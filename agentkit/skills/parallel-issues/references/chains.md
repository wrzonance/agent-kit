# Issue chains

## Contents

- Building the chain graph
- Publishing a locally-built chain base
- Deferred dispatch
- Merge-down after a predecessor advances
- Merge order and the stacked-PR retarget
- Post-squash-merge conflicts
- Never send a post-push instruction that reads as a rewrite
- Contract-inheritance refusal and recovery

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
**predecessors pushed AND join base pushed** — an unpushed join base exists only in this
session's local git objects, and a torn-down session or pruned worktree can lose it before
anyone else reads it (see "Publishing a locally-built chain base" below). A conflict at any
step parks exactly C by
name for human resolution — never pick one predecessor and silently drop the other's
commits, and never invent a merge base by hand.
Report the join, its predecessors, and the merged base in the chain plan so a five-issue set
dispatches five issues. Chains respect a hard depth cap of 4 concurrent successor links. The
cap limits how many links may be in flight; it does not limit chain membership; a successor
that would extend the in-flight depth enters the same refill queue as slot-cap overflow, with
`queued=N[#...]` accounting, and is dispatched from its predecessor's pushed SHA as soon as a
link completes. Never turn a depth-overflow tail into an exclusion or silently truncate the
chain.

## Publishing a locally-built chain base

Any commit built locally on top of a predecessor — a join's integration commit above, or a
linear successor's own merge-down of an advanced predecessor (below) — is invisible to
`origin` until it is pushed. `create-issue-worktree.sh` pushes a branch exactly once, at
creation, from whichever single SHA it started at — it never re-pushes a merge commit added
afterward, so a branch that started from a single predecessor lands in exactly the same
unpublished-merge position as a join the moment either one gains a local merge commit of its
own; a linear chain is not protected from this just because it only had one predecessor.

`agent-run.sh` runs a declared command directly, with no base-pin check to satisfy — that
gate was part of the command-approval fence removed 2026-08-19, and nothing replaced it. Push
anyway, before handing a commit to a successor's worktree creation or to review: an unpushed
commit lives only in this session's local git objects, and a torn-down session or pruned
worktree can lose it before anyone else reads it. A worker's own *interim* verification
mid-task — checking a locally-built merge before its single end-of-task push — needs no push
at all, since `agent-run.sh` runs against whatever is on disk regardless of origin state; push
only when the commit is about to be handed off, dispatched against by another agent, or relied
on by a successor.

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

### Depth overflow and refill

The chain-depth queue is a ready-to-refill queue, not a second class of selection. At the
funnel, list queued issue numbers in pickup order and count them in the same `queued=` field as
ordinary slot-cap overflow. A depth-6 fixture with the four-link cap starts issue #1. Issues
#2--#5 make up the depth window, but become dispatchable one at a time as their immediate
predecessors push (#2 after #1, #3 after #2, #4 after #3, and #5 after #4). Issue #6 stays
queued as `queued=1[#6]` until #5 pushes; then dispatch #6 from #5's exact full SHA and report
`queued=0` at handoff. This demonstrates that depth is a concurrency window while all six
selected issues remain members of one chain.

On every predecessor completion, refill only the next successor whose immediate predecessor
has a pushed commit. Preserve the queued issue's original worktree/branch/write-set plan and
do not consume a slot for a tail whose base is not published. If a run ends before a queued
successor's predecessor publishes, print the still-queued IDs, their `chain-depth` reason, and
the exact command that resumes the original selection with those IDs.

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
   tree — re-verify on the merged tree itself. Publish before handing the commit to the next
   descendant or to review; see "Publishing a locally-built chain base" above for why a
   worker's own interim check does not need this. If the merge carries a protected path
   forward unchanged, commit it with `worktree-commit.sh --include-staged --yolo --allow-base-inherited
   <full-SHA>` — the same full SHA from step 1. Nothing has to carry that SHA in the dispatch
   prompt for this: `--allow-base-inherited` only ever applies while a merge is active, and
   its `verify_base_inherited` check requires the named commit to equal the worktree's own
   `MERGE_HEAD`, which the worker can read straight back with `git rev-parse MERGE_HEAD` at
   commit time. A worktree created from a chain base (`create-issue-worktree.sh
   --chain-base`) commits its own ordinary, non-merge changes exactly like a trunk-based
   worktree does — the protected-path guard never engages outside an active merge, so that
   initial base commit is never needed by `worktree-commit.sh` either, named in a prompt or
   otherwise.
4. Record the refreshed base for every stacked PR in the handoff. The record names the full
   SHA used for the merge and the new PR base, so the next operator can distinguish a checked
   cascade from a branch that merely moved.

The cascade is complete only when each descendant has been verified against the new head that
was merged into it. `chain-advance.sh --retarget --pr N --base B` then performs the agent-driven
retarget proof: it re-reads `baseRefName`, checks `B...head` ancestry, requires settled green CI,
and proves `closingIssuesReferences` is non-empty. Because `gh pr edit --base` leaves
`headRefOid` untouched, and both the check rollup and provider approvals hang off the head
commit, head-bound evidence produced against the *old* base survives the retarget — so the
helper additionally stamps a retarget boundary from the provider's own clock and requires every
check to postdate it. The helper exits non-zero when ancestry, CI freshness, or closing linkage
is missing or stale, including when that provenance cannot be read at all. A base change does
not re-run the workflow (`pull_request` fires on opened/synchronize/reopened, not `edited`), so
this refusal is expected until CI is genuinely re-run against the new base.

Formal approval is provider policy, not mechanical base safety (issue #455), so it never blocks
the retarget proof. The proof line instead reports an `approval=` token —
`current:post-retarget` (an APPROVED review on the current head, submitted after the retarget
boundary), `residue:stale` (an APPROVED review exists but predates the boundary or targets an
older head), `none` (no APPROVED review at all), or `unknown` (review evidence was unreadable).
A trigger/observe provider settles formally on the current head only after the ready/provider
transition that follows this proof (`pr-to-green` Step 3/4); a disabled or effective-none
provider may never produce a formal approval at all, and none is required. Residual approval
state is always recorded, never silently dismissed, inherited, or refreshed automatically —
but it is a record, not a gate.

## Merge order and the stacked-PR retarget

The ready-flip handoff must state each chain's merge order explicitly, base PR first —
merging a mid-chain PR before its base is a broken build for whoever merges next. After each
predecessor merges, **merge the updated default branch down into the successor and publish that
merge before retargeting**. This ordering is load-bearing: a squash merge advances the default
branch with a commit the successor does not contain. For an agent-driven merge, only after that
merge-down succeeds run `chain-advance.sh --retarget --pr <N> --base <default>` and require its
complete proof, including the refreshed `baseRefName`, `base...head` ancestry, current CI
evidence, and non-empty `closingIssuesReferences` (its reported `approval=` token is residue,
not a requirement — see above). The helper prechecks ancestry
before editing: exit 1 means it did not confirm a base mutation (including a behind successor),
while exit 2 means the edit succeeded but a later proof failed and stderr names the applied
base. A stacked PR merged while still based on its
predecessor's (now-merged) branch merges into that branch, not into the trunk — its changes
never reach the default branch, and nothing fails loudly to say so. State all of this
explicitly in the handoff; a reader who only sees "merge order: #67, #68" will not reconstruct
the retarget step on their own.

For an interactive human merge, merging in dependency order and deleting the merged head
branch is expected to let GitHub automatically retarget the successor — but GitHub does not
reliably do that: it closes the successor instead when it is a draft or not cleanly mergeable
onto the new base (`base_ref_deleted` then `closed` in the same second, confirmed for #484
and #561; issue #564). An agent-driven `merge-pr.sh --delete-branch` never relies on that
forge behavior either way: it reads for open dependents before deleting and retargets each one
itself (or, with `--no-retarget`, refuses the delete and names them), then still re-checks
after the delete and recovers via `chain-advance.sh --recover-closed` (recreate the deleted
base ref at its own recorded SHA, reopen, retarget, delete the temporary ref) if GitHub closed
one anyway — see `pr-to-green/references/auto-merge.md`'s "Dependents check before delete" for
the full contract. That recovery helper is also the fix for a successor an *older* kit version,
or a human merge, already left closed this way — one call, base and head unchanged.

The retarget also invalidates the successor's evidence. GitHub can move the child to the
default branch when the parent branch is deleted, while leaving successful checks and a
provider approval from the old base attached to the child. After every parent merge, pause
the chain and revalidate each open successor: use the helper's live `base...head` ancestry
comparison to detect whether the child is behind its new base, refresh the successor's state,
and require CI to run against the new base before treating it as green.
A stale digest is a stop signal, not a green result. If the provider's approval is stale too,
the proof reports `approval=residue:stale` in the handoff; the one-review/one-ping rule does
not permit silently inheriting it or spending a second provider trigger to make the history
look fresh, but a stale or absent approval never blocks the retarget itself — it is the
ready/provider transition's job to settle formally on the current head when the configured
provider action is trigger or observe.

## Post-squash-merge conflicts

When a predecessor is squash-merged, the default branch receives its content in one new commit,
but not the predecessor commits from which the successor was built. On the successor's next
merge-down, Git can therefore fall back to an older merge base and present the predecessor's
already-carried changes as a conflict instead of a real divergence.
This conflict is expected once per link in any squash-merged chain; by itself, it does not mean
the chain or merge-down failed.

Resolve it from content evidence, never from the conflict labels alone:

1. Before reading `--theirs`, `:2:`, or `:3:` content, assert that this is still an active merge:
   `git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || { echo 'MERGE_HEAD absent; stop' >&2; exit 1; }`.
   An aborted merge is a hard stop; never run a conflict-resolution fallback without `MERGE_HEAD`.
   Compare both complete conflict blobs before choosing a side. For a default-branch merge into
   the successor, the branch is normally `ours` and the updated default branch is `theirs`; verify
   that orientation from the merge being performed rather than assuming it.
2. Establish whether the branch is a superset of the default-branch blob. Account for every block
   on the default-branch side and identify every line it has that the branch lacks. State the
   finding concretely, for example: "branch is a superset except N lines, which are the superseded
   form of X."
3. Choose the resolution that follows from that comparison. If the only default-branch-only lines
   are an older form deliberately replaced by the successor, keeping the branch side is justified.
   If either side has independent content, combine it deliberately. A blind `--theirs` can
   duplicate predecessor content the branch already carries.
4. Report the conflict, the blob comparison, the superset finding, and the chosen repair. A
   conflict repair is never resolved silently.

## Never send a post-push instruction that reads as a rewrite

A dispatched worker's history is frozen the moment its first push lands — `worker-prompts.md`'s
"Progress, commit, and push" section states that rule in the worker's own voice, and the
fix-batch template carries the same rule. This is the root's reciprocal half of it: once a
worker has pushed, never send it — or leave standing in its inbox from an earlier phase — any
instruction that can be read as "amend," "reset," "rebase," or "force-push" the commit it just
published, no matter how small the defect. A `Co-Authored-By` trailer typo, a wording nit, or
any other cosmetic fix is never worth it: rewriting a commit that a chain successor may already
have started from strands that successor — its branch keeps pointing at a SHA that no longer
exists on `origin`, the merge-base falls back to the trunk, and its PR ends up showing the
predecessor's entire diff duplicated inside it. Ask for a follow-up commit instead, exactly as
the worker itself is instructed to do. Confirmed 2026-08-21: a pre-push "fix the trailer if it
is wrong" instruction was still sitting in a worker's inbox after its push and read as license
to force-push; word every post-push correction as a request for a new commit, never as a
description of what the existing one should have said.

## Contract-inheritance refusal and recovery

A long `--auto-serialize` chain is by construction long-running: each link waits for its
predecessor's pushed commit before its own worktree is created. `create-issue-worktree.sh`
carries the ROOT checkout's own `.agent/env-contract.txt` into each new worktree with
`agent-preflight.sh --inherit-session`, since `sandbox=`/`tls=`/`caches=` describe the
*session* (which process is running commands, what it can reach), not any one worktree, and a
fresh per-worktree probe can disagree with the root while being truthful for itself. That
carry-forward is only trusted from a source recent enough and written by the same harness/CLI
— there is no cryptographic session identity to check instead. The root's own contract is
written once, at session start, and by a chain's third-or-later link it is routinely older
than the inheritance window even though nothing about the session actually changed.

Before this was fixed, staleness discarded the recorded root contract outright and fell back
to an unqualified fresh probe in the new worktree's own process. If that fresh probe was less
restrictive on any field than the (older, more restrictive) root contract — for example a root
recorded as `active=unknown measured-by=hook` against a worktree that freshly measured
`active=no measured-by=agent-shell` — `compose-worker-prompt.sh` refused to compose the
worker prompt at all, with the reason `worktree-contract-less-restrictive-than-root` and no
documented way forward.

`agent-preflight.sh` now revalidates a same-harness stale source instead of discarding it:
past the window it still probes fresh, but keeps whichever of the recorded and fresh readings
is more restrictive on every field (the same never-widen comparison `apply_never_widen`
already uses for a worktree's own prior contract), so an ordinary chain link no longer trips
this refusal. Harness identity is still a hard requirement — a source written by a different
harness/CLI is never inherited or revalidated, only re-probed fresh — and that case, or any
other refusal that still reaches `compose-worker-prompt.sh`, has this recovery sequence:

1. Re-run preflight at the ROOT checkout so its own `.agent/env-contract.txt` reflects the
   current session.
2. Re-run `agent-preflight.sh --worktree <worktree> --inherit-session <root-env-contract>`
   for the affected worktree.
3. Re-run `compose-worker-prompt.sh` for that link.

This sequence is cheap and safe to repeat; nothing about it mutates git state or requires
re-dispatching the link's lead.
