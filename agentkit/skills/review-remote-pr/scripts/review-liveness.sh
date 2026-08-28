#!/usr/bin/env bash
# review-liveness.sh — classify a detached adversarial review without probing
# producer PIDs or inferring completion from an artifact's mere existence.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"

run_dir=''
transcript=''
poll_seconds=120
now_epoch=''
launcher_state=unknown
run_dir_real=''
transcript_real=''
sample_path=''
heartbeat_path=''
result_path=''
previous_bytes=0
previous_epoch=0
have_previous=0

usage() {
    cat <<EOF
Usage: $PROGNAME --run-dir DIR --transcript PATH [options]

Classify one detached review poll as Completed, Still running, or Blocked.
Exit status is 0, 1, or 2 for those states respectively; exit 3 is a usage or
environment error.

Options:
  --verdict PATH          Canonical verdict beneath DIR (default: DIR/adversarial.result.json).
  --poll-seconds N       Required spacing between unchanged transcript samples (1-3600).
  --now-epoch N          Override the current epoch for deterministic callers/tests.
  --launcher-state S     running|completed|unknown (default: unknown).
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 3
}

require_value() {
    [[ -n ${2:-} ]] || die "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --) shift; break ;;
            --run-dir) require_value "$1" "${2:-}"; run_dir=$2; shift 2 ;;
            --run-dir=*) run_dir=${1#*=}; shift ;;
            --transcript) require_value "$1" "${2:-}"; transcript=$2; shift 2 ;;
            --transcript=*) transcript=${1#*=}; shift ;;
            --verdict) require_value "$1" "${2:-}"; result_path=$2; shift 2 ;;
            --verdict=*) result_path=${1#*=}; shift ;;
            --poll-seconds) require_value "$1" "${2:-}"; poll_seconds=$2; shift 2 ;;
            --poll-seconds=*) poll_seconds=${1#*=}; shift ;;
            --now-epoch) require_value "$1" "${2:-}"; now_epoch=$2; shift 2 ;;
            --now-epoch=*) now_epoch=${1#*=}; shift ;;
            --launcher-state) require_value "$1" "${2:-}"; launcher_state=$2; shift 2 ;;
            --launcher-state=*) launcher_state=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "unknown option: $1" ;;
        esac
    done
}

validate_path() {
    local path=$1 label=$2
    [[ ! -L $path ]] || die "$label must not be a symlink: $path"
    if [[ -e $path ]]; then
        [[ -f $path && -O $path ]] || die "$label must be an owned regular file: $path"
    fi
}

validate_args() {
    [[ -n $run_dir ]] || die '--run-dir is required'
    [[ -n $transcript ]] || die '--transcript is required'
    [[ $poll_seconds =~ ^[0-9]+$ ]] ||
        die '--poll-seconds must be an integer'
    ((poll_seconds >= 1 && poll_seconds <= 3600)) ||
        die '--poll-seconds must be 1-3600'
    if [[ -n $now_epoch ]]; then
        [[ $now_epoch =~ ^[0-9]+$ ]] || die '--now-epoch must be a non-negative integer'
    else
        now_epoch=$(date +%s)
    fi
    case $launcher_state in
        running|completed|unknown) ;;
        *) die '--launcher-state must be running, completed, or unknown' ;;
    esac
    command -v jq >/dev/null 2>&1 || die 'jq is required to validate review artifacts'

    private_dir_ensure "$run_dir" '--run-dir'
    validate_path "$transcript" transcript
    run_dir_real=$(readlink -f -- "$run_dir") ||
        die "could not resolve --run-dir: $run_dir"
    transcript_real=$(readlink -f -- "$transcript") ||
        die "could not resolve --transcript: $transcript"
    case $transcript_real in
        "$run_dir_real"/*) ;;
        *) die '--transcript must be beneath --run-dir' ;;
    esac
    validate_path "$transcript_real" transcript

    sample_path="$run_dir_real/.review-liveness.state"
    heartbeat_path="$transcript_real.status"
    if [[ -z $result_path ]]; then
        result_path="$run_dir_real/adversarial.result.json"
    else
        [[ $result_path == /* ]] || result_path="$run_dir_real/$result_path"
        validate_path "$result_path" verdict
        result_path=$(readlink -f -- "$result_path") ||
            die "could not resolve --verdict: $result_path"
        case $result_path in
            "$run_dir_real"/*) ;;
            *) die '--verdict must be beneath --run-dir' ;;
        esac
    fi
    validate_path "$sample_path" liveness-state
    validate_path "$heartbeat_path" heartbeat
    validate_path "$result_path" result
    if [[ -e $sample_path ]]; then
        [[ $(stat -c %a -- "$sample_path" 2>/dev/null) == 600 ]] ||
            die "liveness-state must have mode 0600: $sample_path"
    fi
}

valid_result() {
    [[ -f $result_path && ! -L $result_path && -O $result_path ]] || return 1
    jq -e '
      type == "object" and
      (
        (
          .status == "completed" and
          (.exitCode | type) == "number" and .exitCode == 0 and
          (.requestedModel | type) == "string" and
          (.transcript | type) == "string" and
          (.verdict | type) == "object" and
          ((.verdict | keys) - ["verdict", "findings"] | length) == 0 and
          (.verdict.verdict == "findings" or .verdict.verdict == "no_findings") and
          (.verdict.findings | type) == "array" and
          (if .verdict.verdict == "no_findings" then (.verdict.findings | length) == 0
           else (.verdict.findings | length) > 0 end) and
          all(.verdict.findings[];
            (type == "object") and
            ((keys - ["priority", "location", "failureScenario", "smallestFix"]) | length == 0) and
            (.priority == "P1" or .priority == "P2") and
            (.location | type) == "string" and
            (.failureScenario | type) == "string" and
            (.smallestFix | type) == "string")
        )
        or
        (
          .status == "blocked" and
          (.blockedReason | type) == "string" and
          ((keys - ["status", "blockedReason", "detail", "provider",
                    "requestedModel", "effort", "mode", "transcript", "fallback"]) | length) == 0
        )
      )
    ' <"$result_path" >/dev/null 2>&1
}

terminal_result() {
    case $launcher_state in
        running) return 1 ;;
        completed|unknown) valid_result ;;
    esac
}

transcript_bytes() {
    if [[ ! -e $transcript_real ]]; then
        printf '0\n'
        return
    fi
    [[ -f $transcript_real && ! -L $transcript_real && -O $transcript_real ]] ||
        die "transcript must be an owned regular file: $transcript_real"
    stat -c %s -- "$transcript_real" ||
        die "could not read transcript size: $transcript_real"
}

heartbeat_fresh() {
    [[ -f $heartbeat_path && ! -L $heartbeat_path && -O $heartbeat_path ]] || return 1
    local heartbeat_epoch
    heartbeat_epoch=$(jq -er '
        if type == "object" and
           (.wallClockEpoch | type) == "number" and
           (.wallClockEpoch | floor) == .wallClockEpoch
        then .wallClockEpoch
        else empty
        end
    ' "$heartbeat_path" 2>/dev/null) || return 1
    # A future timestamp yields a negative age, which passes the freshness test
    # below and would hold the verdict at "still running" until the local clock
    # caught up -- a liveness check that cannot observe a dead reviewer. The
    # heartbeat is written on this machine, so ahead-of-now is corruption, not
    # skew: treat it as not fresh and let the caller surface the stall.
    ((heartbeat_epoch <= now_epoch)) || return 1
    local age=$((now_epoch - heartbeat_epoch))
    ((age <= 2 * poll_seconds))
}

read_sample() {
    [[ -e $sample_path ]] || return 0
    [[ -f $sample_path && ! -L $sample_path && -O $sample_path ]] ||
        die "liveness-state must be an owned regular file: $sample_path"
    local sample_json
    sample_json=$(cat -- "$sample_path") || die "could not read liveness-state: $sample_path"
    jq -e '
        type == "object" and
        (.transcriptBytes | type) == "number" and
        (.transcriptBytes | floor) == .transcriptBytes and
        .transcriptBytes >= 0 and
        (.sampleEpoch | type) == "number" and
        (.sampleEpoch | floor) == .sampleEpoch and
        .sampleEpoch >= 0
    ' <<<"$sample_json" >/dev/null 2>&1 ||
        die "invalid liveness-state: $sample_path"
    previous_bytes=$(jq -r '.transcriptBytes' <<<"$sample_json")
    previous_epoch=$(jq -r '.sampleEpoch' <<<"$sample_json")
    have_previous=1
}

write_sample() {
    local tmp
    tmp=$(mktemp "$run_dir_real/.review-liveness.state.tmp.XXXXXX") ||
        die "could not stage liveness-state: $sample_path"
    if ! jq -cn --argjson bytes "$1" --argjson epoch "$2" \
        '{transcriptBytes:$bytes, sampleEpoch:$epoch}' >"$tmp" ||
        ! chmod 600 -- "$tmp" ||
        ! mv -f -- "$tmp" "$sample_path"; then
        rm -f -- "$tmp"
        die "could not publish liveness-state: $sample_path"
    fi
}

emit_state() {
    local state=$1 rc=$2
    printf '%s\n' "$state"
    exit "$rc"
}

main() {
    parse_args "$@"
    validate_args
    read_sample

    terminal_result && emit_state Completed 0

    local current_bytes elapsed
    current_bytes=$(transcript_bytes)
    if (( ! have_previous )); then
        write_sample "$current_bytes" "$now_epoch"
        emit_state 'Still running' 1
    fi

    if ((current_bytes < previous_bytes)); then
        write_sample "$current_bytes" "$now_epoch"
        emit_state 'Still running' 1
    fi

    elapsed=$((now_epoch - previous_epoch))
    if ((current_bytes > previous_bytes)) ||
        heartbeat_fresh ||
        ((elapsed < poll_seconds)); then
        if ((elapsed >= poll_seconds)); then
            write_sample "$current_bytes" "$now_epoch"
        fi
        emit_state 'Still running' 1
    fi

    emit_state Blocked 2
}

main "$@"
