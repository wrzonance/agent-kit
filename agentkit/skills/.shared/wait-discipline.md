# Wait / polling discipline

Read this single detailed wait contract before any worker, CI, or review wait in `parallel-issues` or `review-remote-pr`.
Avoid empty wait cycles that do not advance collection.

## The rule

**A wait must never spend model turns.** This is the cost goal, not a guarantee: a runtime may yield even while a helper blocks. Use a bounded helper — `claude-adversarial-review.sh … > verdict.json`, `gh-pr-state.sh --wait-ci --rounds N --interval S`, or `agent-run.sh --cmd test`. A `sleep N` + re-check issued as its own tool call is churn: the helper already owns the polling loop.
Use the largest permitted yield. After a runtime yield, resume the same running session or cell;
never restart the helper.

Root calls already-blocking bounded helpers directly: CI `gh-pr-state.sh --wait-ci` and
duration-bounded adversarial runs need no waiter. Redirect output to a log and report one
terminal line preserving exit status; read the log after completion. Consent-bearing launches
stay in the consent-holding context. A fresh waiter is justified only for a genuinely unbounded or long-lived producer,
or when useful root work continues concurrently. Give that waiter a finite observation bound;
use the **Throwaway waiter prompt** and spawn-contract isolation rules, never a setup/fix worker.

Every wait names an explicit bound: adversarial duration, CI round cap, or native collection
deadline below. A CI round cap bounds polling sleeps, not network-request wall time. Require the
worker completion marker/contract or runner completion marker as terminal evidence.

**A bounded wait must be silent until its terminal condition.** Emit one completion or expiry
line: event-forwarding tools such as Claude Monitor deliver stdout lines to the model; buffered
shell output need not do so. Send any progress heartbeat to a log file, not stdout.

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

- **One wait per interval.** For helper polling, the helper owns the interval. For native collection, an empty capped wait may be re-issued as specified below; short polling outside that rule is churn.
- **After an empty yield, resume collection.** Inspect durable state for a completion or actionable blocker, not merely because time passed.
- **Narrate only a state change or a decision.** Report completion, blockers, or review decisions; never narrate "still waiting" or "checking again".
- **Never hand-poll CI.** `gh-pr-state.sh --wait-ci` already polls with bounded rounds (`--rounds`, `--interval`) and prints one progress line per round on stderr. Use it instead of a loop of `gh pr view` / `gh pr checks`.

### Post-dispatch root budget

After the authorized dispatch round and its bookkeeping are complete, discretionary root work while waiting for the first reported completion is a closed set: record each returned root turn with `"$agentkit/.shared/scripts/run-state.sh" append --run-id "$RUN_ID" --repo-root "$repository_root" --path root_turns --json true`, resume bounded collection, run the scheduled `stall-check.sh` sample only at its deadline, or send a `send_message`/`followup_task` that the worker's own message requested. Nothing else discretionary runs in that interval.
Required orchestration remains permitted: finish remaining approved initial or refill dispatches, persist returned worker IDs, and handle user steering.
The exclusions are explicit: no external fetches, primary-source verification, new analysis artifacts,
condition-gated reference reads, or root reads of repository files the worker may be rewriting.
Those belong to the issue lead or to the post-push review phase. When the first completion arrives,
run `"$agentkit/.shared/scripts/run-state.sh" set --run-id "$RUN_ID" --repo-root "$repository_root" --path first_completion` before Collect and stop appending turns; the final handoff summary prints the frozen count.

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

"An explicit bound" is a number, not an adjective. These are total observation windows, not
per-call blocking durations; the tool schema owns call defaults and limits.

| Wait class | Default bound |
|---|---|
| Worker implementation wait (`wait_agent` on an issue lead or fix-batch worker) | **900 s** collection window |
| Draft-loop, review, or CI wait | **600 s** |
| Helper-internal polling (`gh-pr-state.sh --wait-ci`, adversarial max-duration-seconds) | the helper's own `--rounds × --interval` / duration bound |

This table is the single source for the worker-wait bound: `compose-worker-prompt.sh` parses
the "Worker implementation wait" row at dispatch time and prints it beside each dispatched
worker's own issue number as a `wait-bound=` line, so the orchestrator reads a number back
instead of recalling this rule — see `parallel-issues/SKILL.md`'s "Compose the issue-lead
prompt" step. Never duplicate this number as a literal in a script; change it here and the
printed value follows.

### Native and tool collection

Use the current harness's advertised tools. `yield-cap=` is a legacy shell-yield
hint, not a native-agent limit. Select each blocking duration from the live tool
schema, observations of that same tool/session, the communication limit, and the
remaining original collection window. If less than the tool minimum remains,
expire collection without another call. An early event is not a timeout sample.

| Running operation | Collection |
|---|---|
| Codex native child | Native `wait_agent`; current V2 uses `timeout_ms` and mailbox events. Other versions may require target IDs. |
| Codex shell session | `write_stdin`: returned `session_id`, empty `chars`, `yield_time_ms`. |
| Codex running exec cell | `functions.wait`: returned `cell_id`, `yield_time_ms`; only after a running-cell result. |
| Claude background agent or shell | Completion notification, then its summary/output file if needed. Foreground calls already block where supported. |
| Claude legacy explicit collection | Advertised `TaskOutput` only: returned `task_id`, `block: true`, `timeout` in milliseconds. Deprecated, not the default. |
| Other harness | Advertised collector and returned handle; no borrowed API names. |

For Codex, continue bounded native collection while children are outstanding;
ending the root turn does not promise that completion mail starts a new one.
Claude yields the turn with work recorded as pending and handles the later
notification. Neither path declares the overall task complete before results.
A mailbox wake can be a question, blocker, completion, or user input; act on that
event and retain unfinished IDs. Empty capped yields resume the same operation,
with no narration between calls except required user updates. They do not justify
restarting helpers or inspecting disk/forge. Keep the original deadline. At its
expiry, report outstanding IDs and the next action. Collection expiry does not terminate a worker or authorize worktree writes.
Failure status remains failure.

Sources: [OpenAI native-agent schemas](https://github.com/openai/codex/blob/main/codex-rs/core/src/tools/handlers/multi_agents_spec.rs),
[OpenAI waiting guidance](https://github.com/openai/plugins/blob/main/plugins/superpowers/skills/using-superpowers/references/codex-tools%2Emd#waiting-on-children),
[Claude foreground/background subagents](https://code.claude.com/docs/en/sub-agents#run-subagents-in-foreground-or-background),
[Claude TaskOutput compatibility schema](https://code.claude.com/docs/en/agent-sdk/python#taskoutput), and
[Claude Monitor behavior](https://code.claude.com/docs/en/tools-reference#monitor-tool).

For implementation workers, record the last observed progress time at dispatch/completion
and the next stall-check deadline: progress time plus `STALL_THRESHOLD_MINUTES` (default 12).
Before that deadline, no `stall-check.sh` call. At or after it, sample once and schedule the
next sample no sooner than another threshold interval; observed progress resets the deadline.
The helper still requires its own consecutive quiet samples before declaring a stall.
External CI pending/expiry is a CI result, not evidence that an implementation worker stalled.

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
