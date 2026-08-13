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

- **One wait per interval.** Issue at most one blocking wait per polling interval, and only while a task is genuinely outstanding. Re-issuing a wait the instant it returns empty is the failure mode: it produces nothing and costs a turn every time.
- **Between waits, wait again; read durable state only when a wait reports an actual completion.** A running lead leaves evidence on disk and on the forge; inspect it after completion rather than asking the runtime again.
- **Narrate only a state change or a decision.** "PR #42 opened for issue #57", "lead for #62 returned BLOCKED — coverage gate", "starting the draft loop for PR #68", "declining finding F2 because the input is validated at the boundary" are reports. "Still running", "still waiting", "no output yet", "checking again", "continuing to monitor" are not — when nothing changed, say nothing and wait again.
- **Never hand-poll CI.** `gh-pr-state.sh --wait-ci` already polls with bounded rounds (`--rounds`, `--interval`) and prints one progress line per round on stderr. Use it instead of a loop of `gh pr view` / `gh pr checks`.

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
