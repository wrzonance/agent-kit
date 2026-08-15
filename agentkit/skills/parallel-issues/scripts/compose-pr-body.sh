#!/usr/bin/env bash
# Compose the canonical, file-backed PR body used by parallel-issues publication.
set -euo pipefail

readonly PROGNAME=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'

ISSUE=''
WHY_FILE=''
WHAT_FILE=''
DECISIONS_FILE=''
TESTING_FILE=''
AGENT=''
OUTPUT=''
OUTPUT_TMP=''

usage() {
    printf 'Usage: %s --issue N --why-file FILE --what-file FILE --decisions-file FILE --testing-file FILE --agent ID [--output FILE]\n' "$PROGNAME" >&2
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --issue|--why-file|--what-file|--decisions-file|--testing-file|--agent|--output)
                require_value "$1" "${2-}"
                case $1 in
                    --issue) ISSUE=$2 ;;
                    --why-file) WHY_FILE=$2 ;;
                    --what-file) WHAT_FILE=$2 ;;
                    --decisions-file) DECISIONS_FILE=$2 ;;
                    --testing-file) TESTING_FILE=$2 ;;
                    --agent) AGENT=$2 ;;
                    --output) OUTPUT=$2 ;;
                esac
                shift 2
                ;;
            --issue=* ) ISSUE=${1#*=}; shift ;;
            --why-file=* ) WHY_FILE=${1#*=}; shift ;;
            --what-file=* ) WHAT_FILE=${1#*=}; shift ;;
            --decisions-file=* ) DECISIONS_FILE=${1#*=}; shift ;;
            --testing-file=* ) TESTING_FILE=${1#*=}; shift ;;
            --agent=* ) AGENT=${1#*=}; shift ;;
            --output=* ) OUTPUT=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage; die "unknown argument: $1" ;;
        esac
    done
}

validate_section() {
    local label=$1 path=$2
    [[ -n $path ]] || die "$label is required"
    [[ -f $path && ! -L $path && -r $path && -O $path ]] ||
        die "$label must be an owned readable regular file: $path"
    LC_ALL=C grep -qE '[^[:space:]]' -- "$path" ||
        die "$label is empty or whitespace-only: $path"
}

validate_testing() {
    local line
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        [[ $line =~ ^-[[:space:]]\[[xX[:space:]]\][[:space:]].+ ]] ||
            die 'Testing section must contain only markdown checkbox lines'
    done <"$TESTING_FILE"
}

validate_args() {
    [[ $ISSUE =~ $UINT_RE ]] || die '--issue must be a positive integer'
    [[ -n $AGENT && $AGENT != *$'\n'* && $AGENT != *$'\r'* ]] ||
        die '--agent must be a non-empty single-line identity'
    validate_section '--why-file' "$WHY_FILE"
    validate_section '--what-file' "$WHAT_FILE"
    validate_section '--decisions-file' "$DECISIONS_FILE"
    validate_section '--testing-file' "$TESTING_FILE"
    validate_testing
    [[ $OUTPUT != *$'\n'* && $OUTPUT != *$'\r'* ]] || die '--output must be a single-line path'
    if [[ -n $OUTPUT && $OUTPUT != - ]]; then
        [[ ! -L $OUTPUT ]] || die "refusing symlink output: $OUTPUT"
        [[ ! -e $OUTPUT || -f $OUTPUT ]] || die "output is not a regular file: $OUTPUT"
        output_dir=$(dirname -- "$OUTPUT")
        [[ -d $output_dir ]] || die "output directory does not exist: $output_dir"
    fi
}

cleanup() {
    [[ -z $OUTPUT_TMP ]] || rm -f -- "$OUTPUT_TMP"
}

emit_section() {
    local heading=$1 path=$2 contents
    contents=$(<"$path")
    printf '%s\n\n%s\n\n' "$heading" "$contents"
}

emit_body() {
    printf '%s\n\n' 'This was written agentically; verify its assertions:'
    emit_section '## Why' "$WHY_FILE"
    emit_section '## What' "$WHAT_FILE"
    emit_section '## Decisions' "$DECISIONS_FILE"
    emit_section '## Testing' "$TESTING_FILE"
    printf '🤖 Co-authored by %s.\n\nCloses #%s\n' "$AGENT" "$ISSUE"
}

write_body() {
    if [[ -z $OUTPUT || $OUTPUT == - ]]; then
        emit_body
        return 0
    fi
    OUTPUT_TMP=$(mktemp "$(dirname -- "$OUTPUT")/.compose-pr-body.XXXXXXXXXX") ||
        die "could not allocate output buffer in $(dirname -- "$OUTPUT")"
    chmod 600 -- "$OUTPUT_TMP" || die "could not secure output buffer: $OUTPUT_TMP"
    emit_body >"$OUTPUT_TMP"
    mv -f -- "$OUTPUT_TMP" "$OUTPUT"
    OUTPUT_TMP=''
}

parse_args "$@"
validate_args
trap cleanup EXIT HUP INT TERM
write_body
