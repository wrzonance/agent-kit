# Issue chains

## Contents

- Building the chain graph
- Publishing a locally-built chain base
- Deferred dispatch
- Deferred draft finalization after a predecessor advances
- Merge order and the stacked-PR retarget
- Post-squash-merge conflicts
- Never send a post-push instruction that reads as a rewrite
- Contract-inheritance refusal and recovery

Read this when `--auto-serialize` turns Step 3 conflicts into chains, and again at Phase 2
dispatch time and at the ready-flip handoff. `SKILL.md` keeps the pinned mechanics (the
ordering-evidence rule, the depth cap, the exact deferral and retarget sentences); this file
carries the walkthrough behind them.

## Building the chain graph

Coverage enforcement applies only to kit chain targets matching
`^feat/issue-[1-9][0-9]*$`, the branch convention owned by `create-issue-worktree.sh`.
Other targets, including release/backport branches, keep their ordinary CI policy.
A kit stacked PR may receive no checks or only part of the check set observed on a
recent default-target PR. The helpers compare actual check-run identities (app ID
and name), retain providers such as GitHub Code Quality, and name the reference
PR/head plus missing checks. `verification=no-ci-on-stacked-base` identifies zero
checks; `partial-ci-on-stacked-base` identifies a coverage gap; unavailable or empty
reference evidence is `unknown`. These observations do not establish the cause or
which checks are required. Workflow files alone cannot explain repository-managed
checks. Review completion does not clear missing CI. After retarget, observe fresh
checks and closing linkage before merging; retargeting is not proof the gap cleared.

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

`create-issue-worktree.sh` pushes a branch exactly once, at creation; any merge commit added
afterward (a join's integration commit, or a successor's merge-down of an advanced predecessor) is
invisible to `origin` until pushed — a linear chain is not protected from this just because it only had one predecessor.
Push before handing a commit to a successor's worktree creation or to review; a worker's interim
verification needs no push, since `agent-run.sh` runs against what is on disk.

Chains gate on the predecessor's **pushed commit** (the completion report carries the full SHA),
never on PR state or the root's publication ceremony.

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

## Deferred draft finalization after a predecessor advances

A predecessor can advance after a successor review starts: a review fix, CI repair, or generator
change may publish a new head. Record the predecessor's final evidence, but do not merge, verify,
or relaunch reviews across its descendants. `chain-advance.sh --finalize-successor` acts only on
the PR named by the caller and does not enumerate or update descendants. The existing run-state
file stores the sealed tuple at `chainFinalizations.<pr>`; this is resume evidence, not a new
registry.

Before any merge or full run, call `chain-advance.sh --finalization-status --pr N --run-state
"$RUN_DIR/run-state.json" --predecessor-pr P`. Exit 0 (`finalization=sealed`) ends the driver
without work. Exit 10 means the recorded child head or immediate-parent tuple changed. Re-finalize
a moved predecessor first; unavailable or malformed remote evidence remains a hard failure.

Finalize in dependency order at the draft-ready boundary:

1. Finish the predecessor first. Its tuple must bind a terminal receipt, immutable reviewed
   head/payload, green final-head `--pr-state-digest` with known code-quality and inline-comment
   classifications, explicit `--accepted-findings` evidence, final verified head, and the exact
   remote branch SHA. A normal-policy `verified-skip` receipt binds its reviewed head and payload
   directly and does not require a paid-review ledger. An ancestry relation alone is never a
   finalized-parent proof.
2. If the predecessor's recorded final head is already an ancestor of the successor's reviewed
   head, no integration is needed. Otherwise the successor's sole writer resolves that exact SHA
   with `--resolve-base`, runs `git merge --no-commit --no-ff <full-SHA>`, and inspects every
   conflict. Preserve independent intent from both sides; never select a side merely from
   `ours`/`theirs` labels. Commit the deliberate result. If the merge carries a protected path
   forward unchanged, use `worktree-commit.sh --include-staged --yolo --allow-base-inherited
   "$(git rev-parse MERGE_HEAD)" -- <paths>`; this allowance applies only during the active merge.
3. Keep the driver order `commit -> full verification -> push`: run the successor's full
   integration verification once on the committed combined head, push that exact head, refresh
   final-head CI, and disposition accepted findings against the resulting code. For an adversarial
   receipt, extend the existing ledger with `review-ledger.sh cover --reason
   merge-down:<exact-predecessor-final-head>`. The original reviewed head and payload stay
   immutable; the cover bridges them to the final integrated head without another review spend.
4. Invoke `chain-advance.sh --finalize-successor --pr N --predecessor-pr P --repo OWNER/REPO
   --run-state "$RUN_DIR/run-state.json" --issue-comments "$RUN_DIR/state/pr_N_issue_comments.json"
   --pr-state-digest "$RUN_DIR/state/pr_N_final.digest" --accepted-findings
   "$RUN_DIR/accepted-findings.ndjson" --review-attempt "$RUN_DIR/state/review-attempt.json"
   --pushed-branch feat/issue-N`. Omit `--review-attempt` only for a terminal verified skip. It
   refuses unresolved parent evidence, stale lineage, red or pending CI, incomplete findings, and
   a remote branch whose exact tip differs. An unchanged
   successful tuple prints `no-op` and does not rewrite state, run verification, or launch review.

For A -> B -> C -> D with several A fixes before finalization and no later changes, this produces
three successor integration verifications: B after A, C after B, and D after C. Initial
implementation checks and CI are separate. If A advances again, B becomes stale when B next reaches
finalization; C and D remain untouched until their immediate predecessor is finalized again. This
topological walk preserves useful successor work and removes the eager all-descendant cascade.

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

Two proofs tolerate evidence a retarget can never make current (issue #577), and the proof line
reports them ahead of `closing-issues=`:

- `behind=N generated-only=yes|no` — a `behind_by` gap confined entirely to declared
  `AGENT_GENERATED_PATHS` is reported, not refused; any undeclared path in the gap refuses.
- `provider-check=<names>|none|unreadable` — a stale check is excused only when its check-run's own
  `.app.slug` belongs to a provider in `AGENT_REVIEW_PROVIDERS`; unreadable grants nothing.
- `approval=current:post-retarget|residue:stale|none|unknown` — recorded, never a gate (issue #455):
  formal approval is provider policy and settles at the ready/provider transition.

Both exemptions read *this checkout's* `.agent/config.env` and print
`exemptions=disabled reason=repo-mismatch` when the checkout's own slug differs from `--repo`.

For an interactive human merge, deleting the merged head may make GitHub close a draft or
not-cleanly-mergeable successor instead of retargeting it (#484, #561, issue #564).
`merge-pr.sh --delete-branch` never relies on that: it reads for open dependents first and by
default refuses the delete and names them; `--retarget-dependents` is opt-in after this file's
merge-down-then-`chain-advance.sh --retarget` procedure has completed for every dependent, and a
dependent GitHub closes anyway is recovered with `chain-advance.sh --recover-closed` (also the fix
for a successor an older kit or a human merge left closed). See
`pr-to-green/references/auto-merge.md`'s "Dependents check before delete" for the contract.

A retarget invalidates the successor's evidence: after every parent merge, revalidate each open
successor with the helper's live `base...head` ancestry read and require CI against the new base
before treating it as green; a stale digest is a stop signal, and a stale approval is reported as
`approval=residue:stale`, never inherited or re-triggered.

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

A dispatched worker's history is frozen at its first push (`worker-prompts.md`'s "History freeze" states it in
the worker's voice). The root's reciprocal half: once a worker has pushed, never send it — or leave in its inbox
— anything readable as "amend," "reset," "rebase," or "force-push", however small the defect; a rewrite strands
any successor already started from that SHA. Word every post-push correction as a request for a new commit.

## Contract-inheritance refusal and recovery

`create-issue-worktree.sh` carries the root's `.agent/env-contract.txt` into each new worktree with
`agent-preflight.sh --inherit-session`, and a same-harness source past the inheritance window is
revalidated (never-widen on every field) rather than discarded, so a long chain's pushed commit
handoff no longer trips `compose-worker-prompt.sh`'s `worktree-contract-less-restrictive-than-root`
refusal. If that refusal still appears (a source written by a different harness is never inherited):

1. Re-run preflight at the ROOT checkout.
2. Re-run `agent-preflight.sh --worktree <worktree> --inherit-session <root-env-contract>`.
3. Re-run `compose-worker-prompt.sh` for that link.

Safe to repeat; nothing mutates git state or re-dispatches the lead.
