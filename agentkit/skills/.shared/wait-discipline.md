# Wait / polling discipline

Read this before issuing any wait in `parallel-issues` or `review-remote-pr` — for a worker
lead, a PR-loop agent, CI, or an adversarial review verdict. It is the single detailed home
for the wait contract; each skill's own body keeps only the pinned rule sentences and names
this file for the rationale and the durable-state recipe.

Waiting is not work, and narrating a wait is not a status report — one observed run spent ~27 empty wait cycles on it.

## The rule

**A wait must never spend model turns.** This is the cost goal, not a guarantee: a runtime may yield even while a helper blocks. Use a bounded helper — `claude-adversarial-review.sh … > verdict.json`, `gh-pr-state.sh --wait-ci --rounds N --interval S`, or `agent-run.sh --cmd test`. A `sleep N` + re-check issued as its own tool call is churn: the helper already owns the polling loop.

CI and review waits belong to a throwaway waiter with fresh context, never the setup or
fix-batch worker. Root dispatches the compact **Throwaway waiter prompt** in
`parallel-issues/references/worker-prompts.md`, using the spawn contract's isolation and
effective cap rules. One waiter owns one bounded helper invocation and one result line;
helper output goes to a file. Consent-bearing review launches remain in the consent-holding
context: a waiter may observe their completion, never launch them. If spawning is unavailable,
record that degradation and use one bounded local helper with the same limits and metrics.

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

### Idle notices are not quiescence proof

An `idle_notification` is a point-in-time observation, not a terminal worker state. Before
any root write in that worker's worktree, compare the notice timestamp with the timestamp of
the newest outbound message sent to that same lead. If the idle notice is older than that
message, it is stale evidence and cannot satisfy the quiescence gate; the lead may have been
resumed by the queued message. Require the other quiescence evidence as well: no unacknowledged
outbound message, a clean `git status --porcelain` apart from declared operator-pending paths,
and a recorded `quiescence:` ledger line naming those observations.

## GitHub API budget — a rate-limit exit is not a wait to retry

Every `gh`-authenticated run by this account shares two hourly pools (REST, GraphQL) across every session
on every machine. `pr-queue.sh --write-confirmed-queue` prints a `budget: rest=R/L reset=ISO graphql=R/L
reset=ISO` preflight line and warns (never blocks) when the queue's estimated cost exceeds the remaining
REST budget. A `gh-pr-state.sh` or `pr-queue.sh` call that dies on exhaustion exits `3` (not `1`) and names
the reset time on the same line. On that exit: stop mutating immediately (no retry, no further write-side
`gh` call); record applied-vs-outstanding from durable state, never from memory of intent; report the reset
time verbatim; and never retry into an empty pool — if the reset is inside this session's remaining time,
wait for it with the silent epoch recipe above. Concurrent runs on one account exhaust the pool inside an
hour; the durable fix is a separate machine identity (agent-kit#179), not spacing polls by hand.

## Default numeric bounds per wait class

"An explicit bound" is a number, not an adjective; a wait without one falls back to the harness default (~110 s). The defaults:

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

An early completion still returns early. Use the largest runtime-advertised yield/timeout
allowed by higher-priority communication limits (the effective cap); class defaults never
override these limits. Below that cap, increase an empty wait's duration up to the cap.
At the effective cap, repeat that capped wait only while the bounded task is outstanding.
An empty yield is neither completion nor a stall. No empty-wait narration, except updates
required by higher-priority instructions; count those requests too.

For implementation workers, record the last observed progress time at dispatch/completion
and the next stall-check deadline: progress time plus `STALL_THRESHOLD_MINUTES` (default 12).
Before that deadline, no `stall-check.sh` call. At or after it, sample once and schedule the
next sample no sooner than another threshold interval; observed progress resets the deadline.
The helper still requires its own consecutive quiet samples before declaring a stall.
External CI pending/expiry is a CI result, not evidence that an implementation worker stalled.

## Wait metrics at handoff

Report `wait_seconds`, `root_requests`, `waiter_requests`, `max_waiter_context_tokens`,
and `requests_per_wait_minute = (root_requests + waiter_requests) / (wait_seconds / 60)`.
Count model requests attributable to waiting, including launch, empty yields, required
updates, and terminal handling; do not equate tool calls with requests. Use the union of
overlapping wait intervals for run elapsed time; sum requests across actors. No waits means
zero counts and rate `n/a`. Missing transcript/token telemetry means `unavailable`, never zero.
Record effective caps and evidence provenance. The virtual 20/30-minute benchmark is
**synthetic**, not live acceptance: fewer than 10 root requests and waiter context below
10K require measured live evidence. A strict communication cap can prevent that root budget.

## Never replay a recorded path as a command

Any path that crosses to a human or is recorded for a resumed run uses the contract/resolver form (`$agentkit`,
or `"$agentkit/.shared/scripts/contract-read.sh" --get skills.path`) — never a literal `agentkit/<version>/` path,
which stops resolving at the next plugin update. The session ledger's `skills_path` field is historical
provenance and must stay; the hazard is only replaying it as executable on resume.

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
  REPO=${REPO:-$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$(git rev-parse --show-toplevel)" --get repo.slug)}
  [[ $REPO == */* ]] || { printf '%s\n' 'repo=none in the environment contract; re-run the Step 0 preflight from a checkout with a GitHub origin' >&2; exit 1; }
  "$agentkit/review-remote-pr/scripts/gh-pr-state.sh" --pr "$pull_request" --repo "$REPO"
fi
```
