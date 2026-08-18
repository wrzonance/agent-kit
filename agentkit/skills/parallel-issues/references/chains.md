# Issue chains

## Contents

- Building the chain graph
- Publishing a locally-built chain base
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
that dependency is also mechanically evident. Classify each file-conflict pair before it
becomes an edge: only an **interface dependency** — one issue consumes code or contracts the
other produces, or both mutate the same executable logic — serializes. Overlap confined to
test files or prose is not a dependency: run those issues in parallel and merge the later
branch down once at the end, resolving the textual collision there. Build the dependency
graph from the interface edges and blocked-by edges and decompose it into linear chains;
print the resulting chain plan next to the conflict table (attended runs get approval on it;
`--fast-mode` proceeds and discloses).

A cycle cannot be linearized into a chain. When the graph contains one, report the cyclic
members by issue number and fall back to the ordinary drop/ask handling for exactly those
issues — the rest of the chain plan is unaffected.

**A join is scheduled, not dropped.** If an issue has more than one predecessor in the graph
(C blocked by both A and B), there is no single predecessor SHA to start from — but that is
a sequencing fact, not a reason to lose the issue from the run. Defer C until every
predecessor's commit is pushed, then build its start point by merging those pushed commits
down: create C's branch from the first predecessor's SHA, then for each remaining
predecessor's SHA in turn run `git merge --no-ff` (inspect with `--no-commit` first when
caution is warranted, but **commit each merge before starting the next** — one pending
merge blocks another, and an uncommitted merge has no SHA). The final integration commit's
full 40-character SHA is C's `chain_base_sha`. Push that integration commit to
`origin/feat/issue-C` before C's lead is dispatched: `create-issue-worktree.sh` pushes a
branch exactly once, at creation, from whichever single SHA it started at, and never
re-pushes a merge commit added afterward. A join's dispatch gate is therefore two-part —
**predecessors pushed AND join base pushed** — because an unpushed join base fails
`agent-run.sh`'s `--yolo-base` pin by construction (see "Publishing a locally-built chain
base" below). A conflict at any step parks exactly C by
name for human resolution — never pick one predecessor and silently drop the other's
commits, and never invent a merge base by hand.
Report the join, its predecessors, and the merged base in the chain plan so a five-issue set
dispatches five issues. Chains respect a hard depth cap of 4; an issue that would extend a
chain past that depth is dropped from the chain with a named report rather than silently
truncated or silently included.

## Publishing a locally-built chain base

Any commit built locally on top of a predecessor — a join's integration commit above, or a
linear successor's own merge-down of an advanced predecessor (below) — is invisible to
`origin` until it is pushed. `agent-run.sh`'s `--yolo-base` pin (`yolo_pinned_base`,
`agent-run.sh:1372-1403`) accepts only a SHA that is itself server-advertised or an ancestor
of one, so a locally-committed merge that has not been pushed fails that check by
construction, regardless of whether it came from a join or an ordinary two-parent
merge-down. `create-issue-worktree.sh` pushes a branch exactly once, at creation, from
whichever single SHA it started at — it never re-pushes a merge commit added afterward, so a
branch that started from a single predecessor lands in exactly the same unpushed-base
position as a join the moment either one gains a local merge commit of its own; a linear
chain is not protected from this just because it only had one predecessor.

Two ways to satisfy the pin — pick the one that matches who is about to rely on the commit:

- **Push the local commit.** Use this whenever the merge commit itself is what gets handed
  to a successor or dispatched against — a join's integration commit before its lead is
  dispatched, and any cascade step below where the successor is about to be re-verified or
  handed off. Push before composing the next prompt or running the next check.
- **Pin `--yolo-base` to the predecessor's already-published SHA instead of your own merge
  commit.** Use this for a worker's own *interim* verification mid-task, before its single
  end-of-task push — the predecessor's SHA is already origin-advertised and is an ancestor
  of the local merge commit, so the pin succeeds without publishing unreviewed work early.
  This is also the more honest anchor of the two: pinning trust to your own not-yet-reviewed
  commit makes your own changes the trust base, while the predecessor's SHA was already
  root-published before you built on top of it.

Chains gate on the predecessor's **pushed commit**, never on PR state (open, draft, or
merged) and never on the root's publication ceremony — a successor starts from the exact
commit the predecessor's worker committed and pushed (the completion report carries the full
SHA), not from "the PR looks mergeable," and it does not wait for the PR to exist.

## Deferred dispatch

A chain successor's worktree is created and its lead dispatched as soon as the
predecessor's worker has committed **and pushed** its branch — the commit is the gate, not
the publication. The root's post-push review, draft-PR creation, board move, and ledger
writes are off the successor's critical path; if that review later lands a fix commit, the
successor absorbs it as an ordinary merge-down. A lead that merely *reports* done without a
pushed SHA has not cleared the gate. `chain_base_sha` is recorded as the full 40-character
lowercase SHA from the commit line `worktree-commit.sh` printed for that predecessor (the
completion report carries it), and it is what the successor's `git worktree add` starts from
instead of `origin/$base`.

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
   tree. Publishing here is what makes that re-verification's `--yolo-base` pin valid in the
   first place — see "Publishing a locally-built chain base" above for the mechanism and the
   interim-verification alternative when a worker needs to check its own merge before its
   final push.
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
