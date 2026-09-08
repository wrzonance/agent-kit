#!/usr/bin/env bash
# shellcheck disable=SC2153  # MODE is supplied by both sourced harnesses
# Shared lifecycle and boundary helpers for the Claude/Codex review harnesses.
# The caller supplies emit_progress, REVIEW_HARNESS_LABEL and CONSENT_PROVIDER;
# all artifact, cleanup, polling, classification, and verdict invariants live
# here so the two entry points cannot drift.
# Reviewer-process PID slots. Initialized HERE, at source time, so values can
# never be inherited from the caller's environment: Claude Code exports
# CLAUDE_PID (the interactive session's own PID) into Bash tool shells, and an
# env-inherited value would make review_cleanup kill the host session.
# shellcheck disable=SC2034  # operational slots are assigned by the wrappers
CLAUDE_PID=""
CODEX_PID=""
LIMIT_PID=""
POLLER_PID=""
REVIEW_CHILD_PIDS=()

review_register_pid() {
    local pid=${1:-}
    [[ $pid =~ ^[1-9][0-9]*$ ]] || die "Cannot register invalid child PID: $pid"
    REVIEW_CHILD_PIDS+=("$pid")
}

review_forget_pid() {
    local pid=${1:-} registered
    local -a remaining=()
    if ((${#REVIEW_CHILD_PIDS[@]})); then
        for registered in "${REVIEW_CHILD_PIDS[@]}"; do
            [[ $registered == "$pid" ]] || remaining+=("$registered")
        done
    fi
    if ((${#remaining[@]})); then
        REVIEW_CHILD_PIDS=("${remaining[@]}")
    else
        REVIEW_CHILD_PIDS=()
    fi
}


# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "${BASH_SOURCE[0]%/*}/private-dir.sh"

review_die_blocked() {
    local reason=$1 detail=$2 fallback=$3 json
    local fallback_message=${4:-$fallback}
    printf '%s: BLOCKED (%s): %s\n' "$PROGNAME" "$reason" "$detail" >&2
    printf '%s: take the %s; do not retry.\n' "$PROGNAME" "$fallback_message" >&2
    json=$(jq -cn --arg blockedReason "$reason" --arg detail "$detail" \
        --arg transcript "$TRANSCRIPT_PATH" --arg fallback "$fallback" \
        '{status:"blocked", blockedReason:$blockedReason, detail:$detail,
          transcript:$transcript, fallback:$fallback}')
    review_publish_output "$json"
    printf '%s\n' "$json"
    exit 3
}

review_publish_output() {
    local json=$1
    [[ -n ${OUTPUT_PATH:-} ]] || return 0
    printf '%s\n' "$json" >"$OUTPUT_TMP" || die "Cannot write output artifact: $OUTPUT_TMP"
    chmod 600 -- "$OUTPUT_TMP" || die "Cannot secure output artifact: $OUTPUT_TMP"
    mv -f -- "$OUTPUT_TMP" "$OUTPUT_PATH" || die "Cannot publish output artifact: $OUTPUT_PATH"
}

review_cleanup() {
    local pid
    if ((${#REVIEW_CHILD_PIDS[@]})); then
        for pid in "${REVIEW_CHILD_PIDS[@]}"; do
            [[ -n $pid ]] || continue
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        done
    fi
    REVIEW_CHILD_PIDS=()
    POLLER_PID=""
    CLAUDE_PID=""
    CODEX_PID=""
    LIMIT_PID=""
    if [[ -n ${PID_FILE:-} ]]; then rm -f -- "$PID_FILE"; PID_FILE=""; fi
    if [[ -n ${STATUS_FILE:-} ]]; then rm -f -- "$STATUS_FILE"; STATUS_FILE=""; fi
    if [[ -n ${STATUS_TMP:-} ]]; then rm -f -- "$STATUS_TMP"; STATUS_TMP=""; fi
    [[ -n ${OUTPUT_TMP:-} ]] && rm -f -- "$OUTPUT_TMP"
    [[ -n ${WORK_DIR:-} && -d $WORK_DIR ]] && rm -rf -- "$WORK_DIR"
    return 0
}

review_prepare_transcript() {
    local parent artifact
    parent=$(dirname -- "$TRANSCRIPT_PATH")
    private_dir_ensure "$parent" "Transcript parent"
    [[ ! -L $TRANSCRIPT_PATH ]] || die "Refusing to write through a transcript symlink: $TRANSCRIPT_PATH"
    if [[ -e $TRANSCRIPT_PATH ]]; then
        [[ -f $TRANSCRIPT_PATH && -O $TRANSCRIPT_PATH ]] || die "Refusing to overwrite transcript not owned by this user: $TRANSCRIPT_PATH"
        rm -f -- "$TRANSCRIPT_PATH" || die "Cannot remove previous transcript: $TRANSCRIPT_PATH"
    fi
    (set -o noclobber; : >"$TRANSCRIPT_PATH") || die "Cannot create transcript exclusively: $TRANSCRIPT_PATH"
    chmod 600 -- "$TRANSCRIPT_PATH" || die "Cannot secure transcript: $TRANSCRIPT_PATH"
    STATUS_FILE="$TRANSCRIPT_PATH.status"
    STATUS_TMP="$STATUS_FILE.tmp"
    for artifact in "$STATUS_FILE" "$STATUS_TMP"; do
        [[ ! -L $artifact ]] || die "Refusing to write through a status-artifact symlink: $artifact"
        if [[ -e $artifact ]]; then
            [[ -f $artifact && -O $artifact ]] || die "Refusing to overwrite status artifact that is not an owned regular file: $artifact"
            rm -f -- "$artifact" || die "Cannot remove previous status artifact: $artifact"
        fi
    done
}

review_canonical_path() {
    local path=$1 parent base
    base=$(basename -- "$path")
    parent=$(cd -- "$(dirname -- "$path")" 2>/dev/null && pwd -P) || parent=$(dirname -- "$path")
    printf '%s/%s\n' "$parent" "$base"
}

review_prepare_output() {
    [[ -n ${OUTPUT_PATH:-} ]] || return 0
    local parent artifact canonical_output canonical_output_tmp canonical_other
    parent=$(dirname -- "$OUTPUT_PATH")
    private_dir_ensure "$parent" "Output parent"
    OUTPUT_TMP="$OUTPUT_PATH.tmp"
    canonical_output=$(review_canonical_path "$OUTPUT_PATH")
    canonical_output_tmp=$(review_canonical_path "$OUTPUT_TMP")
    for artifact in "$TRANSCRIPT_PATH" "$DIFF_PATH" "$STATUS_FILE" "$STATUS_TMP"; do
        [[ -n $artifact ]] || continue
        canonical_other=$(review_canonical_path "$artifact")
        [[ $canonical_output != "$canonical_other" ]] || die "--output must not alias another artifact: $OUTPUT_PATH"
        [[ $canonical_output_tmp != "$canonical_other" ]] || die "--output temp sibling must not alias another artifact: $OUTPUT_TMP"
    done
    for artifact in "$OUTPUT_PATH" "$OUTPUT_TMP"; do
        [[ ! -L $artifact ]] || die "Refusing to write through an output-artifact symlink: $artifact"
        if [[ -e $artifact ]]; then
            [[ -f $artifact && -O $artifact ]] || die "Refusing to overwrite output artifact not owned by this user: $artifact"
            rm -f -- "$artifact" || die "Cannot remove previous output artifact: $artifact"
        fi
    done
}

review_poll_progress() {
    local started=$1 sleep_pid=""
    trap 'if [[ -n $sleep_pid ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM
    while :; do
        emit_progress "$started"
        sleep "$POLL_SECONDS" &
        sleep_pid=$!
        wait "$sleep_pid" 2>/dev/null || true
        sleep_pid=""
    done
}

review_classify_blocked_reason() {
    local text=${1,,} reason=${2:-}
    case $text in
        *"credit balance"*|*"insufficient credit"*|*"budget exceeded"*|*"quota exceeded"*) reason=budget-exhausted;;
        *unauthenticated*|*"invalid api key"*|*"invalid x-api-key"*|*oauth*|*authentication_error*|*"not logged in"*|*401*|*unauthorized*|*authentication*) reason=unauthenticated;;
        *getaddrinfo*|*enotfound*|*econnrefused*|*"connection refused"*|*eai_again*|*"network is unreachable"*|*"unable to connect"*|*"dns error"*|*"failed to lookup"*|*network*) reason=network-unreachable;;
        *enotimp*|*eperm*|*eacces*|*"not permitted"*|*"permission denied"*|*"cannot execute"*|*"exec format error"*) reason=exec-denied;;
    esac
    printf '%s' "$reason"
}

review_verify_verdict() {
    local verdict=$1 harness=$2 kind findings_count p1_count
    kind=$(jq -r '.verdict // ""' <<<"$verdict")
    [[ $kind == findings || $kind == no_findings ]] || die "$harness returned an invalid verdict value."
    findings_count=$(jq -r '(.findings // []) | length' <<<"$verdict")
    [[ $kind == no_findings && $findings_count -ne 0 ]] && die "$harness returned findings with a no_findings verdict."
    [[ $kind == findings && $findings_count -eq 0 ]] && die "$harness returned a findings verdict with an empty findings array."
    if [[ $MODE == probe ]]; then
        p1_count=$(jq -r '[(.findings // [])[] | select(.priority == "P1")] | length' <<<"$verdict")
        [[ $kind == findings && $p1_count -gt 0 ]] || die "$harness probe did not return the deliberate P1 finding."
    fi
}

# Shared by both harness entry points (moved from the twins, size wave two).
# Each script sets REVIEW_HARNESS_LABEL (Claude|Codex) and CONSENT_PROVIDER
# (anthropic|openai) before main runs.
# shellcheck disable=SC2154  # PROGNAME, TRANSCRIPT_PATH, DEADLINE_EPOCH, HEARTBEAT_FAILURE_FILE,
# MAX_DURATION_SECONDS, MODE, MODEL, EFFORT, POLL_SECONDS, NO_PAYLOAD, DIFF_PATH, REPO_SLUG,
# PR_NUMBER, BASE_REF, CONSENT_STATE_PATH, CONSENT_PAYLOAD, CONSENT_PROVIDER, REVIEW_HARNESS_LABEL,
# SCRIPT_DIR are supplied by the sourcing script
die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

require_value() {
    [[ -n ${2:-} ]] || die "option $1 requires a value"
}

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
    die "$REVIEW_HARNESS_LABEL review exceeded --max-duration-seconds $MAX_DURATION_SECONDS"
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

transcript_event_count() {
    local count
    count=$(grep -c '[^[:space:]]' -- "$TRANSCRIPT_PATH" 2>/dev/null) || count=0
    printf '%s' "${count:-0}"
}

# The head of validate_args both harnesses share; each script keeps its own
# harness-specific checks between this and review_validate_mode_args.
review_validate_common_args() {
    [[ $MODE == probe || $MODE == review ]] || die "--mode must be probe or review"
    [[ -n $MODEL ]] || die "--model is required"
    [[ -n $TRANSCRIPT_PATH ]] || die "--transcript is required"
    case $EFFORT in
    low | medium | high | xhigh | max) ;;
    *) die "--effort must be one of: low medium high xhigh max" ;;
    esac
    [[ $POLL_SECONDS =~ ^[0-9]+$ ]] || die "--poll-seconds must be an integer"
    ((POLL_SECONDS >= 1 && POLL_SECONDS <= 3600)) || die "--poll-seconds must be 1-3600"
}

review_validate_mode_args() {
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
    "$consent_script" check --state "$CONSENT_STATE_PATH" --provider "$CONSENT_PROVIDER" \
        --payload "$payload" >/dev/null 2>&1 ||
        die 'valid cross-provider consent check is required; refusing to launch review'
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
