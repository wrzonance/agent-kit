# Wait / polling discipline

Read this before issuing any wait in `parallel-issues` or `review-remote-pr` — for a worker
lead, a PR-loop agent, CI, or an adversarial review verdict. It is the single detailed home
for the wait contract; each skill's own body keeps only the pinned rule sentences and names
this file for the rationale and the durable-state recipe.

Waiting is not work, and narrating a wait is not a status report. One observed run spent
~27 empty wait cycles and ~15 paragraphs that carried no new fact — pure cost, zero
progress.

## The rule

**A wait must never spend model turns.** Wait either by invoking a bounded helper that blocks in a single cell — `claude-adversarial-review.sh … > verdict.json`, `gh-pr-state.sh --wait-ci --rounds N --interval S`, or `agent-run.sh --cmd test` — or by one harness-level wait on a background terminal. A `sleep N` + re-check issued as its own tool call is churn: the model pays a turn to do what the helper's internal poll loop already does for free.

Blocking is safe because every wait names an explicit bound alongside its invocation: adversarial max-duration-seconds, the CI round cap, the worker completion marker/contract, or the runner completion marker/contract. Background a worker or producer only when useful work can continue concurrently; when it is the last task standing, rejoin once with a harness-level terminal wait. This rule covers adversarial verdicts, CI, worker waits, and test-runner logs. For logs, run `agent-run.sh --cmd test` in the foreground or poll the log only from inside one bounded harness cell; never issue separate sleep and tail/re-check tool calls.

**A bounded wait must be silent until its terminal condition.** The waiting process emits nothing while waiting and exactly one line on completion or expiry: every line of background output wakes the orchestrator for a turn. A progress heartbeat, if genuinely needed, goes to a log file, not stdout.

For a wait to a known epoch, calculate the target and sleep once. The following copy/paste recipe is silent until its final line:

```text
target_epoch=$(( $(date +%s) + 300 ))
remaining=$(( target_epoch - $(date +%s) ))
if (( remaining > 0 )); then
  sleep "$remaining"
fi
printf 'wait complete\n'
```

If a bounded loop is genuinely necessary, redirect each heartbeat with `>>"$log"` and reserve
stdout for the single completion or expiry line.

- **One wait per interval.** Issue at most one blocking wait per polling interval, and only while a task is genuinely outstanding. Re-issuing a wait the instant it returns empty is the failure mode: it produces nothing and costs a turn every time.
- **Between waits, wait again; read durable state only when a wait reports an actual completion.** A running lead leaves evidence on disk and on the forge; inspect it after completion rather than asking the runtime again.
- **Narrate only a state change or a decision.** "PR #42 opened for issue #57", "lead for #62 returned BLOCKED — coverage gate", "starting the draft loop for PR #68", "declining finding F2 because the input is validated at the boundary" are reports. "Still running", "still waiting", "no output yet", "checking again", "continuing to monitor" are not — when nothing changed, say nothing and wait again.
- **Never hand-poll CI.** `gh-pr-state.sh --wait-ci` already polls with bounded rounds (`--rounds`, `--interval`) and prints one progress line per round on stderr. Use it instead of a loop of `gh pr view` / `gh pr checks`.

## Default numeric bounds per wait class

"An explicit bound" is a number, not an adjective. A wait issued without one falls back to
the harness default (~110 s on one measured runtime), and a five-issue run spent ~2 h
processing 61 timed-out waits that each carried zero information. The defaults:

| Wait class | Default bound |
|---|---|
| Worker implementation wait (`wait_agent` on an issue lead or fix-batch worker) | **900 s** minimum |
| Draft-loop, review, or CI wait | **600 s** |
| Helper-internal polling (`gh-pr-state.sh --wait-ci`, adversarial max-duration-seconds) | the helper's own `--rounds × --interval` / duration bound |

This table is the single source for the worker-wait bound: `compose-worker-prompt.sh` parses
the "Worker implementation wait" row at dispatch time and prints it beside each dispatched
worker's own issue number as a `wait-bound=` line, so the orchestrator reads a number back
instead of recalling this rule — see `parallel-issues/SKILL.md`'s "Compose the issue-lead
prompt" step. Never duplicate this number as a literal in a script; change it here and the
printed value follows.

An early completion still returns early, so a large bound costs nothing when workers are
fast. If the harness caps a single wait below the class default, issue the largest wait it
permits. A wait that returns `timed_out:true` must never be re-issued at the same duration —
it produced nothing and will again: escalate the bound (at least double it) or take the
stall path (`parallel-issues/scripts/stall-check.sh`) instead of blocking blind.

## Never replay a recorded path as a command

Any path that crosses the boundary to a human, or that is recorded for a future resumed run
to execute, uses the contract/resolver form (`$agentkit`, or
`"$agentkit/.shared/scripts/contract-read.sh" --get skills.path`) — never a literal
`agentkit/<version>/` path. A version-pinned plugin path stops resolving the moment the plugin
updates, and it then fails as a bare missing-file error that never says why. The one exception:
the session ledger's `skills_path` field records the version-pinned path as historical
provenance, which is correct and must stay — the hazard is only replaying a recorded
`skills_path` as an executable path on resume without re-resolving it first.

## Durable state to inspect after a completion

Read only from disk and the forge, and only once a wait reports an actual completion:

- The worktree: `git status --short`, `git log --oneline -n 3`.
- The PR: `gh-pr-state.sh --pr N --repo OWNER/REPO`, which returns a five-line digest — PR/
  draft/mergeable/head, CI counts, thread counts, unhandled nitpicks, code-scanning alerts —
  and exits 0 whether CI is green, failing, or pending, because CI state is data and not an
  error. Read the digest and stop; do not chase it with `gh pr view` or `gh pr checks`. Pass
  `--repo` explicitly so it never has to resolve the slug from inside a worktree.

The runnable recipe (re-derive at the top of every shell call — env does not persist between
tool calls; run from inside the issue's worktree):

```bash
set -euo pipefail
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
git status --short
git log --oneline -n 3
pull_request=  # Its PR number; leave empty until one is reported (e.g. after a BLOCKED completion with no PR yet).
if [ -n "${pull_request}" ]; then
  REPO=${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}
  "$agentkit/review-remote-pr/scripts/gh-pr-state.sh" --pr "$pull_request" --repo "$REPO"
fi
```
