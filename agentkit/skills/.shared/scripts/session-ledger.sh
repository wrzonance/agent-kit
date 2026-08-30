#!/usr/bin/env bash
# session-ledger.sh — append and replay human decisions for one orchestrator run.
set -euo pipefail
umask 077

# Resolve a PATH symlink first (as bootstrap-repo.sh does): BASH_SOURCE[0]
# names the symlink, whose directory has no lib/ sibling to source.
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1091  # sibling library is resolved at runtime
source "$SCRIPT_DIR/lib/secure-mkdir.sh"

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
QUOTE_FILE=''
TIMESTAMP=''
LOCK_FD=''

usage() {
    cat <<EOF
Usage:
  $PROGRAM append --ledger FILE --run-id ID --skills-path PATH --procedure-set NAME \
    --decision TEXT --scope TEXT (--quote TEXT | --quote-file PATH) [--timestamp UTC]
  $PROGRAM read --ledger FILE --run-id ID
  $PROGRAM covers --ledger FILE --run-id ID --decision TEXT --scope TEXT

append writes one validated, owner-private NDJSON decision record. read validates
the complete ledger and emits only records for the requested run ID. covers exits 0
when a validated record for the run carries the exact decision AND the exact
scope -- the once-per-run authorization check -- and exits 1 when nothing does,
so a caller stops instead of silently proceeding. Both are mandatory: a
decision token alone must never satisfy a narrower recorded grant.

--quote and --quote-file are mutually exclusive; exactly one is required for
append. --quote-file reads the named file's bytes exactly as supplied -- no
interpolation, no reflow -- except that a carriage return is stripped (a
CRLF or bare-CR grant is normalized to LF; see below), which is the
fidelity-preserving path for a multi-line human grant. --quote itself also
accepts embedded newlines, under the same carriage-return normalization. A
quote file containing a NUL byte is refused rather than silently truncated.
--decision and --scope must remain single-line tokens.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit "${2:-1}"
}

die_usage() {
    local message=$1
    printf '%s: %s\n' "$PROGRAM" "$message" >&2
    usage >&2
    exit 2
}
die_evidence() { die "$1" 1; }

require_value() {
    [[ -n ${2:-} ]] || die_usage "$1 requires a value"
}

parse_options() {
    shift
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
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
            --quote-file)
                require_value "$1" "${2:-}"
                QUOTE_FILE=$2
                shift 2
                ;;
            --quote-file=*)
                require_value '--quote-file' "${1#*=}"
                QUOTE_FILE=${1#*=}
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
    local name=$1 value=$2 allow_multiline=${3:-single} normalized_value normalized_secret_re
    [[ -n $value ]] || die_usage "$name must be non-empty"
    ((${#value} <= MAX_TEXT_LENGTH)) ||
        die_usage "$name is too long (maximum $MAX_TEXT_LENGTH characters)"
    if [[ $allow_multiline == single ]]; then
        [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
            die_usage "$name must be a single line"
    fi
    # The existing-record validator is case-insensitive; normalize both sides
    # here so an uppercase credential label cannot be written and permanently
    # poison the ledger before the replay-side check sees it.
    normalized_value=${value,,}
    normalized_secret_re=${SECRET_RE,,}
    [[ ! $normalized_value =~ $normalized_secret_re ]] ||
        die_usage "$name resembles a secret; do not record credential material"
}

# --quote-file reads a file's bytes exactly as supplied -- the fidelity-
# preserving path for a multi-line human grant (matches the file-backed
# transport discipline in .shared/github-body-policy.md) -- except that
# strip_carriage_returns (below) still normalizes a carriage return out of
# the loaded text; that is the one intentional exception to "verbatim" and
# it is documented, not silent. Command substitution alone strips trailing
# newlines, so a sentinel byte is appended and stripped back off to preserve
# the file's exact trailing bytes. A NUL byte cannot survive downstream: the
# stored value is later passed to jq as a --arg, an argv value, and argv is a
# NUL-terminated C string at the exec boundary, so anything past the first
# NUL would be silently dropped there. A NUL-containing file is refused here
# instead of being silently truncated/altered: a quote with a NUL byte is not
# a human grant. The comparison reads the file through two independent
# streams (process substitution, not a pipe) so shellcheck does not read this
# as a same-file read/write conflict (SC2094) -- both sides only ever read.
load_quote_file() {
    [[ -f $QUOTE_FILE && ! -L $QUOTE_FILE && -r $QUOTE_FILE && -O $QUOTE_FILE ]] ||
        die_usage "--quote-file must be an owned readable regular file: $QUOTE_FILE"
    cmp -s <(LC_ALL=C tr -d '\000' <"$QUOTE_FILE") "$QUOTE_FILE" ||
        die_usage "--quote-file contains a NUL byte and cannot be stored verbatim: $QUOTE_FILE"
    local content
    content=$(cat -- "$QUOTE_FILE" && printf x) ||
        die_evidence "could not read quote file: $QUOTE_FILE"
    QUOTE=${content%x}
}

# A bare carriage return is a formatting artifact, not content, so it is
# stripped before validation and storage rather than rejected outright --
# this also normalizes a CRLF quote to LF without touching its wording. This
# is the one respect in which stored text is not byte-identical to the
# supplied --quote/--quote-file input: every other byte is preserved exactly.
strip_carriage_returns() {
    QUOTE=${QUOTE//$'\r'/}
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
    if [[ -n $QUOTE && -n $QUOTE_FILE ]]; then
        die_usage '--quote and --quote-file are mutually exclusive'
    fi
    [[ -n $QUOTE || -n $QUOTE_FILE ]] || die_usage '--quote or --quote-file is required'
    if [[ -n $QUOTE_FILE ]]; then
        load_quote_file
    fi
    strip_carriage_returns
    validate_text '--quote' "$QUOTE" multiline
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
        die_evidence "ledger parent must not be group- or world-writable: $parent (fix: chmod 700 $parent)"
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
        secure_mkdir_p "$parent" || die_evidence "could not create ledger parent: $parent"
        # Defensive: mkdir -m already bypasses umask, but this is the kit's
        # own metadata directory and we just created it ourselves, so
        # confirming (rather than trusting) its mode costs nothing and
        # catches a platform where -m does not fully apply. A directory that
        # pre-dates this call is never touched here -- see validate_parent.
        chmod 700 -- "$parent" || die_evidence "could not secure ledger parent: $parent"
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
      # The quote field alone preserves a multi-line human grant verbatim; a
      # bare carriage return is stripped before storage, so a stored quote
      # must never contain one, but embedded newlines are expected.
      def safe_quote:
        if type != "string" then false
        else length > 0 and length <= 4096
          and (test("\\r") | not)
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
          and (.quote | safe_quote)
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
    # Hold the same lock the append path uses so a read never observes a
    # torn NDJSON line written mid-append.
    acquire_lock
    if [[ ! -e $LEDGER && ! -L $LEDGER ]]; then
        release_lock
        return 0
    fi
    validate_ledger_file
    validate_existing_records
    jq -c --arg run_id "$RUN_ID" 'select(.run_id == $run_id)' "$LEDGER"
    release_lock
}

covers_records() {
    local matches
    validate_inputs
    validate_text '--decision' "$DECISION"
    # Scope is mandatory and compared exactly: an omitted scope acting as a
    # wildcard would let a decision-only check reuse a narrowly recorded grant
    # for a broader mutation. Every appended record carries a scope, so every
    # check can name the one it needs.
    [[ -n $SCOPE ]] || die_usage '--scope is required for covers'
    validate_text '--scope' "$SCOPE"
    # Reuse the read path's full validation and locking; its output is already
    # limited to this run's records. An unreadable or invalid ledger fails
    # closed as not-covered -- an authorization check never guesses.
    matches=$(read_records | jq -c --arg decision "$DECISION" --arg scope "$SCOPE" '
        select(.decision == $decision and .scope == $scope)') ||
        die_evidence "ledger is unreadable; treating the mutation as not covered: $LEDGER"
    if [[ -z $matches ]]; then
        printf '%s: not covered: no recorded decision %s for run %s%s\n' \
            "$PROGRAM" "$DECISION" "$RUN_ID" "${SCOPE:+ (scope: $SCOPE)}" >&2
        return 1
    fi
    printf 'covered= run-id=%s decision=%s records=%s\n' \
        "$RUN_ID" "$DECISION" "$(wc -l <<<"$matches")"
}

main() {
    require_commands
    case ${1:-} in
        append|read|covers)
            COMMAND=$1
            parse_options "$@"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        '')
            die_usage 'a subcommand is required: append, read, or covers'
            ;;
        *)
            die_usage "unknown subcommand: ${1:-}"
            ;;
    esac

    case $COMMAND in
        append) append_record ;;
        read) read_records ;;
        covers) covers_records ;;
    esac
}

main "$@"
