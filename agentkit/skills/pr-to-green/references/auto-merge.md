# Auto-merge (`--auto-merge`)

This is the detail behind the SKILL.md body's `--auto-merge` heading: consent
recording, the pre-merge review-completion gate, serialization, and method
semantics. Read it once per run when `--auto-merge` is present on the
invocation line. "Concurrency admission and revalidation" below applies to
every run driving Steps 2–4 in parallel, `--auto-merge` or not — read it
whenever more than one independent root is being driven at once.

## Contents

- Concurrency admission and revalidation
- Consent and the ledger record
- Mechanical queue advance without redisplay
- The pre-merge review-completion gate
- Serialization protocol
- Merge method and branch deletion
  - Dependents check before delete (issue #564)
- Board move
- PreToolUse guard alignment
- Still forbidden

## Concurrency admission and revalidation

**Cap source and admission.** The runtime concurrency cap comes from
`parallel-issues/scripts/concurrency-cap.sh` (never inferred or invented), with the root as one
occupant; a root over the cap queues until an occupant reaches evidence-green or blocks, and a root that
fails or blocks releases its slot immediately.

**The confirmed-queue snapshot is single-slot.** `authorize-queue.sh` and `pr-queue.sh
--write-confirmed-queue` share one fixed path, so authorizing PR B overwrites PR A's record even in
sequence; a root entering the Step 2 critical section must re-derive the authorization for its own PR at its own current head every time.

**Revalidate after every merge.** A Step 5 merge stales every other in-flight root's base: before its
next mutation, every other in-flight root revalidates its own head and base with a fresh
`pr-queue.sh`/`gh-pr-state.sh` read — evidence captured before that merge may not authorize a mutation,
and the transition/settlement steps do not re-check it for you.

## Consent and the ledger record

`--auto-merge` is valid only on the invocation line — never inferred from a
prior session, a comment, or issue prose. It is covered by the same single
displayed-queue confirmation Step 1 already requires; the displayed plan must
say plainly that confirmed merges are included before that confirmation is
asked for. Record the grant in the session ledger exactly like the ready-
transition grant, on receipt, before it is exercised.

Step 1 first persists the displayed provider decisions in the owner-only
confirmed-queue snapshot. Its authorization call must pass the exact same
provider name/action/source records; a provider mismatch cannot upgrade,
downgrade, add, or remove review authority. Step 1 then passes `--auto-merge`,
the confirmed `--merge-method`, and exactly one
of `--delete-branch` or `--keep-branch` to `scripts/authorize-queue.sh`. The
helper first matches the freshly derived queue against Step 1's owner-only
displayed-queue snapshot, then derives the authorization queue fields live and
adds the merge fields to the same owner-only record:

```json
{"repository":"...", "readyTransition":true, "autoMerge":true,
 "mergeMethod":"squash", "deleteBranch":false,
 "providers":[...], "queue":[...]}
```

`mergeMethod` is one repository-allowed method (`squash`, `merge`, or
`rebase`) confirmed in the displayed plan. Although branch deletion defaults
to false at the skill invocation boundary, authorization derivation requires
the confirmed choice to be restated explicitly as `--keep-branch` or
`--delete-branch`; it never infers the flag. Worktrees stay preserved either
way — deletion only ever touches the remote branch ref.

## Mechanical queue advance without redisplay

A strict serial queue advances its base after every merge: a merged predecessor
forces every open independent root to merge-down (a clean, no-conflict merge of
the advanced default branch, or a branch-protection-required "up to date"
update) and forces every stacked successor to merge-down and retarget. Either
one changes the item's head SHA, and a retarget also changes its base. The
Step 1 displayed-queue confirmation durably authorizes deterministic
maintenance of *that exact confirmed queue* — it is not blanket consent for a
different PR set, provider plan, merge policy, or a queue the operator has
never seen. Treated naively, every one of these purely mechanical SHA/base
updates would force a fresh redisplay-and-reconfirm round trip per merge,
defeating a confirmed unattended `--auto-merge` sprint (issue #450).

`scripts/authorize-queue.sh --allow-mechanical-advance` closes that gap without widening consent.
It still requires an exact repository and provider-decision match; only when the live queue drifts
from the displayed snapshot does it reconcile each confirmed PR against fresh `pr-queue.sh`
evidence into exactly one bucket:

- **unchanged** — no drift.
- **root merge-down** — prior state `RUNNABLE`, same base, head changed, same diff fingerprint,
  and the authorized head proven an ancestor of the new head by a live `compare` read.
- **stacked retarget** — prior state `WAITING_FOR_MERGE`/`RETARGET_REQUIRED`, base changed, the
  same fingerprint and ancestry proof, and either the proof line
  `chain-advance.sh --retarget` persisted under the repository Git metadata (found automatically)
  or `--retarget-proof PR:FILE` naming that exact line (matching base and head,
  `ancestry=verified`, `green:post-retarget`, an `approval=` token, a `boundaryEpoch=` token, a
  positive `closing-issues=`; `behind=`/`generated-only=`/`boundaryEvent=`/`provider-check=` tokens
  may precede it). The proof's `boundaryEpoch=` must equal the PR's live timeline's own latest
  matching retarget event, read fresh at authorization time (never trusted from the file alone) —
  a proof that outlived a later retarget is refused, naming `chain-advance.sh --retarget` as the
  fix, rather than authorizing a boundary its own CI never actually proved fresh against.
- **verified merge** — a confirmed PR absent from the live queue and independently read as
  `merged:true`.

The diff fingerprint is a sha256 over the sorted per-file `{filename, blob sha, patch}` list from a
live `pulls/N/files` read, computed by `pr-queue.sh`; a failed or oversized read yields a null
fingerprint that satisfies no bucket. Anything that fits no bucket fails closed with the same
redisplay-and-reconfirm refusal as without the flag, and the helper prints why. The Step 3
transition and `merge-pr.sh` still re-read the live PR at the moment of mutation. Several roots
share the one confirmed-queue file, so their re-run/reconfirm sequences serialize; reviews and
transitions stay concurrent.

## The pre-merge review-completion gate

Before any merge, run `scripts/merge-gate.sh` for the exact confirmed head. It re-reads the PR and
its reviews live and consumes:

- `--pr-state-digest FILE` — `gh-pr-state.sh --full` output for this head, captured with its own
  `--digest-out FILE` (never a shell redirect: a group- or world-writable file is rejected). A
  digest whose `sha=` is not the confirmed head blocks.
- `--provider-result RESULT` — the CodeRabbit result the transition step printed (`AUTO_REVIEW`,
  `TRIGGERED`, `ALREADY_SPENT`, `LANDED`, `STALE_HEAD`, `OBSERVE_ONLY`, `DISABLED`, `BLOCKED`,
  `NONE`). `AUTO_REVIEW`, `ALREADY_SPENT`, and `LANDED` pass; `TRIGGERED` (review in flight) and
  `STALE_HEAD` (review for an earlier head) block.
- `--human-items-decided yes|no` — `no` blocks.
- `--adversarial-review-status covered-head|covered-diff|covered-lineage|stale|absent|blocked|not-required`
  — the word `review-ledger.sh status` prints for this head. The three `covered-*` values pass;
  `stale`, `absent`, and `blocked` block; `not-required` is only ever passed through from a
  documented materiality skip.
- `--code-quality-scan-state complete|pending|not-enabled` and/or `--code-quality-state-file FILE`
  — from `code-quality-state.sh --head SHA --pr N` (its `--state-file` output is the file form;
  both must agree byte-for-byte). `pending` blocks; `complete` and `not-enabled` pass; an
  unreadable probe reports `unknown` and blocks.

Every block prints `blocked reason=…`; `scripts/merge-gate.sh --help` carries the full enum.

### Canonical call sites for the two newest gate inputs

```bash
"$agentkit/review-remote-pr/scripts/gh-pr-state.sh" --pr "$pr" --repo "$repo" \
  --digest-out "$digest_file"
# The pr= / sha= summary line above is read live from the file above; do not
# re-derive it by hand. gh-pr-state.sh writes it itself, mode 600, so the
# file is never rejected as group- or world-writable.

"$agentkit/review-remote-pr/scripts/code-quality-state.sh" \
  --repo "$repo" --head "$head_sha" --pr "$pr" \
  --baseline-file "$work_dir/code-quality-state.json" \
  --state-file "$work_dir/code-quality-scan-state.txt"
# scan-state=... is read live from the --state-file above; do not re-derive
# it by hand, and do not read it from --baseline-file's JSON artifact --
# that file holds {head, findingsOnHead, repoWideOpen, timestamp}, not a
# textual scan-state= line, and merge-gate.sh rejects it as malformed.

adversarial_status=$("$agentkit/review-remote-pr/scripts/review-ledger.sh" status \
  --repo "$repo" --pr "$pr" --comments "$comments_file" --head "$head_sha" \
  --kind adversarial --repo-root "$repo_root") || true

"$agentkit/pr-to-green/scripts/merge-gate.sh" \
  --repo "$repo" --pr "$pr" --head-sha "$head_sha" --base "$base" \
  --pr-state-digest "$digest_file" --provider-result "$provider_result" \
  --human-items-decided yes \
  --adversarial-review-status "$adversarial_status" \
  --code-quality-state-file "$work_dir/code-quality-scan-state.txt"
```

`review-ledger.sh status` exits non-zero for `stale`/`absent`/blocked outcomes
while still printing the verdict word on stdout — capture it with `|| true`
rather than treating a non-zero exit as evidence-unavailable.

### Recording a merge-down or retarget transition (issue #567)

The one-shot receipt's review head predates any post-receipt merge-down or
retarget by construction — `review-ledger.sh status` correctly reads that gap
as `stale`, and the one-spend rule forbids re-reviewing just to clear it.
Before re-running the gate against an advanced head, extend the covered
entry's lineage instead of falsifying or parking:

```bash
"$agentkit/review-remote-pr/scripts/review-ledger.sh" cover \
  --repo "$repo" --pr "$pr" --comments "$comments_file" --head "$head_sha" \
  --reason "merge-down:$base_sha" --kind adversarial --repo-root "$repo_root" || true
```

Always pass `--kind adversarial`: an unfiltered call extends whichever entry
is LAST in the ledger, which may be a bot entry (e.g. a CodeRabbit record
appended after the adversarial receipt) — leaving the receipt merge-gate.sh
actually reads stale. Use `retarget:$old_base` for a stacked-successor
retarget — the "a stacked retarget" bucket above already runs
`chain-advance.sh --retarget`, whose own best-effort hook calls this (with
`--kind adversarial`) after a successful edit — and `fix:$finding_id` for a
fix-batch commit (SKILL.md Step 3). `cover` refuses (exit 12) a `--head` that
is not a proven git descendant of every SHA already recorded on the entry —
its original head plus every previously covered SHA, not only the original
head — the same fail-closed ancestry proof `status` already applies, so a
force-push that drops an already-covered commit still cannot be waved
through. Deliberately best-effort and non-fatal, like the call above: a
failed `cover` never blocks the merge-down or retarget itself, it only
leaves the next `--adversarial-review-status`
read at `stale` until retried.

Code-scanning completion is proven from `GET code-scanning/analyses`, never from a check-run's
`app.slug`: an analysis on `refs/pull/N/merge` matching the head or the PR's `merge_commit_sha`, or
on `refs/pull/N/head` matching the head. A still-running scan under either app slug only rules
completion out. A repository whose recent history has no `refs/pull/*` analysis but does scan its
base is reported `code-scanning: scheduled-only, last analysis <date> on <ref>` and does not block
on completion; it still needs a readable zero-count alerts line. Every other absence blocks, and an
unreadable probe never grants an exemption. The gate prints which case applied.

**Never dispatch a workflow (`gh workflow run`, a `workflow_dispatch` trigger,
or any other means) to manufacture code-scanning evidence so this gate
passes.** That is gate-gaming, not a remedy, regardless of who or what
initiates it — a scheduled-only repository is expected to report
`scheduled-only` and proceed, not be forced into producing evidence it does
not otherwise generate for this PR.

The gate treats an unreadable surface as blocked, never as clean: a
`code-scanning n/a` line (the endpoint 403/404s), a missing/malformed digest
line, or a digest that cannot be parsed all print a `blocked reason=...` line
and exit non-zero. The one exception is a repository corroborated as not
using code scanning at all, via two independent readable signals together:
`code-scanning/default-setup` reporting `not-configured`, plus the alerts
endpoint returning the definitive `404 "no analysis found"` body. Either
signal missing still blocks — a 403 or a malformed body keep gating, since
neither readably proves code scanning is unused. The exception clears only
when no code-scanning analysis has ever been recorded for the repository at
all, so an advanced (workflow-based) CodeQL setup that has not yet uploaded
its first SARIF result falls *inside* the exception rather than outside it —
there is no evidence to miss yet, and the gate resumes blocking it the
moment that first upload lands. `gate=PASS pr=N sha=<head>` is
the only signal that authorizes `merge-pr.sh`, and it is bound to that exact
PR and head — save its verbatim stdout, because `merge-pr.sh` requires it.
Re-run the gate after any push or base advance — a passed gate for an
earlier head never carries forward.

## Serialization protocol

`--auto-merge` implies strict serial merge ordering; there is no parallel
variant. This is scoped to the merge step alone — the ready-transition,
provider trigger, and Phase C finding settlement that get an independent root
to evidence-green in the first place may run concurrently across roots (see
SKILL.md Steps 2–4); only `merge-gate.sh` → `merge-pr.sh` → retarget is
one-at-a-time. For the current confirmed `RUNNABLE` item, once its
evidence-green state and the gate above both hold:

1. Invoke `scripts/merge-pr.sh` with the same confirmed repo/pr/head/base and
   the ledger's `mergeMethod`/`deleteBranch`, plus `--authorization-file` (the
   Step 1 ledger record) and `--gate-result` (the saved `gate=PASS` stdout
   from the step above). The guard lives at the point of mutation, not just in
   the calling order: `merge-pr.sh` refuses — sending no merge request — unless
   the authorization file confirms this exact repository/PR/head/base/method/
   delete-branch as an `autoMerge:true` confirmed `RUNNABLE` queue member, and
   the gate-result file carries a `gate=PASS` line for this exact PR and head.
   It also re-verifies head, base, and `mergeable` itself immediately before
   the merge call — a second, independent freshness check, not a trust of the
   gate's read.
2. On `pr=N merged=true`, mark that PR's board item `Done` (existing helper;
   redundant-with-automation board moves are harmless).
3. Before the next queue item may merge, re-verify it against the advanced
   base exactly as Step 5 already describes: refresh base, merge-down/re-run
   CI if behind, and for a stacked successor run the full
   `../parallel-issues/scripts/chain-advance.sh --retarget` proof. Its own
   gate and merge only run after that revalidation is clean. No merge may
   start while a predecessor's post-merge revalidation is outstanding. When
   a squash-merged predecessor makes that merge-down conflict, follow the
   [post-squash-merge conflict procedure](../../parallel-issues/references/chains.md#post-squash-merge-conflicts)
   before choosing a side.
4. A merge conflict, a failed retarget proof, or a merge refusal (see below)
   parks that item by name and continues the oldest independent runnable
   root, exactly as a non-merge block does today.

## Merge method and branch deletion

`merge-pr.sh` reads the repository's `allow_squash_merge` /
`allow_merge_commit` / `allow_rebase_merge` flags live and refuses to merge
with a method the repository does not allow — this is never inferred or
overridden from the invocation. `--delete-branch` is explicit and defaults to
off; when it is on, a failed branch deletion is reported but does not undo an
already-completed merge (the branch simply outlives the PR, same as the
default). `merge-pr.sh` never deletes by branch name alone: it skips (naming
the reason, never silently) when the PR's head repository is not this target
repository — a fork PR's `feat/x` lives in the fork, and deleting
`owner/repo:feat/x` by name could remove an unrelated same-named branch in
the target repository instead — and it re-reads the branch ref immediately
before deleting, skipping if the tip no longer matches the merged head (new
work may have landed on it since the merge completed). With
`delete_branch_on_merge` enabled the head is deleted by the repository
regardless; `merge-pr.sh` restores it (`branch_delete=restored`) when the run
chose keep-branch.

### Dependents check before delete (issue #564)

Deleting a merged head branch can make GitHub close, rather than retarget, an open dependent that
is a draft or not cleanly mergeable. `--delete-branch` therefore reads
`pulls?state=open&base=<head>` first: with no dependents it deletes; with dependents it refuses,
names them, and exits 3 (the merge already succeeded); an unreadable check refuses too.
`--retarget-dependents` is opt-in and only repoints each dependent's base with a verified `PATCH` —
pass it only after the merge-down and `chain-advance.sh --retarget` proof in
`parallel-issues/references/chains.md` are complete for every dependent. After a delete under that
flag, `merge-pr.sh` re-reads each dependent and recovers any closed one via
`../../parallel-issues/scripts/chain-advance.sh --recover-closed` (best-effort; reported as
`dependent-recovery-failed` when it cannot). `authorize-queue.sh` records `deleteBranch:
"deferred"` for a predecessor with an open successor in the same confirmed queue, and
`merge-pr.sh` refuses that delete on the record alone.

## Board move

The merge step alone moves the board item to `Done`. It does not chain into
`--auto-merge`'s consent — a board move never blocks or reverses a completed
merge, and a redundant `Done` from GitHub's own Project automation is
harmless.

## PreToolUse guard alignment

The repository's PreToolUse hook (`agentkit/hooks/lib/guard-lib.sh`) refuses every directly-typed agent
merge — `gh pr merge`, `gh api -X PUT repos/OWNER/REPO/pulls/N/merge`, and a `gh api graphql`
`mergePullRequest` mutation — unconditionally, even after operator authorization, and even when the
words appear only inside a quoted data string. `merge-pr.sh` is the sole sanctioned entry point: the hook
inspects only the agent's own command line, never a helper's internals, so its identical REST call passes.

## Still forbidden

Also forbidden: force-push, history rewrite, merging a `BLOCKED` item, bypassing branch protection, any
directly-typed merge form, merging outside the confirmed queue, and dispatching a workflow to manufacture
gate evidence. `merge-pr.sh` never retries around a forge refusal (required-approval, stale-sha 409,
not-mergeable 405): each is reported verbatim as a named stop.
