#!/usr/bin/env bash
# shellcheck disable=SC2153  # MODE is supplied by both sourced harnesses
# Shared lifecycle and boundary helpers for the Claude/Codex review harnesses.
# The caller supplies its `die` and `emit_progress` functions and harness name;
# all artifact, cleanup, polling, classification, and verdict invariants live
# here so the two entry points cannot drift.
# Reviewer-process PID slots. Initialized HERE, at source time, so values can
# never be inherited from the caller's environment: Claude Code exports
# CLAUDE_PID (the interactive session's own PID) into Bash tool shells, and an
# env-inherited value would make review_cleanup kill the host session.
CLAUDE_PID=""
CODEX_PID=""
LIMIT_PID=""
POLLER_PID=""


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
    if [[ -n ${POLLER_PID:-} ]]; then
        kill "$POLLER_PID" 2>/dev/null || true
        wait "$POLLER_PID" 2>/dev/null || true
        POLLER_PID=""
    fi
    for pid in ${CLAUDE_PID:-} ${CODEX_PID:-} ${LIMIT_PID:-}; do
        [[ -n $pid ]] || continue
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
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
