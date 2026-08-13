# Issue chains

## Contents

- Building the chain graph
- Deferred dispatch
- Merge order and the stacked-PR retarget

Read this when `--auto-serialize` turns Step 3 conflicts into chains, and again at Phase 2
dispatch time and at the ready-flip handoff. `SKILL.md` keeps the pinned mechanics (the
ordering-evidence rule, the depth cap, the exact deferral and retarget sentences); this file
carries the walkthrough behind them.

## Building the chain graph

Ordering evidence is exactly two mechanical sources inside the selected set: file-conflict
pairs from Step 3's own analysis, and native GitHub blocked-by edges. Issue-body prose is
never an ordering input — an issue that *says* it depends on another does not chain unless
that dependency is also mechanically evident. Build the dependency graph from those edges
and decompose it into linear chains; print the resulting chain plan next to the conflict
table (attended runs get approval on it; `--fast-mode` proceeds and discloses).

A cycle cannot be linearized into a chain. When the graph contains one, report the cyclic
members by issue number and fall back to the ordinary drop/ask handling for exactly those
issues — the rest of the chain plan is unaffected.

**A join is not linearizable either, and is handled the same way.** If an issue has more
than one predecessor in the graph (C blocked by both A and B), there is no single
`chain_base_sha` for it: dispatching C from either predecessor alone silently builds it on
a base missing the other's published commits. Report the joining issue and its predecessors
by number and drop exactly that issue from the chain plan, leaving its predecessors to run
as ordinary chain members. Do not pick one predecessor, and do not invent a merge base —
combining two published commits is a real integration decision, not a dispatch detail. Chains respect a hard depth cap of 4;
an issue that would extend a chain past that depth is dropped from the chain with a named
report rather than silently truncated or silently included.

Chains gate on **root-published commits**, never on PR state (open, draft, or merged) — a
successor starts from the exact commit the root validated and pushed for its predecessor,
not from "the PR looks mergeable."

## Deferred dispatch

A chain successor's worktree is created and its lead dispatched only after the root has
validated, committed, and pushed the predecessor's handback — never earlier, and never
merely once the predecessor's lead *reports* done. `chain_base_sha` is recorded from the
commit line `worktree-commit.sh` printed for that predecessor, and it is what the successor's
`git worktree add` starts from instead of `origin/$base`.

A deferred issue holds no concurrency slot while it waits — it is not "dispatched but idle,"
it simply has not started. If the predecessor's lead fails or returns BLOCKED, every
successor in that chain is never dispatched: park the whole chain and name it in the report,
rather than guessing at a substitute base commit.

## Merge order and the stacked-PR retarget

The ready-flip handoff must state each chain's merge order explicitly, base PR first —
merging a mid-chain PR before its base is a broken build for whoever merges next. After each
predecessor merges, retarget the successor to the default branch
(`gh pr edit <N> --base <default>`), then verify the successor's `baseRefName` actually
changed before allowing it to merge. Never rely on automatic retargeting: GitHub only
retargets automatically when the base branch is deleted on merge, and not every repository
does that. A stacked PR merged while still based on its predecessor's (now-merged) branch
merges into that branch, not into the trunk — its changes never reach the default branch,
and nothing fails loudly to say so. State all of this explicitly in the handoff; a reader
who only sees "merge order: #67, #68" will not reconstruct the retarget step on their own.

The retarget also invalidates the successor's evidence. GitHub can move the child to the
default branch when the parent branch is deleted, while leaving successful checks and a
provider approval from the old base attached to the child. After every parent merge, pause
the chain and revalidate each open successor: use the helper's live `base...head` ancestry
comparison to detect whether the child is behind its new base, refresh the successor's state,
and require CI to run against the new base before treating it as green.
A stale digest is a stop signal, not a green result. If the provider's approval is stale too,
record that residue explicitly in the handoff; the one-review/one-ping rule does not permit
silently inheriting it or spending a second provider trigger to make the history look fresh.
