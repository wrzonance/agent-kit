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
FLAGS=''
REPO=''
BASE=''
QUOTE=''
QUOTE_FILE=''
QUOTE_STDIN=0
TIMESTAMP=''
LOCK_FD=''
TEMP_FILES=()

usage() {
    cat <<'EOF'
Usage:
  session-ledger.sh append --ledger FILE --run-id ID --skills-path PATH --procedure-set NAME \
    --decision TEXT --scope TEXT (--quote TEXT | --quote-file PATH | --quote-stdin) [--timestamp UTC]
  session-ledger.sh read --ledger FILE --run-id ID
  session-ledger.sh covers --ledger FILE --run-id ID --decision TEXT --scope TEXT
  session-ledger.sh quarantine --ledger FILE
  session-ledger.sh run-id --procedure-set NAME --scope CSV [--flags CSV] --repo SLUG --base BRANCH

append writes one validated, owner-private NDJSON decision record. read and
covers validate only records attributed to the requested run, so unrelated
malformed rows cannot block it. quarantine moves every invalid physical row to
an owner-private audit sidecar and leaves a fully valid ledger. covers exits 0
only when a validated record carries the exact decision AND exact scope.

The run-id command canonicalizes scope and flag CSVs before hashing the full
procedure/scope/flags/repository/base tuple. CSV order and duplicates do not
change the result.

--quote, --quote-file, and --quote-stdin are mutually exclusive; exactly one
is required for append. File and stdin input are read exactly as supplied -- no
interpolation, no reflow -- except that a carriage return is stripped (a
CRLF or bare-CR grant is normalized to LF; see below), which is the
fidelity-preserving path for a multi-line human grant. --quote itself also
accepts embedded newlines, under the same carriage-return normalization. A
quote file containing a NUL byte is refused rather than silently truncated.
--decision and --scope must remain single-line tokens.

Recipe: establish and reuse one run ID
  issue_scope="${selected_issue_scope:-${requested_issue_scope:-auto}}"
  invocation_flags="yolo=${yolo_invocation:-false},trust-trunk=${trust_trunk:-false},fast-mode=${fast_mode:-false},auto-review=${auto_review:-false},auto-serialize=${auto_serialize:-false}"
  LEDGER="$repository_root/.agent/session-ledger.ndjson"
  [ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ] || exit 1
  RUN_ID=$("$agentkit/.shared/scripts/session-ledger.sh" run-id --procedure-set parallel-issues --scope "$issue_scope" \
    --flags "$invocation_flags" --repo "$repository" --base "$base") || exit 1
  printf '%s' "$QUOTE" | "$agentkit/.shared/scripts/session-ledger.sh" append --ledger "$LEDGER" --run-id "$RUN_ID" --skills-path "$agentkit" \
    --procedure-set parallel-issues --decision "$DECISION" --scope "$SCOPE" --quote-stdin || exit 1
  "$agentkit/.shared/scripts/session-ledger.sh" covers --ledger "$LEDGER" --run-id "$RUN_ID" \
    --decision "$DECISION" --scope "$SCOPE" || exit 1
  "$agentkit/.shared/scripts/session-ledger.sh" read --ledger "$LEDGER" --run-id "$RUN_ID"
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
            --flags)
                require_value "$1" "${2:-}"
                FLAGS=$2
                shift 2
                ;;
            --flags=*)
                require_value '--flags' "${1#*=}"
                FLAGS=${1#*=}
                shift
                ;;
            --repo)
                require_value "$1" "${2:-}"
                REPO=$2
                shift 2
                ;;
            --repo=*)
                require_value '--repo' "${1#*=}"
                REPO=${1#*=}
                shift
                ;;
            --base)
                require_value "$1" "${2:-}"
                BASE=$2
                shift 2
                ;;
            --base=*)
                require_value '--base' "${1#*=}"
                BASE=${1#*=}
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
            --quote-stdin)
                QUOTE_STDIN=1
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
    for command in date dirname flock jq mktemp mv readlink sha256sum stat; do
        command -v "$command" >/dev/null 2>&1 ||
            die_evidence "$command is not installed; session ledger unavailable"
    done
}

validate_text() {
    local name=$1 value=$2 allow_multiline=${3:-single} normalized_value normalized_secret_re
    validate_identity_text "$name" "$value" "$allow_multiline"
    normalized_value=${value,,}
    normalized_secret_re=${SECRET_RE,,}
    [[ ! $normalized_value =~ $normalized_secret_re ]] ||
        die_usage "$name resembles a secret; do not record credential material"
}

validate_identity_text() {
    local name=$1 value=$2 allow_multiline=${3:-single}
    [[ -n $value ]] || die_usage "$name must be non-empty"
    ((${#value} <= MAX_TEXT_LENGTH)) ||
        die_usage "$name is too long (maximum $MAX_TEXT_LENGTH characters)"
    if [[ $allow_multiline == single ]]; then
        [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
            die_usage "$name must be a single line"
    fi
}

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

load_quote_stdin() {
    if IFS= read -r -d '' QUOTE; then
        die_usage '--quote-stdin contains a NUL byte and cannot be stored verbatim'
    fi
}

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
    local quote_sources=0
    [[ -z $QUOTE ]] || quote_sources=$((quote_sources + 1))
    [[ -z $QUOTE_FILE ]] || quote_sources=$((quote_sources + 1))
    ((QUOTE_STDIN == 0)) || quote_sources=$((quote_sources + 1))
    ((quote_sources <= 1)) || die_usage '--quote, --quote-file, and --quote-stdin are mutually exclusive'
    ((quote_sources == 1)) || die_usage '--quote, --quote-file, or --quote-stdin is required'
    if [[ -n $QUOTE_FILE ]]; then
        load_quote_file
    elif ((QUOTE_STDIN == 1)); then
        load_quote_stdin
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

print_run_id() {
    local canonical digest prefix
    validate_identity_text '--procedure-set' "$PROCEDURE_SET"
    validate_identity_text '--scope' "$SCOPE"
    [[ -z $FLAGS ]] || validate_identity_text '--flags' "$FLAGS"
    validate_identity_text '--repo' "$REPO"
    validate_identity_text '--base' "$BASE"
    canonical=$(jq -cn --arg procedure_set "$PROCEDURE_SET" --arg scope "$SCOPE" \
        --arg flags "$FLAGS" --arg repo "$REPO" --arg base "$BASE" '
        def csv:
          split(",") | map(gsub("^\\s+|\\s+$"; "")) |
          if any(. == "") then error("empty CSV member") else unique end;
        {version:1, procedure_set:$procedure_set, scope:($scope | csv),
         flags:(if $flags == "" then [] else ($flags | csv) end), repo:$repo, base:$base}
    ') || die_usage '--scope and --flags must contain comma-separated non-empty values'
    digest=$(printf '%s' "$canonical" | sha256sum) || die_evidence 'could not hash canonical run identity'
    digest=${digest%% *}
    prefix=${PROCEDURE_SET//[^A-Za-z0-9._-]/-}
    [[ $prefix =~ ^[A-Za-z0-9] ]] || prefix="run-$prefix"
    printf '%s-%s\n' "${prefix:0:80}" "${digest:0:32}"
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

cleanup() {
    local file
    release_lock
    for file in "${TEMP_FILES[@]}"; do
        [[ -z $file ]] || rm -f -- "$file"
    done
}

trap cleanup EXIT

ensure_ledger() {
    prepare_parent
    if [[ -e $LEDGER || -L $LEDGER ]]; then
        validate_ledger_file
        return 0
    fi
    if ! (set -o noclobber; : >"$LEDGER"); then
        die_evidence "could not create ledger without following a symlink: $LEDGER"
    fi
    chmod 600 -- "$LEDGER" || die_evidence "could not secure ledger: $LEDGER"
    validate_ledger_file
}

validate_record_stream() {
    jq -s -e --arg secret_re "$SECRET_RE" '
      def safe_text:
        if type != "string" then false
        else length > 0 and length <= 4096
          and (test("[\\r\\n]") | not)
          and (test($secret_re; "i") | not)
        end;
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
        else (keys | sort) == ["decision", "procedure_set", "quote", "run_id", "scope", "skills_path", "timestamp"]
          and (.timestamp | safe_timestamp)
          and (.run_id | safe_text)
          and (.skills_path | safe_path)
          and (.procedure_set | safe_text)
          and (.decision | safe_text)
          and (.scope | safe_text)
          and (.quote | safe_quote)
        end;
      all(.[]; valid_record)
    ' "$@" >/dev/null 2>&1
}

records_for_run() {
    jq -Rrc --arg run_id "$RUN_ID" '
      fromjson? | select(type == "object" and .run_id? == $run_id)
    ' "$LEDGER"
}

validated_records_for_run() {
    local records
    records=$(records_for_run) ||
        die_evidence "could not inspect ledger records for run $RUN_ID: $LEDGER"
    if ! printf '%s' "$records" | validate_record_stream; then
        die_evidence "ledger contains invalid or secret-like records for run $RUN_ID: $LEDGER"
    fi
    [[ -z $records ]] || printf '%s\n' "$records"
}

append_record() {
    local entry existing records
    validate_append_inputs
    prepare_parent
    acquire_lock
    ensure_ledger
    records=$(validated_records_for_run)
    existing=$(jq -sc --arg run_id "$RUN_ID" --arg decision "$DECISION" \
        --arg scope "$SCOPE" --arg quote "$QUOTE" \
        'first(.[] | select(.run_id == $run_id and .decision == $decision and .scope == $scope and .quote == $quote)) // empty' \
        <<< "$records") || die_evidence 'could not inspect ledger for a duplicate record'
    if [[ -n $existing ]]; then
        printf '%s\n' "$existing"
        release_lock
        return 0
    fi
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
    acquire_lock
    if [[ ! -e $LEDGER && ! -L $LEDGER ]]; then
        release_lock
        return 0
    fi
    validate_ledger_file
    validated_records_for_run
    release_lock
}

ensure_quarantine_file() {
    local file=$1 mode
    [[ ! -L $file ]] || die_evidence "refusing a quarantine symlink: $file"
    if [[ ! -e $file ]]; then
        if ! (set -o noclobber; : > "$file"); then
            die_evidence "could not create quarantine sidecar without following a symlink: $file"
        fi
        chmod 600 -- "$file" || die_evidence "could not secure quarantine sidecar: $file"
    fi
    [[ -f $file && -O $file && -r $file && -w $file ]] ||
        die_evidence "quarantine sidecar is not an owned readable regular file: $file"
    mode=$(stat -c %a -- "$file" 2>/dev/null) ||
        die_evidence "could not inspect quarantine sidecar permissions: $file"
    [[ $mode == 600 ]] || die_evidence "quarantine sidecar must have mode 0600: $file"
}

quarantine_records() {
    local parent sidecar kept audit line reason record timestamp source_ledger
    local line_number=0 quarantined=0 remaining=0
    [[ -n $LEDGER ]] || die_usage '--ledger is required'
    parent=$(ledger_parent)
    [[ ! -L $parent ]] || die_evidence "ledger parent is a symlink: $parent"
    [[ -e $parent ]] || {
        printf 'quarantined=0 remaining=0 sidecar=%s/ledger-quarantine.ndjson\n' "$parent"
        return 0
    }
    validate_parent "$parent"
    acquire_lock
    if [[ ! -e $LEDGER && ! -L $LEDGER ]]; then
        printf 'quarantined=0 remaining=0 sidecar=%s/ledger-quarantine.ndjson\n' "$parent"
        release_lock
        return 0
    fi
    validate_ledger_file
    kept=$(mktemp -- "$parent/.session-ledger.repair.XXXXXX") ||
        die_evidence "could not create ledger repair file in $parent"
    audit=$(mktemp -- "$parent/.ledger-quarantine.audit.XXXXXX") ||
        die_evidence "could not create quarantine audit file in $parent"
    TEMP_FILES+=("$kept" "$audit")
    chmod 600 -- "$kept" "$audit" || die_evidence 'could not secure quarantine temporary files'
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || die_evidence 'could not produce a UTC timestamp'
    source_ledger=$LEDGER
    while IFS= read -r line || [[ -n $line ]]; do
        line_number=$((line_number + 1))
        if printf '%s\n' "$line" | validate_record_stream; then
            printf '%s\n' "$line" >> "$kept" || die_evidence 'could not stage a valid ledger row'
            remaining=$((remaining + 1))
            continue
        fi
        if jq -e . >/dev/null 2>&1 <<< "$line"; then
            reason='invalid ledger record'
        else
            reason='invalid JSON'
        fi
        record=$(jq -cn --arg timestamp "$timestamp" --arg source "$source_ledger" \
            --argjson line "$line_number" --arg reason "$reason" --arg raw "$line" \
            '{timestamp:$timestamp,source:$source,line:$line,reason:$reason,raw:$raw}') ||
            die_evidence 'could not encode quarantine audit record'
        printf '%s\n' "$record" >> "$audit" || die_evidence 'could not stage quarantine audit record'
        quarantined=$((quarantined + 1))
    done < "$LEDGER"
    validate_record_stream "$kept" || die_evidence 'ledger repair left invalid records'
    sidecar="$parent/ledger-quarantine.ndjson"
    if ((quarantined > 0)); then
        ensure_quarantine_file "$sidecar"
        cat -- "$audit" >> "$sidecar" || die_evidence "could not append quarantine audit: $sidecar"
        chmod 600 -- "$sidecar" || die_evidence "could not secure quarantine sidecar: $sidecar"
        mv -- "$kept" "$LEDGER" || die_evidence "could not install repaired ledger: $LEDGER"
        chmod 600 -- "$LEDGER" || die_evidence "could not secure repaired ledger: $LEDGER"
    fi
    printf 'quarantined=%s remaining=%s sidecar=%s\n' "$quarantined" "$remaining" "$sidecar"
    release_lock
}

covers_records() {
    local matches
    validate_inputs
    validate_text '--decision' "$DECISION"
    [[ -n $SCOPE ]] || die_usage '--scope is required for covers'
    validate_text '--scope' "$SCOPE"
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
        append|read|covers|quarantine|run-id)
            COMMAND=$1
            parse_options "$@"
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        '')
            die_usage 'a subcommand is required: append, read, covers, quarantine, or run-id'
            ;;
        *)
            die_usage "unknown subcommand: ${1:-}"
            ;;
    esac

    case $COMMAND in
        append) append_record ;;
        read) read_records ;;
        covers) covers_records ;;
        quarantine) quarantine_records ;;
        run-id) print_run_id ;;
    esac
}

main "$@"
