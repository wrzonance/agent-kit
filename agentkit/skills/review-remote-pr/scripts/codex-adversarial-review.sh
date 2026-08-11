#!/usr/bin/env bash
#
# codex-adversarial-review.sh — one-shot, tool-isolated adversarial diff review
# driven through the Codex CLI's non-interactive `codex exec` interface.
#
# The Codex-side twin of claude-adversarial-review.sh. Same contract, same exit
# codes, same stdout/stderr split, so the calling skill can treat either harness
# identically and only the binary changes.
#
# The run is isolated: read-only sandbox, no user config (so no user MCP servers,
# no custom settings), no rules/AGENTS.md discovery (this is what makes the review
# genuinely blind), no session persistence, and a throwaway working directory that
# is not a git repository. The verdict is schema-constrained and every invariant is
# asserted before a result is printed.
#
# Modes:
#   probe   — reviews a fixed minimal diff carrying a deliberate P1 defect and
#             fails unless the model reports it. Use it to smoke-test the harness.
#   review  — reviews the diff at --diff.
#
# Output:
#   stdout  — the final result object (JSON), and nothing else.
#   stderr  — progress records while running, then any human-readable failure.
#
# Exit status:
#   0  completed and every invariant held
#   1  usage error, or a real invariant/verdict failure
#   3  ENVIRONMENT-BLOCKED: Codex cannot run here (binary missing, exec denied,
#      no network, unauthenticated, or the CLI no longer offers the isolation
#      contract). stdout carries a blocked JSON object. Callers take the other
#      harness's reviewer immediately and never report this as a failed review.
#
# COST NOTE: `codex exec` exposes no provider spend-ceiling flag. This helper
# applies an observed token ceiling to the one-shot stream and a duration ceiling
# around the process; both are hard safety failures rather than verdicts.
#
# Requires: bash >= 4.2, codex CLI, jq, GNU coreutils.

set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly WARN_DIFF_BYTES=262144   # 256 KiB — advise splitting beyond this
readonly DEFAULT_MAX_DURATION_SECONDS=900
readonly DEFAULT_MAX_TOKENS=30000
readonly REQUIRED_FLAGS=(
    --model
    --config
    --sandbox
    --ephemeral
    --ignore-user-config
    --ignore-rules
    --skip-git-repo-check
    --output-schema
    --output-last-message
    --json
)

MODE=""
CODEX_BIN=${CODEX_EXECUTABLE:-codex}
CODEX_RESOLVED=""
MODEL=""
EFFORT="xhigh"
DIFF_PATH=""
TRANSCRIPT_PATH=""
POLL_SECONDS=120
MAX_DIFF_BYTES=1048576            # 1 MiB — a runaway-diff backstop, not a protocol limit
MAX_DURATION_SECONDS=$DEFAULT_MAX_DURATION_SECONDS
MAX_TOKENS=$DEFAULT_MAX_TOKENS
WORK_DIR=""
POLLER_PID=""
CODEX_PID=""
LIMIT_PID=""
LIMIT_REASON_FILE=""
DEADLINE_EPOCH=0

usage() {
    cat <<EOF
Usage: $PROGNAME --mode <probe|review> --model <model> --transcript <path> [options]

Required:
  --mode <probe|review>      probe: review a fixed diff with a known P1 defect.
                             review: review the diff at --diff.
  --model <model>            Model for the review (e.g. gpt-5.6-terra).
  --transcript <path>        Where to write the raw JSONL event stream.
                             Must be a fresh path in an existing 0700 directory;
                             created exclusively with mode 0600.

Conditionally required:
  --diff <path>              Unified diff to review. Required in review mode.

Options:
  --codex <path>             codex executable (default: \$CODEX_EXECUTABLE, else
                             the first "codex" on PATH).
  --effort <level>           Reasoning effort, passed as model_reasoning_effort
                             (default: $EFFORT).
  --poll-seconds <1-3600>    Progress-report interval on stderr (default: $POLL_SECONDS).
  --max-diff-bytes <n>       Reject a review diff larger than this (default: $MAX_DIFF_BYTES).
                             A warning is printed above $WARN_DIFF_BYTES bytes; split the
                             review into coherent slices instead of sending one enormous diff.
  --max-duration-seconds <1-86400>
                             Hard wall-clock ceiling for the review (default: $MAX_DURATION_SECONDS).
  --max-tokens <1024-1000000>
                             Hard observed token ceiling (default: $MAX_TOKENS).
  -h, --help                 Show this help.

Exit: 0 verdict obtained, 1 usage/invariant failure, 3 environment-blocked.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

# Environment-blocked: Codex cannot run here at all, so no verdict is obtainable.
# The caller must switch to the other harness rather than treat this as a finding.
die_blocked() {
    local reason=$1 detail=$2
    printf '%s: BLOCKED (%s): %s\n' "$PROGNAME" "$reason" "$detail" >&2
    printf '%s: take the cross-harness adversarial reviewer instead; do not retry.\n' "$PROGNAME" >&2
    jq -cn \
        --arg blockedReason "$reason" \
        --arg detail "$detail" \
        --arg transcript "$TRANSCRIPT_PATH" \
        '{status: "blocked", blockedReason: $blockedReason, detail: $detail,
          transcript: $transcript, fallback: "cross-harness-reviewer"}'
    exit 3
}

cleanup() {
    if [[ -n $POLLER_PID ]]; then
        kill "$POLLER_PID" 2>/dev/null || true
        wait "$POLLER_PID" 2>/dev/null || true
        POLLER_PID=""
    fi
    if [[ -n $LIMIT_PID ]]; then
        kill "$LIMIT_PID" 2>/dev/null || true
        wait "$LIMIT_PID" 2>/dev/null || true
        LIMIT_PID=""
    fi
    if [[ -n $CODEX_PID ]]; then
        kill "$CODEX_PID" 2>/dev/null || true
        wait "$CODEX_PID" 2>/dev/null || true
        CODEX_PID=""
    fi
    [[ -n $WORK_DIR && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
    return 0
}

seconds_until_deadline() {
    local now left
    now=$(date +%s)
    left=$((DEADLINE_EPOCH - now))
    ((left > 0)) || return 1
    printf '%s' "$left"
}

die_duration() {
    die "Codex review exceeded --max-duration-seconds $MAX_DURATION_SECONDS"
}

# Review transcripts contain the complete private diff and must never be placed
# in a shared temporary directory. The caller creates one 0700 run directory and
# passes a fresh path inside it. Refuse anything weaker before invoking Codex.
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
        --codex) require_value "$1" "${2:-}" && CODEX_BIN=$2 && shift 2 ;;
        --codex=*) CODEX_BIN=${1#*=} && shift ;;
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
        --max-diff-bytes) require_value "$1" "${2:-}" && MAX_DIFF_BYTES=$2 && shift 2 ;;
        --max-diff-bytes=*) MAX_DIFF_BYTES=${1#*=} && shift ;;
        --max-duration-seconds) require_value "$1" "${2:-}" && MAX_DURATION_SECONDS=$2 && shift 2 ;;
        --max-duration-seconds=*) MAX_DURATION_SECONDS=${1#*=} && shift ;;
        --max-tokens) require_value "$1" "${2:-}" && MAX_TOKENS=$2 && shift 2 ;;
        --max-tokens=*) MAX_TOKENS=${1#*=} && shift ;;
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
    [[ $MAX_DIFF_BYTES =~ ^[0-9]+$ ]] || die "--max-diff-bytes must be an integer"
    ((MAX_DIFF_BYTES >= 1024)) || die "--max-diff-bytes must be at least 1024"
    [[ $MAX_DURATION_SECONDS =~ ^[0-9]+$ ]] || die "--max-duration-seconds must be an integer"
    ((MAX_DURATION_SECONDS >= 1 && MAX_DURATION_SECONDS <= 86400)) ||
        die "--max-duration-seconds must be 1-86400"
    [[ $MAX_TOKENS =~ ^[0-9]+$ ]] || die "--max-tokens must be an integer"
    ((MAX_TOKENS >= 1024 && MAX_TOKENS <= 1000000)) ||
        die "--max-tokens must be 1024-1000000"
    [[ $MODE == review && -z $DIFF_PATH ]] && die "--diff is required in review mode"
    return 0
}

# Resolve the CLI and prove the isolation flags this harness depends on still
# exist, so a silent CLI change fails loudly (exit 3) instead of quietly running
# an unisolated, repo-aware review. Help is captured to a FILE, never a pipe: some
# CLIs exit before flushing buffered pipe writes and report a truncated flag list.
preflight() {
    CODEX_RESOLVED=$(command -v -- "$CODEX_BIN" 2>/dev/null) ||
        die_blocked codex-missing "codex executable not found: $CODEX_BIN"
    [[ -x $CODEX_RESOLVED ]] ||
        die_blocked codex-missing "codex executable is not executable: $CODEX_RESOLVED"
    command -v jq >/dev/null || die "jq is required but was not found on PATH"
    command -v timeout >/dev/null || die "timeout is required to enforce the review duration ceiling"

    local help_file=$WORK_DIR/codex-help.txt
    "$CODEX_RESOLVED" exec --help >"$help_file" 2>&1 ||
        die_blocked exec-denied "codex exec --help could not run; the CLI cannot start here."

    local flag
    for flag in "${REQUIRED_FLAGS[@]}"; do
        grep -qF -e "$flag" -- "$help_file" ||
            die_blocked cli-contract-missing \
                "installed Codex CLI does not support required isolation flag: $flag"
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

write_review_input() {
    local target=$1
    cat >"$target" <<'EOF'
You are a one-shot static diff reviewer. No repository, tools, or external context
exists. Never emit tool-call syntax, never attempt to read files, and never run
commands. Analyze only the diff supplied below and finish with the required
structured verdict.
EOF
    if [[ $MODE == probe ]]; then
        cat >>"$target" <<'EOF'

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
        die "Review diff is ${bytes} bytes, over --max-diff-bytes ($MAX_DIFF_BYTES). Split the review by coherent diff slices."
    ((bytes <= WARN_DIFF_BYTES)) ||
        printf '%s: warning: diff is %s bytes; keep the review within --max-tokens and consider splitting.\n' \
            "$PROGNAME" "$bytes" >&2

    cat >>"$target" <<'EOF'

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
        --argjson transcriptBytes "$bytes" \
        '{status: "running", harness: "codex", runnerPid: $runnerPid,
          elapsedSeconds: $elapsedSeconds, secondsSinceLastEvent: $secondsSinceLastEvent,
          eventCount: $eventCount, transcriptBytes: $transcriptBytes}' >&2
}

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

classify_blocked_reason() {
    local text=$1
    case $text in
    *ENOTIMP* | *"Operation not permitted"* | *"Permission denied"* | *EPERM* | *EACCES*)
        printf 'exec-denied' ;;
    *"not logged in"* | *"Not logged in"* | *401* | *[Uu]nauthorized* | *"authentication"*)
        printf 'unauthenticated' ;;
    *"Connection refused"* | *getaddrinfo* | *"dns error"* | *"failed to lookup"* | *"network"*)
        printf 'network-unreachable' ;;
    *) printf '' ;;
    esac
}

# Runs Codex with user config, rules files, session persistence and repo context
# all disabled, in a throwaway non-repo directory, with the verdict schema enforced.
run_codex() {
    local input_file=$1 stderr_file=$2 isolation_dir=$3 schema_file=$4 final_file=$5
    local seconds
    local -a args=(
        exec
        --model "$MODEL"
        --config "model_reasoning_effort=\"$EFFORT\""
        --sandbox read-only
        --ephemeral
        --ignore-user-config
        --ignore-rules
        --skip-git-repo-check
        --cd "$isolation_dir"
        --output-schema "$schema_file"
        --output-last-message "$final_file"
        --json
        -
    )

    local status=0
    seconds=$(seconds_until_deadline) || return 124
    timeout --signal=KILL "$seconds" "$CODEX_RESOLVED" "${args[@]}" \
        <"$input_file" >>"$TRANSCRIPT_PATH" 2>"$stderr_file" &
    CODEX_PID=$!
    monitor_token_limit &
    LIMIT_PID=$!
    wait "$CODEX_PID" || status=$?
    CODEX_PID=""
    kill "$LIMIT_PID" 2>/dev/null || true
    wait "$LIMIT_PID" 2>/dev/null || true
    LIMIT_PID=""
    [[ $(<"$LIMIT_REASON_FILE") == token-budget ]] && return 125
    return "$status"
}

verify_token_budget() {
    local usage
    usage=$(token_usage_total)
    [[ $usage =~ ^[0-9]+$ ]] ||
        die "Codex omitted token usage; cannot verify --max-tokens $MAX_TOKENS"
    ((usage <= MAX_TOKENS)) ||
        die "Codex review exceeded --max-tokens $MAX_TOKENS (observed $usage)"
    printf '%s' "$usage"
}

verify_verdict() {
    local verdict=$1 kind findings_count p1_count
    kind=$(jq -r '.verdict // ""' <<<"$verdict")
    [[ $kind == findings || $kind == no_findings ]] || die "Codex returned an invalid verdict value."
    findings_count=$(jq -r '(.findings // []) | length' <<<"$verdict")
    [[ $kind == no_findings && $findings_count -ne 0 ]] &&
        die "Codex returned findings with a no_findings verdict."
    [[ $kind == findings && $findings_count -eq 0 ]] &&
        die "Codex returned a findings verdict with an empty findings array."

    if [[ $MODE == probe ]]; then
        p1_count=$(jq -r '[(.findings // [])[] | select(.priority == "P1")] | length' <<<"$verdict")
        [[ $kind == findings && $p1_count -gt 0 ]] ||
            die "Codex probe did not return the deliberate P1 finding."
    fi
    return 0
}

# Best-effort model identity from the JSONL event stream. Measured against
# codex-cli 0.147.0 the stream carries thread.started / turn.started /
# item.completed / turn.completed and NO model field, so this normally yields
# nothing. Claude Code's system/init does report the initialized model, so model
# identity is verifiable there and merely advisory here -- the result object says
# so explicitly rather than leaving a silent null.
observed_model() {
    jq -r -s '[.[] | (.model? // .msg?.model? // .payload?.model? // empty)] | last // ""' \
        <"$TRANSCRIPT_PATH" 2>/dev/null || printf ''
}

# turn.completed carries the usage signal codex exec exposes. Normalize the
# common field spellings to one total so the helper can enforce its ceiling.
token_usage_total() {
    jq -r -s '
        [ .[] | select(.type == "turn.completed") | .usage // empty |
          if (.total_tokens? // .totalTokens? // null) != null then
              (.total_tokens // .totalTokens)
          else
              ((.input_tokens // .inputTokens // 0) +
               (.output_tokens // .outputTokens // 0) +
               (.reasoning_tokens // .reasoningTokens // 0) +
               (.reasoning_output_tokens // .reasoningOutputTokens // 0))
          end
        ] | if length == 0 then "null" else add end' \
        <"$TRANSCRIPT_PATH" 2>/dev/null || printf 'null'
}

monitor_token_limit() {
    local usage
    while [[ -n $CODEX_PID ]] && kill -0 "$CODEX_PID" 2>/dev/null; do
        usage=$(token_usage_total)
        if [[ $usage =~ ^[0-9]+$ ]] && ((usage > MAX_TOKENS)); then
            printf '%s\n' token-budget >"$LIMIT_REASON_FILE"
            kill -KILL "$CODEX_PID" 2>/dev/null || true
            return 0
        fi
        sleep 1
    done
}

token_usage() {
    jq -c -s '[.[] | select(.type == "turn.completed") | .usage] | last // null' \
        <"$TRANSCRIPT_PATH" 2>/dev/null || printf 'null'
}

main() {
    parse_args "$@"
    validate_args
    local started exit_code=0
    started=$(date +%s)
    DEADLINE_EPOCH=$((started + MAX_DURATION_SECONDS))

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-adversarial-XXXXXXXXXX")
    chmod 700 -- "$WORK_DIR" || die "Cannot secure review work directory: $WORK_DIR"
    trap cleanup EXIT
    trap 'exit 130' INT TERM
    local isolation_dir=$WORK_DIR/cwd
    local input_file=$WORK_DIR/input.txt
    local stderr_file=$WORK_DIR/stderr.log
    local schema_file=$WORK_DIR/schema.json
    local final_file=$WORK_DIR/final.json
    LIMIT_REASON_FILE=$WORK_DIR/limit.reason
    : >"$LIMIT_REASON_FILE"
    mkdir -p -- "$isolation_dir"

    prepare_transcript
    preflight

    write_review_input "$input_file"
    verdict_schema >"$schema_file"

    poll_progress "$started" &
    POLLER_PID=$!

    run_codex "$input_file" "$stderr_file" "$isolation_dir" "$schema_file" "$final_file" ||
        exit_code=$?

    kill "$POLLER_PID" 2>/dev/null || true
    wait "$POLLER_PID" 2>/dev/null || true
    POLLER_PID=""

    local stderr_text reason
    stderr_text=$(cat -- "$stderr_file" 2>/dev/null || true)
    if ((exit_code != 0)); then
        if [[ $(<"$LIMIT_REASON_FILE") == token-budget ]]; then
            die "Codex review exceeded --max-tokens $MAX_TOKENS"
        fi
        if ((exit_code == 124 || exit_code == 137)) && ! seconds_until_deadline >/dev/null; then
            die_duration
        fi
        reason=$(classify_blocked_reason "$stderr_text")
        [[ -n $reason ]] && die_blocked "$reason" "codex exec exited $exit_code: $stderr_text"
        die "Codex exited $exit_code: ${stderr_text:-no diagnostic emitted} (transcript: $TRANSCRIPT_PATH)"
    fi

    [[ -s $final_file ]] ||
        die "Codex produced no final message; the gate is blocked, not no_findings. Transcript: $TRANSCRIPT_PATH"

    local verdict used_tokens
    verdict=$(jq -c . <"$final_file" 2>/dev/null) ||
        die "Codex final message is not valid JSON; see $TRANSCRIPT_PATH"
    verify_verdict "$verdict"
    used_tokens=$(verify_token_budget)

    jq -n \
        --argjson exitCode "$exit_code" \
        --arg harness codex \
        --arg requestedModel "$MODEL" \
        --arg observedModel "$(observed_model)" \
        --arg effort "$EFFORT" \
        --argjson eventCount "$(transcript_event_count)" \
        --arg transcript "$TRANSCRIPT_PATH" \
        --argjson tokenUsage "$(token_usage)" \
        --argjson maxTokens "$MAX_TOKENS" \
        --argjson usedTokens "$used_tokens" \
        --argjson verdict "$verdict" \
        '{status: "completed", harness: $harness, exitCode: $exitCode,
          requestedModel: $requestedModel,
          observedModel: (if $observedModel == "" then null else $observedModel end),
          modelVerification: (if $observedModel == "" then "unsupported-by-codex-exec" else "observed" end),
          effort: $effort, eventCount: $eventCount, transcript: $transcript,
          budgetCeiling: "token-limit", maxTokens: $maxTokens, usedTokens: $usedTokens,
          tokenUsage: $tokenUsage,
          verdict: $verdict}'
}

main "$@"
