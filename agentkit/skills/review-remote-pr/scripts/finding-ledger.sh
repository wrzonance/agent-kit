#!/usr/bin/env bash
# finding-ledger.sh — record confirmed adversarial-review dispositions.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly RECEIPT_MARKER='<!-- adversarial-review:spent -->'
readonly DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
readonly SHA_RE='^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$'
readonly ORDER_RC=13

RUN_DIR=${RUN_DIR:-}
TITLE=''
VERDICT=''
SHA=''
RATIONALE=''
DETAIL_KIND=''

usage() {
    cat <<EOF
Usage: $PROGNAME add --title TITLE --verdict fixed --sha SHA
       $PROGNAME add --title TITLE --verdict declined --rationale RATIONALE

Appends one validated JSON record to \$RUN_DIR/findings.ndjson. RUN_DIR must
be the private run directory containing a completed adversarial.result.json.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    printf 'run "%s --help" for usage\n' "$PROGNAME" >&2
    exit 2
}

die_evidence() {
    printf '%s: %s; evidence unavailable\n' "$PROGNAME" "$1" >&2
    exit 1
}

die_order() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "$ORDER_RC"
}

require_value() {
    [[ -n ${2-} ]] || die_usage "$1 requires a value"
}

parse_add_args() {
    shift
    while (($#)); do
        case $1 in
            --title)
                require_value "$1" "${2-}"
                [[ -z $TITLE ]] || die_usage '--title may be given only once'
                TITLE=$2
                shift 2
                ;;
            --title=*)
                [[ -n ${1#*=} ]] || die_usage '--title requires a value'
                [[ -z $TITLE ]] || die_usage '--title may be given only once'
                TITLE=${1#*=}
                shift
                ;;
            --verdict)
                require_value "$1" "${2-}"
                [[ -z $VERDICT ]] || die_usage '--verdict may be given only once'
                VERDICT=$2
                shift 2
                ;;
            --verdict=*)
                [[ -n ${1#*=} ]] || die_usage '--verdict requires a value'
                [[ -z $VERDICT ]] || die_usage '--verdict may be given only once'
                VERDICT=${1#*=}
                shift
                ;;
            --sha)
                require_value "$1" "${2-}"
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=sha
                SHA=$2
                shift 2
                ;;
            --sha=*)
                [[ -n ${1#*=} ]] || die_usage '--sha requires a value'
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=sha
                SHA=${1#*=}
                shift
                ;;
            --rationale)
                require_value "$1" "${2-}"
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=rationale
                RATIONALE=$2
                shift 2
                ;;
            --rationale=*)
                [[ -n ${1#*=} ]] || die_usage '--rationale requires a value'
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=rationale
                RATIONALE=${1#*=}
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
    done
}

reject_unsafe_text() {
    local flag=$1 value=$2
    [[ -n $value ]] || die_usage "$flag requires a non-empty value"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
        die_usage "$flag must not contain a line break"
    [[ $value != *"$RECEIPT_MARKER"* ]] ||
        die_usage "$flag must not contain the receipt marker $RECEIPT_MARKER"
    [[ $value != *"$DOC_MARKER"* ]] ||
        die_usage "$flag must not contain the agent-doc marker $DOC_MARKER"
}

validate_run_dir() {
    [[ -n $RUN_DIR ]] || die_usage 'RUN_DIR must be set'
    [[ -d $RUN_DIR && ! -L $RUN_DIR && -O $RUN_DIR ]] ||
        die_evidence "RUN_DIR is not an owned directory: $RUN_DIR"
    [[ $(stat -c %a -- "$RUN_DIR" 2>/dev/null) == 700 ]] ||
        die_evidence "RUN_DIR must have mode 0700: $RUN_DIR"
}

validate_completed_review() {
    local result=$RUN_DIR/adversarial.result.json
    [[ -f $result && ! -L $result && -O $result ]] ||
        die_order "completed adversarial review result is required: $result"
    command -v jq >/dev/null 2>&1 || die_evidence 'jq is not installed'
    jq -e '
        type == "object" and .status == "completed" and
        (.exitCode | type) == "number" and .exitCode == 0 and
        (.verdict | type) == "object" and
        (.verdict.verdict == "findings" or .verdict.verdict == "no_findings") and
        (.verdict.findings | type) == "array"
    ' "$result" >/dev/null 2>&1 ||
        die_order "adversarial review result is not a completed validated result: $result"
}

validate_existing_ledger() {
    local ledger=$RUN_DIR/findings.ndjson
    [[ ! -L $ledger ]] || die_evidence "findings ledger is a symlink: $ledger"
    [[ ! -e $ledger ]] && return 0
    [[ -f $ledger && -O $ledger && -r $ledger ]] ||
        die_evidence "findings ledger is not an owned regular file: $ledger"
    command -v jq >/dev/null 2>&1 || die_evidence 'jq is not installed'
    jq -s -e --arg receipt "$RECEIPT_MARKER" --arg doc "$DOC_MARKER" '
        all(.[];
          type == "object" and
          ((keys - ["title", "verdict", "sha", "rationale"]) | length == 0) and
          (.title | type == "string") and
          (.title | test("[\\r\\n]") | not) and
          (.title | contains($receipt) | not) and
          (.title | contains($doc) | not) and
          ((.verdict == "fixed" and has("sha") and (has("rationale") | not) and
              (.sha | type == "string" and test("^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$"))) or
           (.verdict == "declined" and has("rationale") and (has("sha") | not) and
              (.rationale | type == "string" and length > 0) and
              (.rationale | test("[\\r\\n]") | not) and
              (.rationale | contains($receipt) | not) and
              (.rationale | contains($doc) | not)))
        )
    ' "$ledger" >/dev/null 2>&1 ||
        die_evidence "findings ledger is invalid: $ledger"
}

validate_add_args() {
    validate_run_dir
    validate_completed_review
    [[ -n $TITLE ]] || die_usage '--title is required'
    [[ $VERDICT == fixed || $VERDICT == declined ]] ||
        die_usage '--verdict must be fixed or declined'
    [[ $DETAIL_KIND == sha || $DETAIL_KIND == rationale ]] ||
        die_usage 'exactly one of --sha or --rationale is required'
    reject_unsafe_text '--title' "$TITLE"
    case $VERDICT:$DETAIL_KIND in
        fixed:sha)
            [[ $SHA =~ $SHA_RE ]] || die_usage '--sha (SHA) must be hexadecimal (or comma-separated hexadecimal)'
            ;;
        declined:rationale)
            reject_unsafe_text '--rationale' "$RATIONALE"
            ;;
        fixed:rationale)
            die_usage 'fixed findings require --sha'
            ;;
        declined:sha)
            die_usage 'declined findings require --rationale'
            ;;
    esac
}

append_record() {
    local ledger=$RUN_DIR/findings.ndjson entry
    if [[ $VERDICT == fixed ]]; then
        entry=$(jq -cn --arg title "$TITLE" --arg sha "$SHA" \
            '{title:$title,verdict:"fixed",sha:$sha}')
    else
        entry=$(jq -cn --arg title "$TITLE" --arg rationale "$RATIONALE" \
            '{title:$title,verdict:"declined",rationale:$rationale}')
    fi
    printf '%s\n' "$entry" >>"$ledger" ||
        die_evidence "could not append to findings ledger: $ledger"
    chmod 600 -- "$ledger" || die_evidence "could not secure findings ledger: $ledger"
    printf 'added finding verdict=%s title=%s\n' "$VERDICT" "$TITLE"
}

main() {
    (($#)) || die_usage 'a subcommand is required: add'
    case $1 in
        add)
            parse_add_args "$@"
            validate_add_args
            validate_existing_ledger
            append_record
            ;;
        -h|--help)
            usage
            ;;
        *)
            die_usage "unknown subcommand: $1 (expected add)"
            ;;
    esac
}

main "$@"
