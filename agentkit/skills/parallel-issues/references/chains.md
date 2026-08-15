# Issue chains

## Contents

- Building the chain graph
- Deferred dispatch
- Merge-down after a predecessor advances
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
merely once the predecessor's lead *reports* done. `chain_base_sha` is recorded as the full
40-character lowercase SHA from the commit line `worktree-commit.sh` printed for that
predecessor, and it is what the successor's
`git worktree add` starts from instead of `origin/$base`.

A deferred issue holds no concurrency slot while it waits — it is not "dispatched but idle,"
it simply has not started. If the predecessor's lead fails or returns BLOCKED, every
successor in that chain is never dispatched: park the whole chain and name it in the report,
rather than guessing at a substitute base commit.

## Merge-down after a predecessor advances

A predecessor can advance after a successor already exists: a post-review fix, CI repair, or
generator change may publish a new head. The response is a merge-down cascade, not a blind
rebase and not a promise that the old checks still describe the child:

1. Resolve the predecessor's short branch ref to its actual full SHA with
   `chain-advance.sh --resolve-base <ref>`. The helper is read-only; models must never expand
   or copy a SHA by hand.
2. Starting at the immediate successor, merge that new predecessor head into the successor
   branch with `git merge --no-commit --no-ff <full-SHA>`. Inspect conflicts. A conflict stops
   the cascade for human resolution; it is never papered over with an arbitrary merge base.
3. Commit and publish the resolved successor, then re-verify it against that exact new full
   SHA before moving to the next descendant. Repeat the merge, publish, and verification for
   every descendant in order. A successful old check or approval is not evidence for the new
   tree.
4. Record the refreshed base for every stacked PR in the handoff. The record names the full
   SHA used for the merge and the new PR base, so the next operator can distinguish a checked
   cascade from a branch that merely moved.

The cascade is complete only when each descendant has been verified against the new head that
was merged into it. `chain-advance.sh --retarget --pr N --base B` then performs the agent-driven
retarget proof: it re-reads `baseRefName`, checks `B...head` ancestry, requires settled green CI,
requires an approval on the current head, and proves `closingIssuesReferences` is non-empty.
Because `gh pr edit --base` leaves `headRefOid` untouched, and both the check rollup and provider
approvals hang off the head commit, head-bound evidence produced against the *old* base survives
the retarget — so the helper additionally stamps a retarget boundary from the provider's own clock
and requires every check and the approval to postdate it. The helper exits non-zero when any proof
is missing or stale, including when that provenance cannot be read at all. A base change does not
re-run the workflow (`pull_request` fires on opened/synchronize/reopened, not `edited`), so this
refusal is expected until CI is genuinely re-run against the new base. Residual approval state
after a base change remains a human judgment: record it and stop; do not dismiss, inherit, or
refresh it automatically.

## Merge order and the stacked-PR retarget

The ready-flip handoff must state each chain's merge order explicitly, base PR first —
merging a mid-chain PR before its base is a broken build for whoever merges next. After each
predecessor merges, retarget the successor to the default branch. For an agent-driven merge,
run `chain-advance.sh --retarget --pr <N> --base <default>` and require its complete proof,
including the refreshed `baseRefName`, `base...head` ancestry, current CI/approval evidence,
and non-empty `closingIssuesReferences`. A stacked PR merged while still based on its
predecessor's (now-merged) branch merges into that branch, not into the trunk — its changes
never reach the default branch, and nothing fails loudly to say so. State all of this
explicitly in the handoff; a reader who only sees "merge order: #67, #68" will not reconstruct
the retarget step on their own.

For an interactive human merge, merging in dependency order and deleting the merged head
branch lets GitHub automatically retarget the successor. That is the human path, not an agent
shortcut: agents keep the branch and perform the explicit retarget proof because branch
deletion is not guaranteed and agents do not delete remote heads as a merge step.

The retarget also invalidates the successor's evidence. GitHub can move the child to the
default branch when the parent branch is deleted, while leaving successful checks and a
provider approval from the old base attached to the child. After every parent merge, pause
the chain and revalidate each open successor: use the helper's live `base...head` ancestry
comparison to detect whether the child is behind its new base, refresh the successor's state,
and require CI to run against the new base before treating it as green.
A stale digest is a stop signal, not a green result. If the provider's approval is stale too,
record that residue explicitly in the handoff; the one-review/one-ping rule does not permit
silently inheriting it or spending a second provider trigger to make the history look fresh.
