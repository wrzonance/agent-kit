#!/usr/bin/env bash
# shellcheck disable=SC2034
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
readonly DEFAULT_MAX_TOKENS=400000
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
NO_PAYLOAD=0
CODEX_BIN=${CODEX_EXECUTABLE:-codex}
CODEX_RESOLVED=""
MODEL=""
EFFORT="xhigh"
DIFF_PATH=""
BASE_REF=""
CONSENT_STATE_PATH=""
CONSENT_PAYLOAD=""
PR_NUMBER=""
REPO_SLUG=""
TRANSCRIPT_PATH=""
OUTPUT_PATH=""
# shellcheck disable=SC2034
OUTPUT_TMP=""
POLL_SECONDS=120
MAX_DIFF_BYTES=1048576            # 1 MiB — a runaway-diff backstop, not a protocol limit
MAX_DURATION_SECONDS=$DEFAULT_MAX_DURATION_SECONDS
MAX_TOKENS=$DEFAULT_MAX_TOKENS
WORK_DIR=""
POLLER_PID=""
CODEX_PID=""
LIMIT_PID=""
LIMIT_REASON_FILE=""
PID_FILE=""
STATUS_FILE=""
STATUS_TMP=""
HEARTBEAT_FAILURE_FILE=""
DEADLINE_EPOCH=0

usage() {
    cat <<EOF
Usage: $PROGNAME --mode <probe|review> --model <model> --transcript <path> [options]

Required:
  --mode <probe|review>      probe: review a fixed diff with a known P1 defect.
                             review: review the diff at --diff.
  --model <model>            Model for the review (e.g. gpt-5.6-terra).
  --transcript <path>        Where to write the raw JSONL event stream.
                             Must be a fresh path in a private directory;
                             missing parent directories are created as 0700;
                             created exclusively with mode 0600.

Conditionally required:
  --diff <path>              Unified diff to review. Required in review mode.
  --repo <owner/name>        Repository the PR belongs to. Bound into the consent
                             payload so a PR number cannot collide across repos.
  --pr <number>              PR number used to bind consent to the exact diff.
  --consent-state <path>     Private consent record. Required in review mode.

Options:
  --codex <path>             codex executable (default: \$CODEX_EXECUTABLE, else
                             the first "codex" on PATH).
  --no-payload               Required in probe mode. The probe sends only a
                             synthetic snippet, no PR diff, and never counts
                             against the one-review-per-PR budget.
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
  --output <path>            Additionally publish the single stdout JSON object to
                             this path, atomically (temp sibling in the same
                             directory, chmod 600, then rename). Written on exit 0
                             (the completed verdict) and exit 3 (the blocked
                             object); never created or left behind on exit 1. The
                             path's directory must be owned by this
                             user, non-symlink, and mode 0700; missing parent
                             directories are created as 0700.
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
record_helper_pid() {
    PID_FILE="$TRANSCRIPT_PATH.pid"
    [[ ! -L $PID_FILE ]] || die "Refusing to write through a PID-file symlink: $PID_FILE"
    rm -f -- "$PID_FILE"
    printf '%s\n' "$$" >"$PID_FILE" || die "Cannot record helper PID: $PID_FILE"
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

record_heartbeat_failure() {
    local detail=$1
    printf '%s\n' "$detail" >"$HEARTBEAT_FAILURE_FILE" 2>/dev/null || true
}

heartbeat_failure_detail() {
    local detail
    detail=$(cat -- "$HEARTBEAT_FAILURE_FILE" 2>/dev/null || true)
    printf '%s' "${detail:-unknown heartbeat publication failure}"
}

# Review transcripts contain the complete private diff and must never be placed
# in a shared temporary directory. The caller creates one 0700 run directory and
# passes a fresh path inside it. Refuse anything weaker before invoking Codex.
require_value() {
    [[ -n ${2:-} ]] || die "option $1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --mode) require_value "$1" "${2:-}" && MODE=${2,,} && shift 2 ;;
        --mode=*) MODE=${1#*=} && MODE=${MODE,,} && shift ;;
        --no-payload) NO_PAYLOAD=1 && shift ;;
        --codex) require_value "$1" "${2:-}" && CODEX_BIN=$2 && shift 2 ;;
        --codex=*) CODEX_BIN=${1#*=} && shift ;;
        --model) require_value "$1" "${2:-}" && MODEL=$2 && shift 2 ;;
        --model=*) MODEL=${1#*=} && shift ;;
        --effort) require_value "$1" "${2:-}" && EFFORT=${2,,} && shift 2 ;;
        --effort=*) EFFORT=${1#*=} && EFFORT=${EFFORT,,} && shift ;;
        --diff) require_value "$1" "${2:-}" && DIFF_PATH=$2 && shift 2 ;;
        --diff=*) DIFF_PATH=${1#*=} && shift ;;
        --base-ref) require_value "$1" "${2:-}" && BASE_REF=$2 && shift 2 ;;
        --base-ref=*) BASE_REF=${1#*=} && shift ;;
        --repo) require_value "$1" "${2:-}" && REPO_SLUG=$2 && shift 2 ;;
        --repo=*) REPO_SLUG=${1#*=} && shift ;;
        --pr) require_value "$1" "${2:-}" && PR_NUMBER=$2 && shift 2 ;;
        --pr=*) PR_NUMBER=${1#*=} && shift ;;
        --consent-state|--state) require_value "$1" "${2:-}" && CONSENT_STATE_PATH=$2 && shift 2 ;;
        --consent-state=*|--state=*) CONSENT_STATE_PATH=${1#*=} && shift ;;
        --consent-payload) require_value "$1" "${2:-}" && CONSENT_PAYLOAD=$2 && shift 2 ;;
        --consent-payload=*) CONSENT_PAYLOAD=${1#*=} && shift ;;
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
        --output) require_value "$1" "${2:-}" && OUTPUT_PATH=$2 && shift 2 ;;
        --output=*) OUTPUT_PATH=${1#*=} && shift ;;
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
    if [[ $MODE == probe ]]; then
        ((NO_PAYLOAD == 1)) ||
            die "--no-payload is required in probe mode; probes send only a synthetic snippet and no PR diff"
        [[ -z $DIFF_PATH && -z $REPO_SLUG && -z $PR_NUMBER &&
            -z $BASE_REF && -z $CONSENT_STATE_PATH && -z $CONSENT_PAYLOAD ]] ||
            die "probe mode cannot include PR review arguments; use only --mode probe --no-payload"
    else
        ((NO_PAYLOAD == 0)) || die "--no-payload is only valid in probe mode"
    fi
    if [[ $MODE == review ]]; then
        [[ -n $DIFF_PATH ]] || die "--diff is required in review mode"
        if [[ -n $BASE_REF ]]; then
            git check-ref-format --branch "$BASE_REF" >/dev/null 2>&1 ||
                die "--base-ref must be a valid branch name"
        fi
        [[ $PR_NUMBER =~ ^[1-9][0-9]*$ ]] || die "--pr is required in review mode"
        [[ $REPO_SLUG =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
            die "--repo OWNER/NAME is required in review mode"
        [[ -n $CONSENT_STATE_PATH ]] || die "--consent-state is required in review mode"
    fi
    return 0
}

verify_consent() {
    local consent_script payload
    consent_script="$SCRIPT_DIR/consent-record.sh"
    [[ -x $consent_script ]] || die "consent record helper is missing: $consent_script"
    local -a payload_args=(payload --repo "$REPO_SLUG" --pr "$PR_NUMBER" --diff "$DIFF_PATH")
    if [[ -n $BASE_REF ]]; then
        payload_args+=(--base-ref "$BASE_REF")
    fi
    payload=$("$consent_script" "${payload_args[@]}") ||
        die 'cannot derive consent payload; refusing to launch review'
    if [[ -n $CONSENT_PAYLOAD && $CONSENT_PAYLOAD != "$payload" ]]; then
        die 'supplied consent payload does not match the exact review diff'
    fi
    "$consent_script" check --state "$CONSENT_STATE_PATH" --provider openai \
        --payload "$payload" >/dev/null 2>&1 ||
        die 'valid cross-provider consent check is required; refusing to launch review'
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

This is a capability probe with no payload. Review only this synthetic snippet;
there is no PR diff and this probe never counts against the one-review-per-PR budget.

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
    local estimated_tokens=$(((bytes + 3) / 4))
    ((estimated_tokens <= MAX_TOKENS)) ||
        die "Review diff is approximately ${estimated_tokens} input tokens, over --max-tokens $MAX_TOKENS. Raise the ceiling or split the review."
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
    local started=$1 now mtime bytes status_json
    now=$(date +%s)
    mtime=$(stat -c %Y -- "$TRANSCRIPT_PATH" 2>/dev/null) || mtime=$started
    bytes=$(stat -c %s -- "$TRANSCRIPT_PATH" 2>/dev/null) || bytes=0
    status_json=$(jq -cn \
        --argjson elapsedSeconds "$((now - started))" \
        --argjson eventCount "$(transcript_event_count)" \
        --argjson transcriptBytes "$bytes" \
        --argjson wallClockEpoch "$now" \
        '{status: "running", harness: "codex", elapsedSeconds: $elapsedSeconds,
          eventCount: $eventCount, transcriptBytes: $transcriptBytes,
          wallClockEpoch: $wallClockEpoch}')
    local failure=''
    if ! printf '%s\n' "$status_json" >"$STATUS_TMP"; then
        failure="printf heartbeat status failed: $STATUS_TMP"
    elif ! chmod 600 -- "$STATUS_TMP"; then
        failure="chmod heartbeat status failed: $STATUS_TMP"
    elif ! mv -f -- "$STATUS_TMP" "$STATUS_FILE"; then
        failure="mv heartbeat status failed: $STATUS_FILE"
    fi
    if [[ -n $failure ]]; then
        record_heartbeat_failure "$failure"
        return 1
    fi
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
    review_register_pid "$CODEX_PID"
    monitor_token_limit &
    LIMIT_PID=$!
    review_register_pid "$LIMIT_PID"
    local heartbeat_failed=0
    while kill -0 "$CODEX_PID" 2>/dev/null; do
        if [[ -s $HEARTBEAT_FAILURE_FILE ]]; then
            kill -TERM -- -"$CODEX_PID" 2>/dev/null ||
                kill "$CODEX_PID" 2>/dev/null || true
            wait "$CODEX_PID" 2>/dev/null || true
            heartbeat_failed=1
            break
        fi
        sleep 0.1
    done
    if ((heartbeat_failed == 0)); then
        wait "$CODEX_PID" || status=$?
    fi
    review_forget_pid "$CODEX_PID"
    CODEX_PID=""
    kill "$LIMIT_PID" 2>/dev/null || true
    wait "$LIMIT_PID" 2>/dev/null || true
    review_forget_pid "$LIMIT_PID"
    LIMIT_PID=""
    [[ $(<"$LIMIT_REASON_FILE") == token-budget ]] && return 125
    ((heartbeat_failed == 1)) && return 125
    [[ -s $HEARTBEAT_FAILURE_FILE ]] && return 125
    return "$status"
}

verify_token_budget() {
    local usage
    usage=$(token_usage_total)
    if ! [[ $usage =~ ^[0-9]+$ ]]; then
        printf '%s: warning: Codex omitted token usage; returning an unverified budget result.\n' \
            "$PROGNAME" >&2
        printf '%s' null
        return 0
    fi
    ((usage <= MAX_TOKENS)) ||
        die "Codex review exceeded --max-tokens $MAX_TOKENS (observed $usage)"
    printf '%s' "$usage"
}

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
    # This is same-process helper enforcement for the observed token ceiling,
    # never a cross-cell liveness signal. Cross-cell pollers use STATUS_FILE.
    while [[ -n $CODEX_PID ]] && kill -0 "$CODEX_PID" 2>/dev/null; do
        usage=$(token_usage_total)
        if [[ $usage =~ ^[0-9]+$ ]] && ((usage > MAX_TOKENS)); then
            printf '%s\n' token-budget >"$LIMIT_REASON_FILE"
            # timeout owns CODEX_PID and puts the reviewed command in its
            # process group. Kill the group so the real Codex child cannot be
            # orphaned when the observed token ceiling is exceeded.
            kill -KILL -- -"$CODEX_PID" 2>/dev/null || true
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
    [[ $MODE == review ]] && verify_consent
    local started exit_code=0
    started=$(date +%s)
    DEADLINE_EPOCH=$((started + MAX_DURATION_SECONDS))

    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codex-adversarial-XXXXXXXXXX")
    chmod 700 -- "$WORK_DIR" || die "Cannot secure review work directory: $WORK_DIR"
    HEARTBEAT_FAILURE_FILE="$WORK_DIR/heartbeat.failure"
    trap review_cleanup EXIT
    trap 'exit 130' INT TERM
    local isolation_dir=$WORK_DIR/cwd
    local input_file=$WORK_DIR/input.txt
    local stderr_file=$WORK_DIR/stderr.log
    local schema_file=$WORK_DIR/schema.json
    local final_file=$WORK_DIR/final.json
    LIMIT_REASON_FILE=$WORK_DIR/limit.reason
    : >"$LIMIT_REASON_FILE"
    mkdir -p -- "$isolation_dir"

    review_prepare_transcript
    review_prepare_output
    record_helper_pid
    preflight

    write_review_input "$input_file"
    verdict_schema >"$schema_file"

    review_poll_progress "$started" &
    POLLER_PID=$!
    review_register_pid "$POLLER_PID"

    run_codex "$input_file" "$stderr_file" "$isolation_dir" "$schema_file" "$final_file" ||
        exit_code=$?

    kill "$POLLER_PID" 2>/dev/null || true
    wait "$POLLER_PID" 2>/dev/null || true
    review_forget_pid "$POLLER_PID"
    POLLER_PID=""

    if [[ -s $HEARTBEAT_FAILURE_FILE ]]; then
        die "heartbeat publication failed: $(heartbeat_failure_detail)"
    fi

    local stderr_text reason
    stderr_text=$(cat -- "$stderr_file" 2>/dev/null || true)
    if ((exit_code != 0)); then
        if [[ $(<"$LIMIT_REASON_FILE") == token-budget ]]; then
            die "Codex review exceeded --max-tokens $MAX_TOKENS"
        fi
        if ((exit_code == 124 || exit_code == 137)) && ! seconds_until_deadline >/dev/null; then
            die_duration
        fi
        reason=$(review_classify_blocked_reason "$stderr_text")
        [[ -n $reason ]] && die_blocked "$reason" "codex exec exited $exit_code: $stderr_text"
        die "Codex exited $exit_code: ${stderr_text:-no diagnostic emitted} (transcript: $TRANSCRIPT_PATH)"
    fi

    [[ -s $final_file ]] ||
        die "Codex produced no final message; the gate is blocked, not no_findings. Transcript: $TRANSCRIPT_PATH"

    local verdict used_tokens budget_ceiling
    verdict=$(jq -c . <"$final_file" 2>/dev/null) ||
        die "Codex final message is not valid JSON; see $TRANSCRIPT_PATH"
    review_verify_verdict "$verdict" Codex
    used_tokens=$(verify_token_budget)
    if [[ $used_tokens == null ]]; then
        budget_ceiling=unverified
    else
        budget_ceiling=token-limit
    fi

    local final_json
    final_json=$(jq -n \
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
        --arg budgetCeiling "$budget_ceiling" \
        --argjson verdict "$verdict" \
        '{status: "completed", harness: $harness, exitCode: $exitCode,
          requestedModel: $requestedModel,
          observedModel: (if $observedModel == "" then null else $observedModel end),
          modelVerification: (if $observedModel == "" then "unsupported-by-codex-exec" else "observed" end),
          effort: $effort, eventCount: $eventCount, transcript: $transcript,
          budgetCeiling: $budgetCeiling, maxTokens: $maxTokens, usedTokens: $usedTokens,
          tokenUsage: $tokenUsage,
          verdict: $verdict}')
    # Durable first: publish_output can die, and emitting stdout before it
    # would hand the caller a verdict that was never published.
    review_publish_output "$final_json"
    printf '%s\n' "$final_json"
}

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/adversarial-review.sh"
die_blocked() {
    review_die_blocked "$1" "$2" "cross-harness-reviewer" "cross-harness adversarial reviewer"
}

main "$@"
