# Auto-merge (`--auto-merge`)

This is the detail behind the SKILL.md body's `--auto-merge` heading: consent
recording, the pre-merge review-completion gate, serialization, and method
semantics. Read it once per run when `--auto-merge` is present on the
invocation line.

## Contents

- Consent and the ledger record
- The pre-merge review-completion gate
- Serialization protocol
- Merge method and branch deletion
- Board move
- Still forbidden

## Consent and the ledger record

`--auto-merge` is valid only on the invocation line — never inferred from a
prior session, a comment, or issue prose. It is covered by the same single
displayed-queue confirmation Step 1 already requires; the displayed plan must
say plainly that confirmed merges are included before that confirmation is
asked for. Record the grant in the session ledger exactly like the ready-
transition grant, on receipt, before it is exercised.

The authorization JSON file Step 1 already writes gains one field when
`--auto-merge` is present:

```json
{"repository":"...", "readyTransition":true, "autoMerge":true,
 "mergeMethod":"squash", "deleteBranch":false,
 "providers":[...], "queue":[...]}
```

`mergeMethod` is one repository-allowed method (`squash`, `merge`, or
`rebase`) confirmed in the displayed plan; `deleteBranch` defaults to `false`
(worktrees stay preserved either way — deletion only ever touches the remote
branch ref).

## The pre-merge review-completion gate

Before any merge, run `scripts/merge-gate.sh` for the exact confirmed head.
It re-reads the PR and its reviews live (never trusts stale in-memory state)
and additionally consumes:

- `--pr-state-digest FILE` — the verbatim `gh-pr-state.sh --full` (or
  `--digest`) output captured for this head, immediately before gating. A
  digest whose `sha=` prefix does not match the confirmed head is stale
  evidence and blocks.
- `--provider-result RESULT` — the CodeRabbit result the confirmed
  ready/provider transition step (Section 3) printed for this head
  (`AUTO_REVIEW`, `TRIGGERED`, `ALREADY_SPENT`,
  `OBSERVE_ONLY`, `DISABLED`, `BLOCKED`, or `NONE` when no CodeRabbit provider
  is declared). `TRIGGERED` means a request was posted but no terminal review
  was yet observed — that is an in-flight review, and it blocks.
- `--human-items-decided yes|no` — whether every human item Phase A/C
  observed for this PR has an explicit per-item decision (the existing
  evidence-green requirement). `no` blocks.
- `--code-quality-scan-state complete|pending` — whether the
  `github-code-quality` scan for the current head has finished. `pending`
  blocks (a finding merely replied-to, with the rescan still outstanding, is
  not finished).

Code-scanning completion is proven from `GET code-scanning/analyses` — the
surface that actually records a completed analysis — not from a check-run's
`app.slug`. GitHub records workflow-uploaded SARIF (a CodeQL workflow,
clippy, etc.) under `app.slug=github-advanced-security`, not
`github-code-scanning`; a slug-only lookup false-blocks every head with real,
clean analyses recorded that way, which is exactly what forced the manual
`gh pr merge --admin` in SpecR #667 (see issue #390). `ref` is always sent as
its own query field, never string-interpolated into the URL, so a base
branch name containing `&` or `#` cannot split or truncate the request. The
gate looks for an analysis under `refs/pull/N/merge` whose `commit_sha`
matches the current head — or the PR's current `merge_commit_sha` (read from
the same PR metadata already fetched for the live-state read, never a second
call; a null value, e.g. not yet computed or the PR isn't mergeable, never
widens matching). Matching both is required because a `pull_request`-event
CodeQL/SARIF upload sets `GITHUB_SHA` to the GitHub-generated merge commit
for that ref, not the PR's own head SHA — a head-only comparison false-
blocked every PR scanned that way. `refs/pull/N/head` is queried too and
matched against the head SHA alone, for tools whose workflow checks out and
scans the head ref directly. A still-running scan is read from a check run
under either app slug, demoted to a secondary "in flight" signal only — it
can never by itself prove completion, only rule it out, which is why it is
consulted *first*: a rerun or a second SARIF upload already in flight for a
head an earlier analysis already covers must still block, not read as
already-current. A repository that plainly runs code scanning elsewhere (its
base ref has recorded analyses, e.g. a cron or `workflow_dispatch` schedule
the PR itself never triggers) is reported as `code-scanning: scheduled-only,
last analysis <date> on <ref>` and does not block on scan completion for
that reason alone — but only once a single page (100, most-recent-first) of
the repository's own recent analysis history is read and confirmed to carry
no `refs/pull/*` entry at all. A repository whose history *does* include a
pull-request analysis demonstrably scans PRs, so a missing analysis for THIS
PR is ambiguous absence, not a schedule, and stays blocked (a probe that
cannot even read that history never grants the exemption either — same
fail-closed default as everywhere else in this gate; and a repository with
more than 100 newer schedule-driven analyses could in principle push a
genuine pull-request analysis off that first page, a residual gap the
alerts-line requirement below still covers). A scheduled-only repository
still needs a genuinely readable, zero-count alerts line — `n/a` blocks it
exactly like it blocks every other status; only the two-signal "never used
at all" exception below waives that.

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
variant. For the current confirmed `RUNNABLE` item, once its evidence-green
state and the gate above both hold:

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
   start while a predecessor's post-merge revalidation is outstanding.
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
work may have landed on it since the merge completed).

## Board move

The merge step alone moves the board item to `Done`. It does not chain into
`--auto-merge`'s consent — a board move never blocks or reverses a completed
merge, and a redundant `Done` from GitHub's own Project automation is
harmless.

## Still forbidden

Identical to the non-`--auto-merge` prohibitions, restated because a merge
step raises the cost of getting them wrong: force-push, history rewrite,
merging a `BLOCKED` item, bypassing branch protection, or merging outside the
confirmed queue. Also forbidden: dispatching a workflow to manufacture gate
evidence (see the code-scanning section above) — a `BLOCKED` gate is a
signal to fix or wait, never to game. `merge-pr.sh` never retries around a
forge refusal — a branch-protection-required-approval refusal, a stale-sha
409, or a not-mergeable 405 is reported verbatim and is a named stop.
