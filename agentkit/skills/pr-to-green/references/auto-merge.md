# Auto-merge (`--auto-merge`)

This is the detail behind the SKILL.md body's `--auto-merge` heading: consent
recording, the pre-merge review-completion gate, serialization, and method
semantics. Read it once per run when `--auto-merge` is present on the
invocation line.

## Contents

- Consent and the ledger record
- Mechanical queue advance without redisplay
- The pre-merge review-completion gate
- Serialization protocol
- Merge method and branch deletion
- Board move
- PreToolUse guard alignment
- Still forbidden

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

`scripts/authorize-queue.sh --allow-mechanical-advance` closes that gap without
widening consent. Passed alongside the normal Step 1/Step 2 invocation, it
still requires an exact match on repository and provider decisions (never
relaxed) and, only when the live queue no longer matches the displayed
snapshot exactly, reconciles each confirmed PR against fresh `pr-queue.sh`
evidence into exactly one of:

- **unchanged** — no drift for this PR.
- **a root merge-down** — the confirmed prior state was `RUNNABLE`, the base is
  unchanged, the head SHA actually changed, the diff fingerprint (below) is
  unchanged, and the previously authorized head is proven an ancestor of the
  new head via a live `compare` read (`behind_by:0`, `status`
  `ahead`/`identical` — never a history rewrite). A bare state change with an
  identical head and base — e.g. the forge recomputing `BLOCKED`/
  `MERGEABLE_UNKNOWN` to `RUNNABLE` with nothing else different — is never
  itself a merge-down and fits no bucket here.
- **a stacked retarget** — the confirmed prior state was `WAITING_FOR_MERGE` or
  `RETARGET_REQUIRED`, the base actually changed (the head may or may not),
  the same diff-fingerprint and live ancestry proof above (both required, not
  only the proof file), plus a `--retarget-proof PR:FILE` naming the exact
  stdout line `../parallel-issues/scripts/chain-advance.sh --retarget` printed
  for this PR (matching base and head, and carrying `ancestry=verified`,
  `green:post-retarget`, `approval=current:post-retarget`, and a positive
  `closing-issues=`). The proof file's own claim is never trusted in place of
  the live ancestry read — both must independently agree. Perform the
  merge-down and `chain-advance.sh --retarget` call itself exactly as Step 5
  and `chains.md` already describe; this flag only lets the resulting refresh
  skip redisplay.
- **a verified merge** — a confirmed PR absent from the live queue, independently
  confirmed `merged:true` from a fresh read of that PR (a PR that vanished for
  any other reason — closed unmerged, deleted, access lost — is never assumed
  merged).

The diff fingerprint is a sha256 over the sorted per-file `{filename, blob
sha, patch}` list from a live `pulls/N/files` read, computed once by
`pr-queue.sh` and carried in its confirmed/live queue evidence (never in the
derived authorization record). An aggregate line-count summary is not a
content identity — a descendant commit can swap reviewed content while
preserving the same add/delete/file-count shape — so equality is checked on
this fingerprint, never on counts alone; a read that fails, returns malformed
data, or covers more files than this is willing to hash yields a null
fingerprint, which can never satisfy a merge-down or retarget bucket.

Every one of those still derives the refreshed head/base live from
`pr-queue.sh`, exactly like the exact-match path — the model never supplies a
replacement SHA by hand. A confirmed PR that fits none of the buckets above
(a state-only change, diff content that changed, a null fingerprint, broken
ancestry, a missing/mismatched retarget proof, or a genuinely new PR the live
queue adds) fails closed with the same redisplay-and-reconfirm refusal as
without the flag — conflicts, unexpected diff expansion, ambiguous ancestry,
topology/provider/merge-policy changes, and human-feedback dispositions are
always material judgment, never mechanical.
The Step 3 transition step and `merge-pr.sh` are unchanged by any of this: both
still re-read the live PR and refuse unless its head and base match the
authorization file's queue record at the exact moment of mutation, so a
mechanically refreshed authorization is exactly as tightly bound as a
freshly confirmed one.

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
  (`AUTO_REVIEW`, `TRIGGERED`, `ALREADY_SPENT`, `LANDED`, `STALE_HEAD`,
  `OBSERVE_ONLY`, `DISABLED`, `BLOCKED`, or `NONE` when no CodeRabbit provider
  is declared). `TRIGGERED` means a request was posted but no terminal review
  was yet observed — that is an in-flight review, and it blocks. `LANDED` is
  that step's observe-mode confirmation that a terminal review postdates the
  trigger AND targets the PR's current head; it gates the merge exactly like
  `AUTO_REVIEW` or `ALREADY_SPENT`. `STALE_HEAD` is a terminal review that
  postdates the trigger but targets an earlier head the PR has since moved
  past — real review evidence, but not for this head, so it blocks exactly
  like `TRIGGERED`.
- `--human-items-decided yes|no` — whether every human item Phase A/C
  observed for this PR has an explicit per-item decision (the existing
  evidence-green requirement). `no` blocks.
- `--code-quality-scan-state complete|pending|not-enabled` — whether the
  `github-code-quality` scan for the current head has finished. `pending`
  blocks (a finding merely replied-to, with the rescan still outstanding, is
  not finished). `not-enabled` (issue #403) means Code Quality is disabled
  for the repository — a stable repository fact, not a scan in flight — and
  gates exactly like `complete`; only a confirmed "not enabled" 403 from
  `code-quality-state.sh --probe` earns this value, never an unreadable probe
  (network failure, an auth/scope 403, a 5xx), which stays blocked instead.

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
work may have landed on it since the merge completed).

## Board move

The merge step alone moves the board item to `Done`. It does not chain into
`--auto-merge`'s consent — a board move never blocks or reverses a completed
merge, and a redundant `Done` from GitHub's own Project automation is
harmless.

## PreToolUse guard alignment

The repository's PreToolUse hook (`agentkit/hooks/lib/guard-lib.sh`) enforces
one rule for every agent, on every invocation, independent of this skill: an
agent-driven merge is sanctioned **only** through this script, `merge-pr.sh`,
bound to a confirmed `--auto-merge` authorization record plus a `gate=PASS`
review-completion result. Every other way an agent could reach the same forge
action is refused unconditionally — including after an explicit operator
authorization, and including a data string that merely mentions the refused
words (a quoted sed/printf argument never becomes a command):

- The `gh pr merge` porcelain verb.
- The direct REST mutation the porcelain verb itself calls —
  `gh api -X PUT repos/OWNER/REPO/pulls/N/merge` (`--method PUT` and the
  attached `-XPUT` form included) — typed by the agent as its own command.
- The equivalent GraphQL mutation — `gh api graphql` carrying a
  `mergePullRequest` field value.

None of those refusals lift on a retry, by design: the retry the operator
actually wants is this script, run through the consent, gate, and
serialization contract already documented above, not the same call typed a
different way. `merge-pr.sh`'s own mutation call is that identical REST
request, and the guard does not refuse it: the hook inspects only the
**agent's own Bash command line**, never a helper script's internals, so
`merge-pr.sh`'s subprocess call is a command line this hook never sees.
Invoking `merge-pr.sh` itself — the sanctioned entry point — is therefore
unaffected by any of the three refusals above, regardless of what it does
internally.

## Still forbidden

Identical to the non-`--auto-merge` prohibitions, restated because a merge
step raises the cost of getting them wrong: force-push, history rewrite,
merging a `BLOCKED` item, bypassing branch protection, any of the three
directly-typed merge forms (see "PreToolUse guard alignment" above), or
merging outside the confirmed queue. Also forbidden: dispatching a workflow
to manufacture gate evidence (see the code-scanning section above) — a
`BLOCKED` gate is a signal to fix or wait, never to game. `merge-pr.sh` never
retries around a forge refusal — a branch-protection-required-approval
refusal, a stale-sha 409, or a not-mergeable 405 is reported verbatim and is
a named stop.
