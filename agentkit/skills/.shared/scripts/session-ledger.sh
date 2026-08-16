#!/usr/bin/env bash
# session-ledger.sh — append and replay human decisions for one orchestrator run.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly MAX_TEXT_LENGTH=4096
readonly SECRET_RE='(gh[pous]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]+|Bearer[[:space:]]+[A-Za-z0-9._~+/=-]+|(token|secret|password|passwd|api[_-]?key)[[:space:]]*[:=][[:space:]]*[^[:space:]]+|-----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY-----)'

LEDGER=''
RUN_ID=''
SKILLS_PATH=''
PROCEDURE_SET=''
DECISION=''
SCOPE=''
QUOTE=''
TIMESTAMP=''
LOCK_FD=''

usage() {
    cat <<EOF
Usage:
  $PROGRAM append --ledger FILE --run-id ID --skills-path PATH --procedure-set NAME \
    --decision TEXT --scope TEXT --quote TEXT [--timestamp UTC]
  $PROGRAM read --ledger FILE --run-id ID

append writes one validated, owner-private NDJSON decision record. read validates
the complete ledger and emits only records for the requested run ID.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit "${2:-1}"
}

die_usage() { die "$1" 2; }
die_evidence() { die "$1" 1; }

require_value() {
    [[ -n ${2:-} ]] || die_usage "$1 requires a value"
}

parse_options() {
    shift
    while (($#)); do
        case $1 in
            --ledger)
                require_value "$1" "${2:-}"
                LEDGER=$2
                shift 2
                ;;
            --ledger=*)
                require_value '--ledger' "${1#*=}"
                LEDGER=${1#*=}
                shift
                ;;
            --run-id)
                require_value "$1" "${2:-}"
                RUN_ID=$2
                shift 2
                ;;
            --run-id=*)
                require_value '--run-id' "${1#*=}"
                RUN_ID=${1#*=}
                shift
                ;;
            --skills-path)
                require_value "$1" "${2:-}"
                SKILLS_PATH=$2
                shift 2
                ;;
            --skills-path=*)
                require_value '--skills-path' "${1#*=}"
                SKILLS_PATH=${1#*=}
                shift
                ;;
            --procedure-set)
                require_value "$1" "${2:-}"
                PROCEDURE_SET=$2
                shift 2
                ;;
            --procedure-set=*)
                require_value '--procedure-set' "${1#*=}"
                PROCEDURE_SET=${1#*=}
                shift
                ;;
            --decision)
                require_value "$1" "${2:-}"
                DECISION=$2
                shift 2
                ;;
            --decision=*)
                require_value '--decision' "${1#*=}"
                DECISION=${1#*=}
                shift
                ;;
            --scope)
                require_value "$1" "${2:-}"
                SCOPE=$2
                shift 2
                ;;
            --scope=*)
                require_value '--scope' "${1#*=}"
                SCOPE=${1#*=}
                shift
                ;;
            --quote)
                require_value "$1" "${2:-}"
                QUOTE=$2
                shift 2
                ;;
            --quote=*)
                require_value '--quote' "${1#*=}"
                QUOTE=${1#*=}
                shift
                ;;
            --timestamp)
                require_value "$1" "${2:-}"
                TIMESTAMP=$2
                shift 2
                ;;
            --timestamp=*)
                require_value '--timestamp' "${1#*=}"
                TIMESTAMP=${1#*=}
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown option: $1"
                ;;
        esac
    done
}

require_commands() {
    local command
    for command in date dirname flock jq mktemp readlink stat; do
        command -v "$command" >/dev/null 2>&1 ||
            die_evidence "$command is not installed; session ledger unavailable"
    done
}

validate_text() {
    local name=$1 value=$2
    [[ -n $value ]] || die_usage "$name must be non-empty"
    ((${#value} <= MAX_TEXT_LENGTH)) ||
        die_usage "$name is too long (maximum $MAX_TEXT_LENGTH characters)"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
        die_usage "$name must be a single line"
    [[ ! $value =~ $SECRET_RE ]] ||
        die_usage "$name resembles a secret; do not record credential material"
}

validate_inputs() {
    [[ -n $LEDGER ]] || die_usage '--ledger is required'
    [[ -n $RUN_ID ]] || die_usage '--run-id is required'
    [[ $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$ ]] ||
        die_usage '--run-id must use letters, numbers, ., _, :, or - (maximum 128 characters)'
    validate_text '--run-id' "$RUN_ID"
}

validate_skills_path() {
    local resolved
    [[ -n $SKILLS_PATH ]] || die_usage '--skills-path is required for append'
    [[ $SKILLS_PATH == /* ]] || die_usage '--skills-path must be an absolute path'
    resolved=$(readlink -f -- "$SKILLS_PATH" 2>/dev/null) ||
        die_evidence "could not resolve skills path: $SKILLS_PATH"
    [[ -d $resolved && ! -L $resolved && -O $resolved ]] ||
        die_evidence "skills path is not an owned directory: $SKILLS_PATH"
    [[ -d $resolved/.shared/scripts && ! -L $resolved/.shared/scripts ]] ||
        die_evidence "skills path has no regular .shared/scripts directory: $SKILLS_PATH"
    SKILLS_PATH=$resolved
}

validate_append_inputs() {
    validate_inputs
    validate_skills_path
    validate_text '--procedure-set' "$PROCEDURE_SET"
    validate_text '--decision' "$DECISION"
    validate_text '--scope' "$SCOPE"
    validate_text '--quote' "$QUOTE"
    if [[ -z $TIMESTAMP ]]; then
        TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ') ||
            die_evidence 'could not produce a UTC timestamp'
    fi
    [[ $TIMESTAMP =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
        die_usage '--timestamp must be UTC in YYYY-MM-DDTHH:MM:SSZ form'
}

ledger_parent() {
    dirname -- "$LEDGER"
}

validate_parent() {
    local parent=$1 current mode
    [[ -d $parent && ! -L $parent && -O $parent ]] ||
        die_evidence "ledger parent is not an owned directory: $parent"
    mode=$(stat -c %a -- "$parent" 2>/dev/null) ||
        die_evidence "could not inspect ledger parent permissions: $parent"
    (( (8#$mode & 0022) == 0 )) ||
        die_evidence "ledger parent must not be group- or world-writable: $parent"
    current=$(dirname -- "$parent")
    while [[ $current != / && $current != . ]]; do
        [[ -d $current && ! -L $current ]] ||
            die_evidence "ledger path crosses an unsafe directory: $current"
        current=$(dirname -- "$current")
    done
}

prepare_parent() {
    local parent
    parent=$(ledger_parent)
    if [[ ! -e $parent ]]; then
        mkdir -p -- "$parent" || die_evidence "could not create ledger parent: $parent"
    fi
    validate_parent "$parent"
}

validate_ledger_file() {
    local mode
    [[ ! -L $LEDGER ]] || die_evidence "refusing a ledger symlink: $LEDGER"
    [[ -f $LEDGER && -O $LEDGER && -r $LEDGER ]] ||
        die_evidence "ledger is not an owned regular file: $LEDGER"
    mode=$(stat -c %a -- "$LEDGER" 2>/dev/null) ||
        die_evidence "could not inspect ledger permissions: $LEDGER"
    [[ $mode == 600 ]] ||
        die_evidence "ledger must have mode 0600: $LEDGER"
}

acquire_lock() {
    local lock_file="$LEDGER.lock"
    [[ ! -L $lock_file ]] || die_evidence "refusing a ledger lock symlink: $lock_file"
    exec {LOCK_FD}>"$lock_file" || die_evidence "could not open ledger lock: $lock_file"
    chmod 600 -- "$lock_file" || die_evidence "could not secure ledger lock: $lock_file"
    flock "$LOCK_FD" || die_evidence "could not acquire ledger lock: $lock_file"
}

release_lock() {
    [[ -n $LOCK_FD ]] || return 0
    flock -u "$LOCK_FD" || true
    exec {LOCK_FD}>&-
    LOCK_FD=''
}

trap release_lock EXIT

ensure_ledger() {
    prepare_parent
    if [[ -e $LEDGER || -L $LEDGER ]]; then
        validate_ledger_file
        return 0
    fi
    # noclobber makes first creation refuse a race or symlink instead of
    # truncating a path selected by another process.
    if ! (set -o noclobber; : >"$LEDGER"); then
        die_evidence "could not create ledger without following a symlink: $LEDGER"
    fi
    chmod 600 -- "$LEDGER" || die_evidence "could not secure ledger: $LEDGER"
    validate_ledger_file
}

validate_existing_records() {
    jq -s -e --arg secret_re "$SECRET_RE" '
      def safe_text:
        if type != "string" then false
        else length > 0 and length <= 4096
          and (test("[\\r\\n]") | not)
          and (test($secret_re; "i") | not)
        end;
      def safe_timestamp:
        type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
      def safe_path:
        type == "string" and test("^/") and (test("[\\r\\n]") | not) and (test($secret_re; "i") | not);
      def valid_record:
        if type != "object" then false
        else (keys - ["timestamp", "run_id", "skills_path", "procedure_set", "decision", "scope", "quote"] | length == 0)
          and (.timestamp | safe_timestamp)
          and (.run_id | safe_text)
          and (.skills_path | safe_path)
          and (.procedure_set | safe_text)
          and (.decision | safe_text)
          and (.scope | safe_text)
          and (.quote | safe_text)
        end;
      all(.[]; valid_record)
    ' "$LEDGER" >/dev/null 2>&1 ||
        die_evidence "ledger contains invalid or secret-like records: $LEDGER"
}

append_record() {
    local entry
    validate_append_inputs
    prepare_parent
    acquire_lock
    ensure_ledger
    validate_existing_records
    entry=$(jq -cn --arg timestamp "$TIMESTAMP" --arg run_id "$RUN_ID" \
        --arg skills_path "$SKILLS_PATH" --arg procedure_set "$PROCEDURE_SET" \
        --arg decision "$DECISION" --arg scope "$SCOPE" --arg quote "$QUOTE" \
        '{timestamp:$timestamp,run_id:$run_id,skills_path:$skills_path,procedure_set:$procedure_set,decision:$decision,scope:$scope,quote:$quote}') ||
        die_evidence 'could not encode ledger record'
    printf '%s\n' "$entry" >>"$LEDGER" ||
        die_evidence "could not append to ledger: $LEDGER"
    chmod 600 -- "$LEDGER" || die_evidence "could not secure ledger: $LEDGER"
    printf '%s\n' "$entry"
    release_lock
}

read_records() {
    local parent
    validate_inputs
    parent=$(ledger_parent)
    [[ ! -L $parent ]] || die_evidence "ledger parent is a symlink: $parent"
    [[ -e $parent ]] || return 0
    validate_parent "$parent"
    [[ -e $LEDGER || -L $LEDGER ]] || return 0
    validate_ledger_file
    validate_existing_records
    jq -c --arg run_id "$RUN_ID" 'select(.run_id == $run_id)' "$LEDGER"
}

main() {
    require_commands
    case ${1:-} in
        append|read)
            COMMAND=$1
            parse_options "$@"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        '')
            die_usage 'a subcommand is required: append or read'
            ;;
        *)
            die_usage "unknown subcommand: ${1:-}"
            ;;
    esac

    case $COMMAND in
        append) append_record ;;
        read) read_records ;;
    esac
}

main "$@"
