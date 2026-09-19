#!/usr/bin/env bash
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
BLOCKER_FILE=''
BLOCKER_PATHS=()
AGENT=''
OUTPUT=''
OUTPUT_TMP=''

usage() {
    printf 'Usage: %s --issue N --why-file FILE --what-file FILE --decisions-file FILE --testing-file FILE [--baseline-exclusion-file FILE] [--blocker PATH]... [--blocker-file FILE] --agent ID [--baseline-file FILE] [--output FILE]\n' "$PROGNAME" >&2
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
            --issue|--why-file|--what-file|--decisions-file|--testing-file|--baseline-file|--baseline-exclusion-file|--blocker|--blocker-file|--agent|--output)
                require_value "$1" "${2-}"
                case $1 in
                    --issue) ISSUE=$2 ;;
                    --why-file) WHY_FILE=$2 ;;
                    --what-file) WHAT_FILE=$2 ;;
                    --decisions-file) DECISIONS_FILE=$2 ;;
                    --testing-file) TESTING_FILE=$2 ;;
                    --baseline-file) BASELINE_FILE=$2 ;;
                    --baseline-exclusion-file) BASELINE_EXCLUSION_FILE=$2 ;;
                    --blocker) BLOCKER_PATHS+=("$2") ;;
                    --blocker-file) BLOCKER_FILE=$2 ;;
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
            --blocker=* ) BLOCKER_PATHS+=("${1#*=}"); shift ;;
            --blocker-file=* ) BLOCKER_FILE=${1#*=}; shift ;;
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

validate_prose_section() {
    local label=$1 path=$2 heading first_assignment
    validate_section "$label" "$path"
    if heading=$(LC_ALL=C grep -m1 -E '^##[[:space:]]' -- "$path"); then
        die "$label contains duplicated heading '$heading' in $path; remove the heading line; compose-pr-body.sh emits it"
    fi
    first_assignment=$(LC_ALL=C awk '
        /^[[:space:]]*$/ { if (count >= 2 && !prose) { print first; found=1; exit }; count=prose=0; next }
        /^[A-Za-z_][A-Za-z0-9_.]*=/ { if (!count) first=$0; count++; next }
        { prose=1 }
        END { if (!found && count >= 2 && !prose) print first }
    ' "$path")
    [[ -z $first_assignment ]] ||
        die "$label contains an unlabelled key=value block beginning '$first_assignment' in $path; replace the key=value block with prose or add a prose label"
}

readonly TESTING_CHECKBOX_RE='^-[[:space:]]\[([xX[:space:]])\][[:space:]](.+)'
readonly TESTING_BULLET_RE='^-[[:space:]]+(.+)$'
readonly TESTING_MALFORMED_CHECKBOX_RE='^-[[:space:]]+\[[^]xX[:space:]]\]([[:space:]]|$)'

validate_testing_action() {
    local lower
    lower=$(printf '%s\n' "$2" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    if [[ $lower =~ (^|[^[:alnum:]_])(was[[:space:]]+not[[:space:]]+run|remains[[:space:]]+(required|pending|unverified|untested|to[[:space:]]+be))([^[:alnum:]_]|$) ||
        $lower =~ (^|[^[:alnum:]_])(tests?|suites?|checks?)[[:space:]]+passed([^[:alnum:]_]|$) ||
        $lower =~ (^|[^[:alnum:]_])passed[[:punct:][:space:]]*$ ]]; then
        die "$1 requires completable verification actions; caveats: ## Decisions; operator work: ## Operator action required"
    fi
}

normalize_testing_file() {
    local label=$1 path=$2 line testing_text
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -z $line ]]; then
            printf '%s\n' "$line"
        elif [[ $line =~ $TESTING_CHECKBOX_RE ]]; then
            testing_text=${BASH_REMATCH[2]}
            [[ ${BASH_REMATCH[1]} == x || ${BASH_REMATCH[1]} == X ]] ||
                validate_testing_action "$label" "$testing_text"
            printf '%s\n' "$line"
        elif [[ $line =~ $TESTING_MALFORMED_CHECKBOX_RE ]]; then
            die "$label must contain only markdown checkbox lines"
        elif [[ $line =~ $TESTING_BULLET_RE ]]; then
            testing_text=${BASH_REMATCH[1]}
            validate_testing_action "$label" "$testing_text"
            printf -- '- [ ] %s\n' "$testing_text"
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

validate_blockers() {
    local path part last_byte
    if [[ -n $BLOCKER_FILE ]]; then
        [[ -f $BLOCKER_FILE && ! -L $BLOCKER_FILE && -r $BLOCKER_FILE && -O $BLOCKER_FILE ]] ||
            die "--blocker-file must be an owned readable regular file: $BLOCKER_FILE"
        if [[ -s $BLOCKER_FILE ]]; then
            last_byte=$(tail -c 1 -- "$BLOCKER_FILE" | od -An -t u1)
            [[ $last_byte =~ ^[[:space:]]*0[[:space:]]*$ ]] ||
                die '--blocker-file must contain NUL-delimited paths'
        fi
        while IFS= read -r -d '' path; do
            BLOCKER_PATHS+=("$path")
        done <"$BLOCKER_FILE"
    fi
    for path in "${BLOCKER_PATHS[@]}"; do
        [[ -n $path && $path != /* && $path != *'`'* &&
            $path != *$'\n'* && $path != *$'\r'* ]] ||
            die "--blocker contains an unsafe repository path: $path"
        IFS=/ read -r -a parts <<<"$path"
        for part in "${parts[@]}"; do
            [[ -n $part && $part != . && $part != .. ]] ||
                die "--blocker contains an unsafe repository path: $path"
        done
    done
}

validate_args() {
    [[ $ISSUE =~ $UINT_RE ]] || die '--issue must be a positive integer'
    [[ -n $AGENT && $AGENT != *$'\n'* && $AGENT != *$'\r'* ]] ||
        die '--agent must be a non-empty single-line identity'
    validate_prose_section '--why-file' "$WHY_FILE"
    validate_prose_section '--what-file' "$WHAT_FILE"
    validate_prose_section '--decisions-file' "$DECISIONS_FILE"
    validate_section '--testing-file' "$TESTING_FILE"
    normalize_testing_file '--testing-file' "$TESTING_FILE" >/dev/null
    [[ -z $BASELINE_FILE ]] || validate_section '--baseline-file' "$BASELINE_FILE"
    [[ -z $BASELINE_EXCLUSION_FILE ]] || validate_testing_file '--baseline-exclusion-file' "$BASELINE_EXCLUSION_FILE"
    validate_blockers
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
    if ((${#BLOCKER_PATHS[@]})); then
        printf '%s\n\n' '## Operator action required'
        printf -- "- \`%s\`\n" "${BLOCKER_PATHS[@]}"
        printf '\n%s\n\n' '**Verification limitation:** The retained successful log is not bound to the published commit and may include the protected worktree paths above.'
    fi
    testing_contents=$(normalize_testing_file '--testing-file' "$TESTING_FILE")
    printf '## Testing\n\n%s' "$testing_contents"
    if [[ -n $BASELINE_EXCLUSION_FILE ]]; then
        printf '\n%s' "$(<"$BASELINE_EXCLUSION_FILE")"
    fi
    printf '\n\n'
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
