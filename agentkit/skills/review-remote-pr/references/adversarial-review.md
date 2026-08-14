# Adversarial review — Step 1b mechanics

## Contents

- Materiality — run vs. document a skip
- Attribution across the review boundary
- External-service authorization
- Cross-provider consent — first send per session
- `--auto-review` — consent given in advance
- Availability → pick the reviewer
- Environment-blocked (exit 3) vs a real failure (exit 1)
- Tested one-shot invocation and monitoring
- Fallback — blind Codex review
- Read the verdict
- Evaluate — then route into Step 5
- Pitfalls

This is the detail behind the SKILL.md body's Step 1b gate (materiality, precheck, receipt). Read
this file in full before running or skipping an adversarial review.

## Materiality — run vs. document a skip

Size alone never decides materiality: a two-line authorization change is material; a mechanically
verified immutable SHA refresh can be trivial. **Run the review** when the diff changes runtime
behavior, API/schema/migration contracts, authorization/security boundaries,
persistence/concurrency, dependency behavior, workflow logic, or user-visible
accessibility/reliability, or whenever the user asks. **Document a skip** only when every changed
line is mechanically verifiable and low-judgment (comments/formatting, generated output with its
parity check, a verified immutable refresh); record the exact oracle — a line-count threshold is
never one. Preferred reviewer: the peer CLI named by `peer-cli=`, strongest reasoning model, one
high-effort pass, never re-run after pushing fixes.

## Attribution across the review boundary

The reviewer **cannot author anything**: it runs with tools disabled and returns a
verdict object. Every commit in this workflow is made by the CLI you are already
running, so the `harness=` trailer from the contract is the correct credit even
when the finding originated in the peer CLI. Interpreting someone else's review
and acting on it is your work, not theirs.

Two rules keep that true rather than accidental:

- `AGENT_TRAILER` is **never exported**. A child process that inherited it would
  stamp this session's identity onto work it did itself.
- Any agent that authors a commit derives its own trailer from its own
  `harness=` probe. That covers the in-harness case too: an issue lead spawned by
  `parallel-issues` runs in the same CLI, so it reaches the same answer on its
  own rather than by inheritance.

## External-service authorization

A cross-harness review sends the PR diff to an external model-provider service. This is a
cross-provider transfer of the diff's filenames and code. Repository ownership, maintainer
status, local filesystem access, or invoking this skill is not consent to disclose that content.

## Cross-provider consent — first send per session

Before the first cross-provider send in a session, disclose the transfer and obtain an explicit
confirmation. The disclosure must name:

- the source payload: the PR diff, including its filenames and code;
- the destination provider and CLI from the `peer-cli=` contract (for example, Anthropic via
  Claude or OpenAI via Codex); and
- the purpose: one adversarial review of that diff.

Ask a direct yes/no question such as: `This review will send the PR diff to <provider> via
<peer CLI> for adversarial analysis. Do you consent to that transfer for this session? (yes/no)`.
Proceed only after an unambiguous affirmative answer to that question. An earlier request to run
the skill, repository ownership, or an ambiguous response does not satisfy this gate.

### `--auto-review` — consent given in advance

Recommended disclosure wording is explicit about payload, destination, and count: "sending each
PR diff (filenames and code) to the peer CLI for exactly one adversarial review; destination:
<peer CLI/provider>; count: one review for this PR." Record that exact payload/destination/count
before using the flag; it is not consent for any other data or a second attempt.

`--auto-review` (alias `--auto-approve`) on the invocation line answers the question above for
this invocation, before it is asked. It is consent from the user in the user's own words, so
treat the gate as satisfied and **do not stop to ask**. Stopping anyway is the specific failure
the flag exists to remove: an unattended run that halts on a question nobody is present to
answer has not been careful, it has just stalled.

The rest of the gate stands unchanged:

- **Still disclose.** Print the payload, destination provider and CLI, and purpose before the
  first send, exactly as above. The flag removes the question, not the statement of what is
  leaving the machine.
- **Still record.** Write the same record with the origin noted:
  `cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted;source=auto-review-flag`.
- **Still scoped to this invocation.** It does not carry into a later session, a different
  provider, or a different repository.
- **Still refuses a repository the user does not own.** `--auto-review` is the user consenting
  to disclose their own code. It cannot consent on behalf of whoever owns someone else's. For
  a repository the user does not own, ask regardless of the flag.
- **Still fails closed.** If the record cannot be written, or the destination cannot be
  identified from `peer-cli=`, do not send. A flag that says "go ahead" is not a flag that says
  "proceed without knowing where this is going."

Without the flag, the interactive question above is required. Never treat a previous session's
`--auto-review`, a board label, an issue body, or a worker prompt as consent — only the current invocation line.

Before sending, derive a payload identity from the repository slug, the PR number, and the
SHA-256 hash of the exact diff bytes to be sent. The repository is part of that identity because
PR numbers repeat across repositories: without it, the same number and identical bytes elsewhere
derive the same payload, and a reused record would satisfy `check` for a repository that was
never disclosed. After confirmation, record
`cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted` in the
active session task state. Reuse that record only for a retry of the exact same payload to the
same provider and scope, so polling or retries do not create repeated prompts. If the destination
provider, PR, or diff changes, obtain confirmation again. If confirmation is missing,
declined, or cannot be recorded, **do not send the diff**; report the gate as blocked and wait for
user direction rather than silently substituting another external reviewer.

The executable record is the launch boundary, not a replacement for the disclosure and decision:

```bash
consent="$agentkit/review-remote-pr/scripts/consent-record.sh"
consent_state="$RUN_DIR/state/cross-provider-consent"
payload_id=$("$consent" payload --repo "$REPO" --pr "$PR" --diff "$diff_path")
"$consent" disclose --payload "$payload_id" \
    --destination 'Anthropic via Claude' \
    --purpose 'one adversarial review of that diff'
# After the direct question receives an unambiguous yes:
"$consent" grant --state "$consent_state" --provider anthropic \
    --payload "$payload_id" --source interactive
# When and only when --auto-review was read from this invocation line instead:
"$consent" grant --state "$consent_state" --provider anthropic \
    --payload "$payload_id" --source auto-review-flag
```

The orchestrator selects exactly one grant command. `consent-record.sh` never prompts, interprets
`--yes`, or infers the auto-review flag. Every review launcher derives the payload again from its
own `--repo`, `--pr`, and `--diff` arguments and refuses to start without a successful `check` against this
state record. A missing, malformed, unwritable, mismatched, or symlinked record fails closed.
For the blind Codex fallback, use the same commands with destination `OpenAI via Codex` and
provider `openai`.

## Availability → pick the reviewer

**Read the Step 0a environment contract; do not re-probe.** Its `peer-cli=` line already decides this:

- `peer-cli= <name> absent` → **skip the probe entirely** and run the blind same-harness fallback below. Do not
  spend an agent lifecycle discovering that the peer CLI cannot start. This is not a blocked gate — the
  fallback reviewer still runs the gate.
- `peer-cli= <name> present … probe=not-run` → the binary resolves on `PATH`, which is **not** proof it can
  execute in this sandbox. Continue to the probe; the helper's own preflight settles it.

## Environment-blocked (exit 3) vs a real failure (exit 1)

`claude-adversarial-review.sh` separates "Claude cannot run here" from "the review ran and the
answer is no". **Branch on the exit code, never on message text:**

| rc | Meaning | What you do |
|---|---|---|
| `0` | The review completed and every invariant held | stdout is exactly one JSON result object — consume the verdict |
| `3` | **Environment-blocked**: Claude cannot run here at all, so no verdict is obtainable | stdout is a blocked JSON object carrying `blockedReason`, `detail`, and `"fallback":"blind-codex-agent"`. Take the blind same-harness fallback **immediately**. Do not retry, do not re-dispatch the agent, and **never report the gate as BLOCKED for this reason** |
| `1` | A genuine failure — usage error, or the harness ran and an invariant/verdict check said no | stdout is **empty**; the reason is on stderr. Do not parse stdout as JSON on this path. *This* is a blocked gate: report it blocked, never `no_findings` |

`blockedReason` is a closed vocabulary: `peer-cli-missing`, `exec-denied`, `network-unreachable`,
`unauthenticated`, `budget-exhausted`, `cli-contract-missing`. Anything else is a helper bug.
`budget-exhausted` is the single exit-3 class where raising `--max-budget-usd` and re-running is a
legitimate response; for every other reason, retrying only burns turns.

## Tested one-shot invocation and monitoring

Use `scripts/claude-adversarial-review.sh`, under Bash. It implements the vendor's documented
programmatic pattern (`--print`, piped diff input, `stream-json --verbose
--include-partial-messages`, `--json-schema`), reports condition state every `--poll-seconds`, and
enforces a total-duration ceiling with `--max-duration-seconds` in addition to Claude's hard
`--max-budget-usd` spend cap. It resolves the executable itself (`$CLAUDE_EXECUTABLE`, else the
first `claude` on `PATH`); pass `--claude PATH` only for an install that is not on `PATH`.

**Stream contract:** stdout carries **exactly one** JSON object — the completed result, or the
blocked object on exit `3`. Progress objects go to **stderr**, one per `--poll-seconds`. Capture
stdout into a temporary path and publish it with `mv` only after the producer exits successfully;
never redirect a live stream to the final verdict path. There is no stream to fold with `jq -s last`,
and do not redirect stderr to `/dev/null` if you want the liveness signal.

The helper preflights the installed CLI and blocks before sending the diff unless the tested
isolation/streaming flags are present; do not silently drop a missing flag to support an older CLI.
It then verifies `system/init`: the requested model must initialize, the tool manifest must contain
exactly `StructuredOutput`, and no MCP server may load. Do not add `--disallowedTools '*'` — it
removes the internal `StructuredOutput` tool, yielding exit `0` with no structured verdict. Plugin
metadata may appear in `system/init`, but plugin tools must not appear in the tool manifest. The
advertised `--safe-mode` contract disables project instruction files, skills, plugins, hooks, MCP
servers, custom commands/agents, styles, workflows, and other customizations; the helper
additionally starts the reviewer in a new empty temp directory rather than the PR worktree.

Run a minimal probe once per review run (or whenever the CLI version/model/flags change) before
sending a real diff. A probe is complete only when it returns a deliberate P1 finding, valid
structured output, verified isolation, the initialized model in non-empty `modelUsage`, and exit
`0`; a requested full `claude-*` id must match the initialized model exactly. Probes are cheap —
`--max-budget-usd 0.25` is ample.

```bash
# The probe result is evidence; jq must be available before any JSON parse.
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'jq is not installed; evidence unavailable' >&2
    exit 1
fi
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/claude-adversarial-review.sh"
reviewer_model='claude-opus-5'
reviewer_effort='high'

base_branch=$(gh pr view "$PR" --repo "$REPO" --json baseRefName --jq '.baseRefName')
git fetch origin "$base_branch" || {
    printf 'Could not fetch origin/%s\n' "$base_branch" >&2
    exit 1
}

diff_path="$RUN_DIR/adversarial.diff"
# A blind reviewer has no repository, so it needs surrounding context -- but the
# width is the single largest cost lever in this whole gate, and it is charged to
# whichever account you have least headroom on. Measured on a 3-file/9-hunk change:
# -U3 1.0x, -U10 1.9x, -U25 3.7x, -U80 10.4x, where -U80 emitted 77% of the full
# text of every touched file. -U25 keeps real context at ~a third of -U80's cost.
# Raise it only for a diff whose hunks genuinely need more surrounding code.
git --no-pager diff --find-renames --unified=25 "origin/$base_branch...HEAD" >"$diff_path" || {
    printf '%s\n' 'Could not build the adversarial-review diff.' >&2
    exit 1
}

probe_out="$RUN_DIR/claude_probe.json"
probe_transcript="$RUN_DIR/claude_probe.ndjson"

probe_rc=0
"$helper" --mode probe --model "$reviewer_model" --effort "$reviewer_effort" \
    --transcript "$probe_transcript" --poll-seconds 120 --max-duration-seconds 900 --max-budget-usd 0.25 \
    >"$probe_out" || probe_rc=$?

case "$probe_rc" in
  0) printf '%s\n' 'probe ok — proceed to the review pass' ;;
  3) printf 'environment-blocked (%s) — take the blind same-harness fallback now; do not retry\n' \
       "$(jq -r '.blockedReason' <"$probe_out")" >&2 ;;
  *) printf '%s\n' 'probe failed on its own terms — report the adversarial gate as BLOCKED' >&2 ;;
esac
```

Only on `probe_rc` `0`, run the review pass:

```bash
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/claude-adversarial-review.sh"
reviewer_model='claude-opus-5'
reviewer_effort='high'

transcript="$RUN_DIR/claude.ndjson"
verdict_path="$RUN_DIR/adversarial.result.json"
consent_state="$RUN_DIR/state/cross-provider-consent"
# Clear any prior verdict before launch -- prepare_output() only clears it once
# parse_args/prepare_transcript succeed, so a helper that dies before that
# point (bad transcript dir, usage error, spawn failure) would otherwise leave
# a stale object on disk for a poller to consume as this launch's result.
rm -f -- "$verdict_path"

# stdout = one JSON object (verdict, or the blocked object on rc 3).
# stderr = one progress object per --poll-seconds.  --transcript = raw NDJSON for auditing.
# --output atomically publishes the same object to verdict_path -- written on
# rc 0 (completed) and rc 3 (blocked), never created or left behind on rc 1.
review_rc=0
"$helper" --mode review --model "$reviewer_model" --effort "$reviewer_effort" \
    --pr "$PR" --consent-state "$consent_state" --diff "$diff_path" \
    --transcript "$transcript" --output "$verdict_path" \
    --poll-seconds 120 --max-duration-seconds 900 --max-budget-usd 5.00 >/dev/null || review_rc=$?
printf 'adversarial-review rc=%s verdict=%s transcript=%s\n' \
    "$review_rc" "$verdict_path" "$transcript"
```

Launch the helper through an asynchronous executor and inspect the launcher's native terminal/child
state whenever that state is available. If the executor cell is detached or its native state is not
available, use the cross-cell heartbeat fallback at least as often as `--poll-seconds`. Each helper
atomically replaces `<transcript>.status` in the transcript's private directory on every monitor
tick (temporary file plus same-directory `mv`). The JSON status artifact contains
`elapsedSeconds`, `transcriptBytes`, `eventCount`, and `wallClockEpoch`; cleanup removes the status
artifact, its temporary sibling, and the PID sidecar on every normal exit. Stderr progress remains
diagnostic only.

The `.pid` sidecar is for same-process helper internals/corroboration. Cross-cell pollers must never
use producer-PID liveness or a process-name probe: executor cells can have separate PID namespaces.
Instead, maintain transcript byte-size samples at least one poll interval apart and compare the
status artifact's `wallClockEpoch` to the current wall clock. A heartbeat is fresh when it is newer
than `2 * --poll-seconds`. Any transcript growth means **Still running**, regardless of PID state or
heartbeat freshness.

Every poll then lands in exactly one of three states, and only the third is ever "blocked":

1. **Completed** — when native launcher state is available, the launcher reports a terminal child
   and the helper published a canonical verdict. Without native launcher state, a validated canonical verdict is Completed
   (success, or the rc=3 environment-blocked JSON). Consume that one verdict. An rc=3 JSON object is final and must never trigger a retry.
2. **Still running** — no verdict, and either the launcher is nonterminal, the heartbeat is fresh,
   or transcript bytes grew since the prior sample. A missing/empty verdict, absent terminal event,
   or heartbeat-only transcript tail is healthy in-flight evidence. Do not relaunch in this state.
3. **Blocked** — no verdict at all, a stale/missing heartbeat, and zero transcript growth across
   two byte-size samples at least one poll interval apart. Report the gate with artifacts preserved.

The dead predicate requires all three conditions; orphaned PID files, stale heartbeat alone, a
single unchanged sample, or a launcher-cell disappearance alone are insufficient. After that
predicate, relaunch exactly once only when no verdict exists. Total launches are at most two per PR
cycle and at most one verdict is consumed; no duplicate concurrent reviews are permitted. Never
start a replacement while the first launch could still be growing the transcript. The duration
ceiling remains a hard bound: a duration breach is a blocked review, never `no_findings`.

The wait is bounded in both directions: the helper kills its producer at the ceiling, so a healthy
review gets its whole window and a review that will never complete costs at most one window. Native
launcher state is preferred; status freshness plus transcript growth is the cross-cell fallback.

Completion is the producer's successful exit together with its terminal stream result event (for
Claude, `result/success` with `is_error == false` and a valid structured verdict; for Codex, a
successful exit plus its terminal result message). A final file's existence or size, or the tail of
a live log, is never completion. Each launch block above clears any stale `verdict_path` before
starting the helper; the helper's own `prepare_output()`/`publish_output()` then stage the verdict to
a temporary sibling and only make it canonical via same-directory `mv`, never leaving a partial or
temporary artifact behind on failure.

Do not accept plain prose or exit `0` alone. Completion requires all of: verified `system/init`, a
final `result/success` event, `is_error == false`, a valid `structured_output` verdict, and process
exit `0` — the helper enforces every one of these, which is why exit `1` means the gate is blocked
and exit `3` means the environment is. Preserve the NDJSON transcript either way. Report both the
requested/initialized model and every model in `canonicalModels`/`modelUsage`; an auxiliary small
model may be disclosed alongside the requested primary model.

Do not invoke `claude ultrareview`: it is a different nested orchestration surface. This workflow
needs one blind diff-only reviewer with deterministic output and monitoring.

## Fallback — blind Codex review

Take this path when the Step 0a contract said `peer-cli= <name> absent`,
when the helper exited `3` (any `blockedReason`), or when external-service authorization is absent.
There are two ways to run it; prefer the first.

**Only the first sub-path is available when consent is absent.** The in-harness agent keeps the
diff inside the CLI already running it; `codex-adversarial-review.sh` is a cross-provider send like
any other. Entering this fallback *because* external-service authorization is absent and then
reaching for the CLI would route around the very gate that sent you here.

**Preferred — a separate in-harness agent.** Start a **separate agent in the CLI you are
already running** on
`gpt-5.6-terra` at `xhigh` with no inherited turn history or project context (`fork_context=false`).
Its entire prompt contains only the review rubric below and the explicit PR diff — never the issue
number/body, repository name, branch/worktree path, design docs, ADRs, goals, PR description, or
previous findings. Instruct it not to use tools or read files. Blindness is mandatory: it judges
only what the diff does. This is cheaper than the CLI: a fresh `codex exec` process re-sends its
whole base instruction set (measured at ~43k input tokens for even a one-word reply).

**When in-harness spawn is unavailable** — the same condition as SKILL.md's Implementation-worker
gate's degraded path (`spawn_agent` genuinely unavailable, or `multi_agent = false`) — use
`scripts/codex-adversarial-review.sh`, the Codex twin of the Claude helper. **This sends the diff
to OpenAI, so the cross-provider consent gate above applies in full**: current-session consent must
name Codex as the destination provider and CLI. If in-harness spawn is unavailable *and* that
consent is absent, report the gate as blocked and stop — never substitute this helper for the
reviewer consent was withheld from. Same `--mode`,
`--model`, `--effort`, `--diff`, `--transcript` flags; same `0` / `1` / `3` exit codes; same split
of progress-on-stderr and one result object on stdout. It enforces blindness mechanically rather
than by instruction: `--sandbox read-only`, `--ephemeral`, `--ignore-user-config` (no user MCP
servers or settings), `--ignore-rules` (no `AGENTS.md` discovery), and a throwaway non-repo working
directory, with the verdict constrained by `--output-schema`.

```bash
# The reviewer result is evidence; jq must be available before any JSON parse.
if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'jq is not installed; evidence unavailable' >&2
    exit 1
fi
# >>> prepend THE RESOLVER (defined once in Step 0) <<<
[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || { printf '%s\n' 'agentkit unresolved: prepend the Step 0 resolver block' >&2; exit 1; }
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
helper="$agentkit/review-remote-pr/scripts/codex-adversarial-review.sh"
diff_path="$RUN_DIR/adversarial.diff"
verdict_path="$RUN_DIR/adversarial.result.json"
consent_state="$RUN_DIR/state/cross-provider-consent"
# Clear any prior verdict before launch -- see the Claude launch block above
# for why this must happen before prepare_output() would otherwise do it.
rm -f -- "$verdict_path"
# --output atomically publishes stdout's JSON object to verdict_path -- written
# on rc 0 (completed) and rc 3 (blocked), never created or left behind on rc 1.
review_rc=0
"$helper" --mode review --model gpt-5.6-terra --effort xhigh \
    --pr "$PR" --consent-state "$consent_state" --diff "$diff_path" \
    --output "$verdict_path" \
    --transcript "$RUN_DIR/codex.jsonl" --max-duration-seconds 900 --max-tokens 400000 >/dev/null || review_rc=$?
# rc 3 is the helper's STRUCTURED environment-blocked result, not a failure: the
# verdict object exists and carries blockedReason. Collapsing it into the generic
# rc 1 path discards the one field that says why, and reports "review failed"
# for an environment that simply cannot run one.
if ((review_rc == 3)); then
    printf 'Blind same-harness review environment-blocked: %s\n' \
        "$(jq -r '.blockedReason // "unspecified"' <"$verdict_path")" >&2
    exit 3
fi
if ((review_rc != 0)); then
    printf '%s\n' 'Blind same-harness review did not complete; report the gate as blocked.' >&2
    exit 1
fi
jq '{verdict: .verdict.verdict, findings: .verdict.findings, tokenUsage}' <"$verdict_path"
```

Two asymmetries against the peer-CLI path (harness-allow: comparing the two is the subject), both reported in the result object rather than hidden:
`codex exec` exposes no provider spend flag, so the helper applies a hard observed-token ceiling
with `--max-tokens` as well as a total-duration ceiling with `--max-duration-seconds`; both are
reported as safety failures rather than accepted verdicts. Its event stream carries no model field,
so the initialized model cannot be verified the way Claude Code's `system/init` allows
(`modelVerification: "unsupported-by-codex-exec"`). It reports the observed `tokenUsage` and the
configured/used token ceiling in the result object.

```text
Adversarially review the following diff BLIND. You have no issue, spec, ADR, goal, or project context by design. Do not use tools or read files. Find only concrete correctness, security, reliability, or contract regressions. Rank findings [P1]/[P2], cite file:line, explain the failure scenario, and suggest the smallest safe fix. Ignore style-only preferences.

<explicit diff only>
```

Capture the separate agent's findings in the private run directory at the neutral shared result
path (`$RUN_DIR/adversarial.result.json`), using the same nesting
(`.verdict.verdict`, `.verdict.findings[]` with `priority`), so the Step 5 routing below is
identical. If the harness cannot create a separate no-history agent, *then* report the
adversarial review as blocked; do not substitute the parent agent's contextual self-review.

(Both paths land findings in the same verdict path so the Step 5 routing below is identical.)

## Read the verdict

The captured stdout is **exactly one** JSON object — no stream to fold, so no `jq -s last`. The
verdict payload is **nested**: `.verdict.verdict` is the `findings`/`no_findings` string and
`.verdict.findings` is the array. The raw NDJSON transcript stays beside it for auditing.

```bash
: "${RUN_DIR:?re-set RUN_DIR to the Step 0c output; shell state does not persist}"
verdict_path="$RUN_DIR/adversarial.result.json"

if ! command -v jq >/dev/null 2>&1; then
    printf '%s\n' 'jq is not installed; evidence unavailable' >&2
    exit 1
fi

# Success path (rc 0) only. rc 3 -> read .blockedReason and take the blind Codex
# fallback; rc 1 -> stdout is empty and the reason is on stderr. See the table above.
jq '{verdict:  .verdict.verdict,
     p1_count: ([.verdict.findings[]? | select(.priority == "P1")] | length),
     findings: .verdict.findings,
     requestedModel, initModel, canonicalModels, totalCostUsd}' <"$verdict_path"
```

## Evaluate — then route into Step 5 (don't auto-apply)

Verify each finding against the actual code before acting. The reviewer can overstate severity, overlap with another provider, or miss things — cross-reference, downgrade overstated severities, drop false positives. Confirmed findings flow through the **same** assess → fix → document logic as automated-review items (Step 5). They have no GitHub review thread, so document each outcome (fixed + commit SHA, or declined + rationale) in a **PR comment** (`gh pr comment $PR --repo $REPO --body=...`) — there is nothing to `resolveReviewThread`.

## Pitfalls

| Problem | Fix |
|---|---|
| Running the adversarial review early or repeatedly | Apply the materiality gate ONCE as the LAST draft step (CI green first). For a material diff, fix confirmed findings and do not re-review the fixes. |
| Same-harness fallback given context | A reviewer that reads the issue/ADRs/design doc rubber-stamps intent. Create a separate no-history agent in the running CLI; give it only the diff and review rubric, and instruct it not to use tools or read files. |
| Claude external-review authorization is absent | Do not send the diff. Run the blind separate Codex-agent fallback and disclose the substitution in the exit report. |
| Tempted to run `claude ultrareview` | Don't. Use the blind, diff-only, structured one-shot helper in Step 1b; nested orchestration is a different surface. |
| Tempted to run `codex exec review` | Don't. That subcommand reviews the *current repository* with full context — the opposite of a blind diff-only reviewer, and non-deterministic in shape. Use `codex-adversarial-review.sh`. |
| `codex exec "prompt"` hangs forever | It reads stdin even when the prompt is an argument (it prints `Reading additional input from stdin...`) and blocks until EOF. Always redirect: `</dev/null`, or pass `-` and redirect the prompt file in. Measured: hangs past 180s without redirection, completes in ~5s with it. |
| Review diff built with a wide `-U` | Context width is the largest cost lever in the gate. Measured on a 3-file/9-hunk change, `-U80` cost 10.4× `-U3` and emitted 77% of the full text of every touched file. Step 1b uses `-U25`; raise it only for hunks that genuinely need more surrounding code. |
| Expecting a provider-dollar ceiling on the Codex path | `codex exec` has no `--max-budget-usd` equivalent. The helper enforces observed `--max-tokens` and `--max-duration-seconds`, while also bounding input with `--max-diff-bytes`; it reports actual `tokenUsage`. |
| Trusting the Codex reviewer's model identity | Its event stream carries no model field, so `modelVerification` is `unsupported-by-codex-exec`. Only the Claude helper can assert the initialized model matches the requested one. |
| Treating a fixed wall-clock timeout as a verdict | Keep the explicit `--max-duration-seconds` safety cap. A breach is a blocked review, never `no_findings`; do not shrink the diff to meet an estimate. |
| Claude is silent between polls | Report PID, elapsed time, seconds since last event, and transcript growth. Silence is a warning until the helper's duration ceiling, then the helper must terminate the review. |
| Claude exits 0 with no verdict | Exit code is necessary, not sufficient. Require verified `system/init` plus final `result/success.structured_output`; otherwise the gate is blocked. |
| Adversarial helper exits 3 reported as BLOCKED | Exit `3` is **environment-blocked**, not a blocked gate: Claude cannot run here, so stdout carries `{"status":"blocked","blockedReason":…,"fallback":"blind-codex-agent"}`. Take the blind same-harness fallback immediately, do not retry, and never report the gate blocked for this reason. Only exit `1` (stdout empty, reason on stderr) is a genuinely blocked gate. |
| Probing Claude when the preflight already said `peer-cli= <name> absent` | Skip the probe entirely and go straight to the fallback. The Step 0a contract already answered it; probing burns an agent lifecycle to rediscover `ENOTIMP`. |
| Using `--disallowedTools '*'` with `--json-schema` | It removes the internal `StructuredOutput` tool. Use `--tools ''` and verify the init manifest is exactly `StructuredOutput`. |
| Skipping review because the diff is short | Size is not risk. Skip only with a deterministic mechanical oracle; runtime, contract, security, persistence, workflow, or accessibility changes are material. |
| Auto-applying adversarial findings | Evaluate first — verify each `[P1]/[P2]` against the actual code, downgrade overstated severities, drop false positives. Confirmed findings go through Step 5; document outcomes in a PR comment (no thread to resolve). |
