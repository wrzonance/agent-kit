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
BASELINE_FILE=''
BASELINE_EXCLUSION_FILE=''
AGENT=''
OUTPUT=''
OUTPUT_TMP=''

usage() {
    printf 'Usage: %s --issue N --why-file FILE --what-file FILE --decisions-file FILE --testing-file FILE [--baseline-exclusion-file FILE] --agent ID [--baseline-file FILE] [--output FILE]\n' "$PROGNAME" >&2
    printf '  --baseline-file FILE   optional verification-baseline.sh evidence block, appended as a "## Verification" section\n' >&2
    printf '  --baseline-exclusion-file FILE   optional worker baseline-exclusion checkbox appended inside Testing\n' >&2
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
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --issue|--why-file|--what-file|--decisions-file|--testing-file|--baseline-file|--baseline-exclusion-file|--agent|--output)
                require_value "$1" "${2-}"
                case $1 in
                    --issue) ISSUE=$2 ;;
                    --why-file) WHY_FILE=$2 ;;
                    --what-file) WHAT_FILE=$2 ;;
                    --decisions-file) DECISIONS_FILE=$2 ;;
                    --testing-file) TESTING_FILE=$2 ;;
                    --baseline-file) BASELINE_FILE=$2 ;;
                    --baseline-exclusion-file) BASELINE_EXCLUSION_FILE=$2 ;;
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
            --baseline-file=* ) BASELINE_FILE=${1#*=}; shift ;;
            --baseline-exclusion-file=* ) BASELINE_EXCLUSION_FILE=${1#*=}; shift ;;
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

readonly TESTING_CHECKBOX_RE='^-[[:space:]]\[[xX[:space:]]\][[:space:]].+'
readonly TESTING_BULLET_RE='^-[[:space:]]+(.+)$'
# A malformed checkbox *attempt* is narrowly "- [<one char>]" where that char
# is not space/x/X (those already matched TESTING_CHECKBOX_RE above), followed
# by whitespace or end of line -- e.g. "- [z] weird". A plain bullet whose text
# happens to start with a markdown link, "- [CI run](url)", has more than one
# character between the brackets and must fall through to TESTING_BULLET_RE
# like any other plain bullet, not trip this guard (#554 F3).
readonly TESTING_MALFORMED_CHECKBOX_RE='^-[[:space:]]+\[[^]xX[:space:]]\]([[:space:]]|$)'

# Prints TESTING_FILE's content with every plain "- item" bullet rewritten to
# an unchecked "- [ ] item" checkbox; an existing checkbox line and blank
# lines pass through unchanged. Dies (naming the offending file) on a line
# that is neither form -- normalization only widens accepted *input*, it
# never silently drops or waves through a genuinely invalid line.
normalize_testing_file() {
    local label=$1 path=$2 line
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line || $line =~ $TESTING_CHECKBOX_RE ]]; then
            printf '%s\n' "$line"
        elif [[ $line =~ $TESTING_MALFORMED_CHECKBOX_RE ]]; then
            # A single-char bracket that failed the strict checkbox regex
            # above is a malformed checkbox attempt, not a plain bullet --
            # normalizing it would silently double-bracket it into something
            # like "- [ ] [z] weird" instead of naming the actual mistake.
            die "$label must contain only markdown checkbox lines"
        elif [[ $line =~ $TESTING_BULLET_RE ]]; then
            printf -- '- [ ] %s\n' "${BASH_REMATCH[1]}"
        else
            die "$label must contain only markdown checkbox lines"
        fi
    done <"$path"
}

validate_testing_file() {
    local label=$1 path=$2 line
    validate_section "$label" "$path"
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -z $line ]] && continue
        [[ $line =~ ^-[[:space:]]\[[xX[:space:]]\][[:space:]].+ ]] ||
            die "$label must contain only markdown checkbox lines"
    done <"$path"
}

validate_args() {
    [[ $ISSUE =~ $UINT_RE ]] || die '--issue must be a positive integer'
    [[ -n $AGENT && $AGENT != *$'\n'* && $AGENT != *$'\r'* ]] ||
        die '--agent must be a non-empty single-line identity'
    validate_section '--why-file' "$WHY_FILE"
    validate_section '--what-file' "$WHAT_FILE"
    validate_section '--decisions-file' "$DECISIONS_FILE"
    validate_section '--testing-file' "$TESTING_FILE"
    normalize_testing_file '--testing-file' "$TESTING_FILE" >/dev/null
    [[ -z $BASELINE_FILE ]] || validate_section '--baseline-file' "$BASELINE_FILE"
    [[ -z $BASELINE_EXCLUSION_FILE ]] || validate_testing_file '--baseline-exclusion-file' "$BASELINE_EXCLUSION_FILE"
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
    testing_contents=$(normalize_testing_file '--testing-file' "$TESTING_FILE")
    printf '## Testing\n\n%s' "$testing_contents"
    if [[ -n $BASELINE_EXCLUSION_FILE ]]; then
        printf '\n%s' "$(<"$BASELINE_EXCLUSION_FILE")"
    fi
    printf '\n\n'
    # verification-baseline.sh's evidence block already opens with its own
    # "## Baseline verification evidence" heading, so it is appended as-is
    # rather than wrapped in a second heading here.
    [[ -z $BASELINE_FILE ]] || printf '%s\n\n' "$(<"$BASELINE_FILE")"
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
