#!/usr/bin/env bash
#
# claude-adversarial-review.sh — one-shot, tool-isolated adversarial diff review
# driven through Claude Code's non-interactive stream-json interface.
#
# The run is isolated (no tools, no MCP, no skills, no session persistence, and a
# throwaway working directory), the verdict is schema-constrained, and every
# isolation and verdict invariant is asserted before a result is printed.
#
# Modes:
#   probe   — reviews a fixed minimal diff carrying a deliberate P1 defect and
#             fails unless the model reports it. Use it to smoke-test the harness.
#   review  — reviews the diff at --diff.
#
# Output:
#   stdout  — exactly ONE JSON object: the final result object, or (on exit 3) the
#             blocked object. A caller can therefore do
#             `verdict=$(claude-adversarial-review.sh ...)` and feed it to jq
#             directly, with no `jq -s last` gymnastics.
#   stderr  — one compact JSON progress object per --poll-seconds while running,
#             plus the human-readable failure reason.
#
# Exit status:
#   0 — review completed and every invariant held.
#   1 — usage error, or a real invariant/verdict failure (the review itself says no).
#   3 — ENVIRONMENT-BLOCKED: Claude cannot run here (binary missing or not
#       executable, exec denied, no network, unauthenticated, exhausted budget, or
#       the installed CLI no longer offers the isolation contract). This is never a
#       review verdict; the caller takes the documented blind-Codex fallback
#       immediately instead of retrying or reporting the work as failed.
#
# Requires: bash >= 4.2, claude >= 2.1, jq, GNU coreutils.

set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly MAX_DIFF_BYTES=10485760 # Claude Code piped-stdin limit (10 MiB)
readonly REQUIRED_FLAGS=(
	--print
	--model
	--effort
	--system-prompt
	--tools
	--permission-mode
	--no-session-persistence
	--safe-mode
	--disable-slash-commands
	--strict-mcp-config
	--mcp-config
	--output-format
	--include-partial-messages
	--json-schema
	--max-budget-usd
	--no-chrome
	--verbose
)

MODE=""
CLAUDE_BIN=${CLAUDE_EXECUTABLE:-claude}
CLAUDE_RESOLVED=""
MODEL=""
EFFORT="xhigh"
DIFF_PATH=""
TRANSCRIPT_PATH=""
POLL_SECONDS=120
MAX_BUDGET_USD="5.00"
WORK_DIR=""
POLLER_PID=""
CLAUDE_PID=""

usage() {
	cat <<EOF
Usage: $PROGNAME --mode <probe|review> --model <model> --transcript <path> [options]

Required:
  --mode <probe|review>      probe: review a fixed diff with a known P1 defect.
                             review: review the diff at --diff.
  --model <model>            Model for the review (e.g. claude-opus-5). An id
                             starting with "claude-" is asserted against the
                             model the session actually initialized with.
  --transcript <path>        Where to write the raw stream-json transcript.
                             Must be a fresh path in an existing 0700 directory;
                             created exclusively with mode 0600.

Conditionally required:
  --diff <path>              Unified diff to review. Required in review mode.

Options:
  --claude <path>            claude executable (default: \$CLAUDE_EXECUTABLE, else
                             the first "claude" on PATH).
  --effort <level>           low|medium|high|xhigh|max (default: $EFFORT).
  --poll-seconds <1-3600>    Progress-report interval (default: $POLL_SECONDS).
  --max-budget-usd <amount>  Hard API spend cap, 0.01-1000 (default: $MAX_BUDGET_USD).
  -h, --help                 Show this help.

Output:
  stdout                     exactly one JSON object: the final result object, or
                             the blocked object described below.
  stderr                     one compact JSON progress object per --poll-seconds,
                             plus the human-readable failure reason.

Exit status:
  0                          review completed and every invariant held.
  1                          usage error, or a real invariant/verdict failure.
  3                          environment-blocked: Claude cannot run here. stdout
                             carries {"status":"blocked","blockedReason":...,
                             "detail":...,"transcript":...,
                             "fallback":"blind-codex-agent"} and blockedReason is
                             one of claude-missing, exec-denied,
                             network-unreachable, unauthenticated,
                             budget-exhausted, cli-contract-missing. Take the
                             blind-Codex fallback; do not retry.
EOF
}

die() {
	printf '%s: %s\n' "$PROGNAME" "$1" >&2
	exit 1
}

# Environment-class failure: Claude cannot run in this sandbox at all, so no
# verdict is obtainable here. Exit 3 keeps that distinguishable from exit 1 ("the
# review found something"), which a caller must not confuse — treating a blocked
# launch as a failed review is expensive.
die_blocked() {
	local reason=$1 detail=$2
	printf '%s: BLOCKED (%s): %s\n' "$PROGNAME" "$reason" "$detail" >&2
	printf '%s: take the blind-Codex adversarial-reviewer fallback; do not retry.\n' "$PROGNAME" >&2
	jq -cn \
		--arg blockedReason "$reason" \
		--arg detail "$detail" \
		--arg transcript "$TRANSCRIPT_PATH" \
		'{status:"blocked", blockedReason:$blockedReason, detail:$detail,
		  transcript:$transcript, fallback:"blind-codex-agent"}'
	exit 3
}

# Collapse a captured diagnostic to one short line so it stays readable inside a
# single-line JSON field and in the stderr message.
squash_text() {
	local text
	text=$(printf '%s' "${1:-}" | tr -s '[:space:]' ' ')
	text=${text# }
	text=${text% }
	printf '%.400s' "$text"
}

# Map a CLI diagnostic onto one of the documented blocked reasons, so the exit-3
# classification comes from what the CLI actually said and not only from its exit
# status. Prints $2 when nothing matches (empty $2 means "not an environment
# failure" — the caller should then treat it as a real failure and exit 1).
classify_blocked_reason() {
	local text=${1,,} reason=${2:-}
	case $text in
	*"credit balance"* | *"insufficient credit"* | *"budget exceeded"* | *"quota exceeded"*)
		reason=budget-exhausted
		;;
	*unauthenticated* | *"invalid api key"* | *"invalid x-api-key"* | *oauth* | *authentication_error* | *"not logged in"*)
		reason=unauthenticated
		;;
	*getaddrinfo* | *enotfound* | *econnrefused* | *"connection refused"* | *eai_again* | *"network is unreachable"* | *"unable to connect"*)
		reason=network-unreachable
		;;
	*enotimp* | *eperm* | *eacces* | *"not permitted"* | *"permission denied"* | *"cannot execute"* | *"exec format error"*)
		reason=exec-denied
		;;
	esac
	printf '%s' "$reason"
}

# Run a short preflight command with its output captured to a FILE, never a pipe
# (see the flush defect documented on preflight()), and bounded so a spawn that
# wedges in a restricted sandbox cannot hang the run. timeout(1) reports 124 on
# expiry; without coreutils timeout the command still runs, just unbounded.
run_bounded() {
	local seconds=$1 out_file=$2
	shift 2
	if command -v timeout >/dev/null 2>&1; then
		timeout "$seconds" "$@" >"$out_file" 2>&1
	else
		"$@" >"$out_file" 2>&1
	fi
}

cleanup() {
	if [[ -n $POLLER_PID ]]; then
		kill "$POLLER_PID" 2>/dev/null || true
		wait "$POLLER_PID" 2>/dev/null || true
		POLLER_PID=""
	fi
	if [[ -n $CLAUDE_PID ]]; then
		kill "$CLAUDE_PID" 2>/dev/null || true
		wait "$CLAUDE_PID" 2>/dev/null || true
		CLAUDE_PID=""
	fi
	[[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
	return 0
}

# Review transcripts contain the complete private diff and must never be placed
# in a shared temporary directory. The caller creates one 0700 run directory and
# passes a fresh path inside it. Refuse anything weaker before invoking Claude.
prepare_transcript() {
	local parent mode
	parent=$(dirname -- "$TRANSCRIPT_PATH")
	[[ -d $parent && ! -L $parent ]] ||
		die "Transcript parent must be an existing private directory: $parent"
	mode=$(stat -c %a -- "$parent") || die "Cannot inspect transcript parent: $parent"
	[[ $mode == 700 ]] || die "Transcript parent must have mode 0700: $parent"
	[[ -O $parent ]] || die "Transcript parent is not owned by this user: $parent"
	[[ ! -L $TRANSCRIPT_PATH ]] ||
		die "Refusing to write through a transcript symlink: $TRANSCRIPT_PATH"
	if [[ -e $TRANSCRIPT_PATH ]]; then
		[[ -f $TRANSCRIPT_PATH && -O $TRANSCRIPT_PATH ]] ||
			die "Refusing to overwrite transcript not owned by this user: $TRANSCRIPT_PATH"
		rm -f -- "$TRANSCRIPT_PATH" ||
			die "Cannot remove previous transcript: $TRANSCRIPT_PATH"
	fi
	# Bash noclobber maps this create to an exclusive open, so a pre-existing
	# symlink cannot redirect the write. The private parent removes the remaining
	# same-directory race from untrusted local users.
	(set -o noclobber; : >"$TRANSCRIPT_PATH") ||
		die "Cannot create transcript exclusively: $TRANSCRIPT_PATH"
	chmod 600 -- "$TRANSCRIPT_PATH" || die "Cannot secure transcript: $TRANSCRIPT_PATH"
}

require_value() {
	[[ -n ${2:-} ]] || die "option $1 requires a value"
}

parse_args() {
	while (($#)); do
		case $1 in
		--mode) require_value "$1" "${2:-}" && MODE=${2,,} && shift 2 ;;
		--mode=*) MODE=${1#*=} && MODE=${MODE,,} && shift ;;
		--claude) require_value "$1" "${2:-}" && CLAUDE_BIN=$2 && shift 2 ;;
		--claude=*) CLAUDE_BIN=${1#*=} && shift ;;
		--model) require_value "$1" "${2:-}" && MODEL=$2 && shift 2 ;;
		--model=*) MODEL=${1#*=} && shift ;;
		--effort) require_value "$1" "${2:-}" && EFFORT=${2,,} && shift 2 ;;
		--effort=*) EFFORT=${1#*=} && EFFORT=${EFFORT,,} && shift ;;
		--diff) require_value "$1" "${2:-}" && DIFF_PATH=$2 && shift 2 ;;
		--diff=*) DIFF_PATH=${1#*=} && shift ;;
		--transcript) require_value "$1" "${2:-}" && TRANSCRIPT_PATH=$2 && shift 2 ;;
		--transcript=*) TRANSCRIPT_PATH=${1#*=} && shift ;;
		--poll-seconds) require_value "$1" "${2:-}" && POLL_SECONDS=$2 && shift 2 ;;
		--poll-seconds=*) POLL_SECONDS=${1#*=} && shift ;;
		--max-budget-usd) require_value "$1" "${2:-}" && MAX_BUDGET_USD=$2 && shift 2 ;;
		--max-budget-usd=*) MAX_BUDGET_USD=${1#*=} && shift ;;
		-h | --help) usage && exit 0 ;;
		*) usage >&2 && die "unknown argument: $1" ;;
		esac
	done
}

validate_args() {
	[[ $MODE == probe || $MODE == review ]] || die "--mode must be probe or review"
	[[ -n $MODEL ]] || die "--model is required"
	[[ -n $TRANSCRIPT_PATH ]] || die "--transcript is required"
	case $EFFORT in
	low | medium | high | xhigh | max) ;;
	*) die "--effort must be one of: low medium high xhigh max" ;;
	esac
	[[ $POLL_SECONDS =~ ^[0-9]+$ ]] || die "--poll-seconds must be an integer"
	((POLL_SECONDS >= 1 && POLL_SECONDS <= 3600)) || die "--poll-seconds must be 1-3600"
	[[ $MAX_BUDGET_USD =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--max-budget-usd must be a number"
	awk -v v="$MAX_BUDGET_USD" 'BEGIN{exit !(v>=0.01 && v<=1000)}' ||
		die "--max-budget-usd must be between 0.01 and 1000"
	# Normalize away any locale-specific decimal handling before it reaches the CLI.
	MAX_BUDGET_USD=$(LC_ALL=C printf '%.2f' "$MAX_BUDGET_USD")
	[[ $MODE == review && -z $DIFF_PATH ]] && die "--diff is required in review mode"
	return 0
}

# Resolve the CLI and prove the isolation/streaming flags this harness depends on
# still exist, so a silent CLI change fails loudly instead of degrading isolation.
#
# --help MUST be captured to a file, never a pipe or command substitution: the CLI
# exits before flushing buffered pipe writes, so `claude --help | grep` sees a
# truncated option list (~120 of 242 lines here) and would fail the check for
# flags that are actually present. File writes are flushed synchronously.
preflight() {
	# jq first: every blocked report is emitted through it.
	command -v jq >/dev/null || die "jq is required but was not found on PATH"
	CLAUDE_RESOLVED=$(command -v -- "$CLAUDE_BIN" 2>/dev/null) ||
		die_blocked claude-missing "claude executable not found: $CLAUDE_BIN"
	[[ -x $CLAUDE_RESOLVED ]] ||
		die_blocked exec-denied "claude executable is not executable: $CLAUDE_RESOLVED"

	preflight_spawn
	preflight_flags
}

# Reachability check before anything paid happens: prove the resolved binary can
# actually spawn here. `--version` is bounded, local, and contacts no API, so this
# costs milliseconds and catches the sandbox-blocked launch (ENOTIMP/EPERM) that
# would otherwise surface as an opaque failure mid-review.
preflight_spawn() {
	local version_file=$WORK_DIR/claude-version.txt status=0 detail
	run_bounded 20 "$version_file" "$CLAUDE_RESOLVED" --version || status=$?
	((status == 0)) && return 0

	detail=$(squash_text "$(cat -- "$version_file" 2>/dev/null || true)")
	[[ -n $detail ]] || detail="no diagnostic emitted"
	((status == 124)) && detail="spawn timed out after 20s; $detail"
	die_blocked "$(classify_blocked_reason "$detail" exec-denied)" \
		"claude --version failed (status $status): $detail"
}

preflight_flags() {
	local help_file=$WORK_DIR/claude-help.txt status=0 detail flag
	run_bounded 60 "$help_file" "$CLAUDE_RESOLVED" --help || status=$?
	if ((status != 0)); then
		detail=$(squash_text "$(cat -- "$help_file" 2>/dev/null || true)")
		[[ -n $detail ]] || detail="no diagnostic emitted"
		die_blocked "$(classify_blocked_reason "$detail" exec-denied)" \
			"claude --help preflight failed (status $status): $detail"
	fi

	for flag in "${REQUIRED_FLAGS[@]}"; do
		grep -qF -e "$flag" -- "$help_file" ||
			die_blocked cli-contract-missing \
				"installed Claude Code does not support required isolation/streaming flag: $flag"
	done
}

verdict_schema() {
	jq -c . <<'JSON'
{
  "type": "object",
  "additionalProperties": false,
  "properties": {
    "verdict": { "type": "string", "enum": ["findings", "no_findings"] },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "properties": {
          "priority": { "type": "string", "enum": ["P1", "P2"] },
          "location": { "type": "string" },
          "failureScenario": { "type": "string" },
          "smallestFix": { "type": "string" }
        },
        "required": ["priority", "location", "failureScenario", "smallestFix"]
      }
    }
  },
  "required": ["verdict", "findings"]
}
JSON
}

system_prompt() {
	cat <<'EOF'
You are a one-shot static diff reviewer. No repository, tools, or external context exists. Never
emit tool-call syntax or request files. Analyze only the supplied diff and finish with the required
structured verdict.
EOF
}

write_review_input() {
	local target=$1
	if [[ $MODE == probe ]]; then
		cat >"$target" <<'EOF'
Adversarially review this minimal code and return the required structured verdict:

```diff
+function mayDeleteAccount(requestingUser, targetUser) {
+  return true;
+}
```
EOF
		return 0
	fi

	[[ -f $DIFF_PATH ]] || die "Review diff not found: $DIFF_PATH"
	local resolved bytes
	resolved=$(readlink -f -- "$DIFF_PATH") || die "Cannot resolve review diff: $DIFF_PATH"
	bytes=$(wc -c <"$resolved")
	((bytes > 0)) || die "Review diff is empty: $resolved"
	grep -q '[^[:space:]]' -- "$resolved" || die "Review diff is empty: $resolved"
	((bytes <= MAX_DIFF_BYTES)) ||
		die "Review diff exceeds Claude Code piped-stdin limit (10 MB). Split the review by coherent diff slices."

	cat >"$target" <<'EOF'
Adversarially review the supplied pull-request diff. Report only concrete P1 or P2 correctness,
security, reliability, accessibility, or API-contract regressions introduced by the diff. For
every finding, cite file:line, describe a reproducible failure scenario, and give the smallest safe
fix. Ignore style, naming, and speculative future concerns. If no qualifying defects exist, return
no_findings with an empty findings array.

DIFF STARTS BELOW
EOF
	cat -- "$resolved" >>"$target"
}

transcript_event_count() {
	local count
	count=$(grep -c '[^[:space:]]' -- "$TRANSCRIPT_PATH" 2>/dev/null) || count=0
	printf '%s' "${count:-0}"
}

transcript_last_label() {
	local line label
	line=$(tail -n 1 -- "$TRANSCRIPT_PATH" 2>/dev/null) || line=""
	[[ -n $line ]] || {
		printf 'startup'
		return 0
	}
	label=$(jq -r 'if (.subtype // "") != "" then "\(.type)/\(.subtype)" else (.type // "unknown") end' \
		<<<"$line" 2>/dev/null) || label=""
	printf '%s' "${label:-partial}"
}

# Progress goes to stderr so stdout carries exactly one JSON object (the result or
# the blocked report) and `$(...)` capture needs no filtering.
emit_progress() {
	local started=$1 now mtime bytes
	now=$(date +%s)
	mtime=$(stat -c %Y -- "$TRANSCRIPT_PATH" 2>/dev/null) || mtime=$started
	bytes=$(stat -c %s -- "$TRANSCRIPT_PATH" 2>/dev/null) || bytes=0
	jq -cn \
		--argjson runnerPid "$$" \
		--argjson elapsedSeconds "$((now - started))" \
		--argjson secondsSinceLastEvent "$((now - mtime))" \
		--argjson eventCount "$(transcript_event_count)" \
		--arg lastEvent "$(transcript_last_label)" \
		--argjson transcriptBytes "$bytes" \
		'{status:"running", runnerPid:$runnerPid, elapsedSeconds:$elapsedSeconds,
		  secondsSinceLastEvent:$secondsSinceLastEvent, eventCount:$eventCount,
		  lastEvent:$lastEvent, transcriptBytes:$transcriptBytes}' >&2
}

# The interval sleep runs in the BACKGROUND and is waited on, never in the
# foreground. Bash defers a trapped signal until the current FOREGROUND child
# exits, so a foreground `sleep` here would keep this poller — and therefore the
# caller's `wait "$POLLER_PID"` — alive for a whole --poll-seconds AFTER the
# review already finished (a silent 120s tax at the default interval). Waiting on
# an asynchronous child instead makes `wait` return the moment TERM arrives.
poll_progress() {
	local started=$1 sleep_pid=""
	trap 'if [[ -n $sleep_pid ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM
	while :; do
		sleep "$POLL_SECONDS" &
		sleep_pid=$!
		wait "$sleep_pid" 2>/dev/null || true
		sleep_pid=""
		emit_progress "$started"
	done
}

# Runs Claude with tools, MCP, skills, session persistence and customizations all
# disabled, in a throwaway working directory, with the verdict schema enforced.
run_claude() {
	local input_file=$1 stderr_file=$2 isolation_dir=$3 schema=$4 prompt=$5
	local -a args=(
		--print
		--model "$MODEL"
		--effort "$EFFORT"
		--system-prompt "$prompt"
		--tools ""
		--permission-mode dontAsk
		--no-session-persistence
		--safe-mode
		--no-chrome
		--disable-slash-commands
		--strict-mcp-config
		--mcp-config '{"mcpServers":{}}'
		--output-format stream-json
		--verbose
		--include-partial-messages
		--json-schema "$schema"
		--max-budget-usd "$MAX_BUDGET_USD"
	)

	# Backgrounded and waited on rather than run in the foreground: bash defers
	# trap handling until a foreground child returns, so an interactive Ctrl-C or
	# a CI cancellation would otherwise leave the API call running to completion.
	# Blocking in `wait` lets the INT/TERM trap fire immediately and clean up.
	local status=0
	(cd "$isolation_dir" && exec "$CLAUDE_RESOLVED" "${args[@]}") \
		<"$input_file" >>"$TRANSCRIPT_PATH" 2>"$stderr_file" &
	CLAUDE_PID=$!
	wait "$CLAUDE_PID" || status=$?
	CLAUDE_PID=""
	return "$status"
}

# Best-effort human-readable reason for a nonzero exit. Claude Code reports most
# failures (bad model, auth, budget) in the JSON stream rather than on stderr, so
# fall back to the last result event before giving up.
claude_failure_detail() {
	local stderr_file=$1 detail
	detail=$(cat -- "$stderr_file" 2>/dev/null || true)
	if [[ -z ${detail//[[:space:]]/} ]]; then
		detail=$(jq -r -s '[.[] | select(.type == "result")] | last
			| (.result // .error // .terminal_reason // empty)' <"$TRANSCRIPT_PATH" 2>/dev/null) || detail=""
	fi
	[[ -n ${detail//[[:space:]]/} ]] || detail="no diagnostic emitted"
	printf '%s (transcript: %s)' "$detail" "$TRANSCRIPT_PATH"
}

# A nonzero Claude exit is either "this sandbox will never let the review run"
# (exit 3, fall back) or a genuine failure (exit 1). Decide from what the CLI
# reported, not from the exit status alone, which is 1 for both classes.
fail_claude_exit() {
	local exit_code=$1 stderr_file=$2 detail reason
	detail=$(squash_text "$(claude_failure_detail "$stderr_file")")
	reason=$(classify_blocked_reason "$detail" "")
	if [[ -n $reason ]]; then
		die_blocked "$reason" "claude exited $exit_code: $detail"
	fi
	die "Claude exited $exit_code: $detail"
}

verify_isolation() {
	local init=$1 tools mcp_count
	tools=$(jq -c '.tools // []' <<<"$init")
	if [[ $(jq -r 'length' <<<"$tools") -ne 1 || $(jq -r '.[0]' <<<"$tools") != "StructuredOutput" ]]; then
		die "Claude tool isolation failed. Manifest: $(jq -r 'join(", ")' <<<"$tools")"
	fi
	mcp_count=$(jq -r '(.mcp_servers // []) | length' <<<"$init")
	((mcp_count == 0)) || die "Claude MCP isolation failed; at least one MCP server was loaded."
}

verify_verdict() {
	local verdict=$1 kind findings_count p1_count
	kind=$(jq -r '.verdict // ""' <<<"$verdict")
	[[ $kind == findings || $kind == no_findings ]] || die "Claude returned an invalid verdict value."
	findings_count=$(jq -r '(.findings // []) | length' <<<"$verdict")
	[[ $kind == no_findings && $findings_count -ne 0 ]] &&
		die "Claude returned findings with a no_findings verdict."
	[[ $kind == findings && $findings_count -eq 0 ]] &&
		die "Claude returned a findings verdict with an empty findings array."

	if [[ $MODE == probe ]]; then
		p1_count=$(jq -r '[(.findings // [])[] | select(.priority == "P1")] | length' <<<"$verdict")
		[[ $kind == findings && $p1_count -gt 0 ]] ||
			die "Claude probe did not return the deliberate P1 finding."
	fi
	return 0
}

verify_model_identity() {
	local init=$1 result=$2 init_model canonical_models
	init_model=$(jq -r '.model // ""' <<<"$init")
	canonical_models=$(jq -c '(.modelUsage // {}) | keys' <<<"$result")
	if [[ -z $init_model || $(jq -r 'length' <<<"$canonical_models") -eq 0 ]]; then
		die "Claude omitted initialized/canonical model identity."
	fi
	jq -e --arg m "$init_model" 'index($m) != null' <<<"$canonical_models" >/dev/null ||
		die "Initialized model $init_model is absent from modelUsage."
	if [[ $MODEL == claude-* && $init_model != "$MODEL" ]]; then
		die "Requested model $MODEL initialized as $init_model."
	fi
	printf '%s' "$init_model"
}

main() {
	parse_args "$@"
	validate_args

	WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-adversarial-XXXXXXXXXX")
	chmod 700 -- "$WORK_DIR" || die "Cannot secure review work directory: $WORK_DIR"
	trap cleanup EXIT
	trap 'exit 130' INT TERM
	local isolation_dir=$WORK_DIR/cwd
	local input_file=$WORK_DIR/input.txt
	local stderr_file=$WORK_DIR/stderr.log
	mkdir -p -- "$isolation_dir"

	prepare_transcript
	preflight

	write_review_input "$input_file"
	local schema prompt started exit_code=0
	schema=$(verdict_schema)
	prompt=$(system_prompt)

	started=$(date +%s)
	poll_progress "$started" &
	POLLER_PID=$!

	run_claude "$input_file" "$stderr_file" "$isolation_dir" "$schema" "$prompt" || exit_code=$?

	kill "$POLLER_PID" 2>/dev/null || true
	wait "$POLLER_PID" 2>/dev/null || true
	POLLER_PID=""

	local init result
	((exit_code == 0)) || fail_claude_exit "$exit_code" "$stderr_file"

	# Files are fed on stdin rather than as jq operands: it keeps paths beginning
	# with "-" harmless without relying on jq's "--" separator (jq 1.6, still
	# current on Debian bookworm, does not accept it).
	jq -e . <"$TRANSCRIPT_PATH" >/dev/null 2>&1 ||
		die "Claude stream transcript is empty or contains invalid JSON: $TRANSCRIPT_PATH"

	init=$(jq -c -s 'map(select(.type == "system" and .subtype == "init")) | first // empty' <"$TRANSCRIPT_PATH")
	[[ -n $init ]] || die "Claude stream omitted system/init; isolation cannot be verified."
	verify_isolation "$init"

	result=$(jq -c -s 'map(select(.type == "result")) | last // empty' <"$TRANSCRIPT_PATH")
	if [[ -z $result ]] ||
		[[ $(jq -r '.subtype // ""' <<<"$result") != "success" ]] ||
		[[ $(jq -r '.is_error // false' <<<"$result") == "true" ]]; then
		die "Claude stream did not end with a successful result event."
	fi

	local verdict init_model
	verdict=$(jq -c '.structured_output // empty' <<<"$result")
	[[ -n $verdict ]] || die "Claude returned no structured verdict."
	verify_verdict "$verdict"
	init_model=$(verify_model_identity "$init" "$result")

	jq -n \
		--argjson exitCode "$exit_code" \
		--arg requestedModel "$MODEL" \
		--arg initModel "$init_model" \
		--argjson canonicalModels "$(jq -c '(.modelUsage // {}) | keys' <<<"$result")" \
		--argjson eventCount "$(transcript_event_count)" \
		--arg transcript "$TRANSCRIPT_PATH" \
		--argjson durationApiMs "$(jq -c '.duration_api_ms // null' <<<"$result")" \
		--argjson totalCostUsd "$(jq -c '.total_cost_usd // null' <<<"$result")" \
		--argjson verdict "$verdict" \
		'{status:"completed", exitCode:$exitCode, requestedModel:$requestedModel,
		  initModel:$initModel, canonicalModels:$canonicalModels, eventCount:$eventCount,
		  transcript:$transcript, durationApiMs:$durationApiMs, totalCostUsd:$totalCostUsd,
		  verdict:$verdict}'
}

main "$@"
