#!/usr/bin/env bash
# consent-record.sh — executable, fail-closed consent for cross-provider diff review.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
COMMAND=${1:-}
STATE_PATH=''
PROVIDER=''
PAYLOAD=''
SOURCE=''
REPO=''
PR_NUMBER=''
DIFF_PATH=''
DESTINATION=''
PURPOSE=''

usage() {
    cat <<EOF
Usage:
  $PROGNAME payload --repo OWNER/NAME --pr N --diff PATH
  $PROGNAME disclose --payload ID --destination TEXT --purpose TEXT
  $PROGNAME grant --state PATH --provider NAME --payload ID --source interactive|auto-review-flag
  $PROGNAME check --state PATH --provider NAME --payload ID

check exits 0 only for an exact granted provider/payload record, and 10 otherwise.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "${2:-1}"
}

require_value() {
    [[ -n ${2:-} ]] || die "option $1 requires a value" 2
}

parse_options() {
    shift
    while (($#)); do
        case $1 in
        --state) require_value "$1" "${2:-}"; STATE_PATH=$2; shift 2 ;;
        --state=*) STATE_PATH=${1#*=}; shift ;;
        --provider) require_value "$1" "${2:-}"; PROVIDER=$2; shift 2 ;;
        --provider=*) PROVIDER=${1#*=}; shift ;;
        --payload) require_value "$1" "${2:-}"; PAYLOAD=$2; shift 2 ;;
        --payload=*) PAYLOAD=${1#*=}; shift ;;
        --source) require_value "$1" "${2:-}"; SOURCE=$2; shift 2 ;;
        --source=*) SOURCE=${1#*=}; shift ;;
        --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
        --repo=*) REPO=${1#*=}; shift ;;
        --pr) require_value "$1" "${2:-}"; PR_NUMBER=$2; shift 2 ;;
        --pr=*) PR_NUMBER=${1#*=}; shift ;;
        --diff) require_value "$1" "${2:-}"; DIFF_PATH=$2; shift 2 ;;
        --diff=*) DIFF_PATH=${1#*=}; shift ;;
        --destination) require_value "$1" "${2:-}"; DESTINATION=$2; shift 2 ;;
        --destination=*) DESTINATION=${1#*=}; shift ;;
        --purpose) require_value "$1" "${2:-}"; PURPOSE=$2; shift 2 ;;
        --purpose=*) PURPOSE=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" 2 ;;
        esac
    done
}

field_is_safe() {
    local value=$1
    [[ -n $value && $value != *';'* && $value != *'='* &&
        $value != *$'\n'* && $value != *$'\r'* ]]
}

validate_payload_inputs() {
    # The repository is part of the payload identity because PR numbers are only
    # unique within one repository. Without it, the same PR number and identical
    # diff bytes in a second repository derive the same payload, so a reused
    # state record would satisfy `check` for a repository the user never
    # consented to disclose. The character class is deliberately narrower than
    # GitHub's own -- it excludes the ':' payload delimiter and the ';'/'='
    # record delimiters, so no repository name can forge a payload or a field.
    [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die '--repo must be OWNER/NAME using [A-Za-z0-9._-]' 2
    [[ $PR_NUMBER =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer' 2
    [[ -f $DIFF_PATH && ! -L $DIFF_PATH && -O $DIFF_PATH ]] ||
        die "diff must be an owned regular file, not a symlink: $DIFF_PATH" 2
}

payload_command() {
    validate_payload_inputs
    local digest
    digest=$(sha256sum -- "$DIFF_PATH" | awk '{print $1}') ||
        die "could not hash diff: $DIFF_PATH"
    [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || die 'sha256sum returned an invalid digest'
    printf '%s:%s:%s\n' "$REPO" "$PR_NUMBER" "$digest"
}

validate_record_fields() {
    field_is_safe "$PROVIDER" || die 'provider contains a record delimiter' 2
    field_is_safe "$PAYLOAD" || die 'payload contains a record delimiter' 2
}

state_parent() {
    local parent
    [[ -n $STATE_PATH ]] || return 1
    parent=$(dirname -- "$STATE_PATH")
    [[ -d $parent && ! -L $parent && -O $parent ]] || return 1
    [[ $(stat -c %a -- "$parent" 2>/dev/null) == 700 ]] || return 1
    printf '%s\n' "$parent"
}

state_path_is_safe() {
    local parent=$1
    [[ ! -L $STATE_PATH ]] || return 1
    if [[ -e $STATE_PATH ]]; then
        [[ -f $STATE_PATH && -O $STATE_PATH ]] || return 1
        [[ $(stat -c %a -- "$STATE_PATH" 2>/dev/null) == 600 ]] || return 1
    fi
}

validate_state_for_write() {
    local parent
    parent=$(state_parent) || die "state parent must be an owned private mode-0700 directory: $STATE_PATH"
    state_path_is_safe "$parent" || die "state path is not an owned mode-0600 regular file: $STATE_PATH"
}

write_record() {
    local parent tmp record
    parent=$(state_parent) || return 1
    state_path_is_safe "$parent" || return 1
    record="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=$SOURCE"
    tmp=$(mktemp "$parent/.consent-record.XXXXXX") || return 1
    if ! printf '%s\n' "$record" >"$tmp" || ! chmod 600 -- "$tmp" ||
        ! mv -f -- "$tmp" "$STATE_PATH"; then
        rm -f -- "$tmp"
        return 1
    fi
    printf '%s\n' "$record"
}

disclose_command() {
    field_is_safe "$PAYLOAD" || die 'payload contains a record delimiter' 2
    [[ -n $DESTINATION && $DESTINATION != *$'\n'* && $DESTINATION != *$'\r'* ]] ||
        die 'destination must be non-empty and single-line' 2
    [[ -n $PURPOSE && $PURPOSE != *$'\n'* && $PURPOSE != *$'\r'* ]] ||
        die 'purpose must be non-empty and single-line' 2
    printf 'payload=%s\ndestination=%s\npurpose=%s\n' "$PAYLOAD" "$DESTINATION" "$PURPOSE"
}

grant_command() {
    [[ $SOURCE == interactive || $SOURCE == auto-review-flag ]] ||
        die '--source must be interactive or auto-review-flag' 2
    validate_record_fields
    validate_state_for_write
    write_record || die "cannot persist consent state: $STATE_PATH"
}

check_command() {
    local parent record expected line_count
    if ! field_is_safe "$PROVIDER" || ! field_is_safe "$PAYLOAD"; then
        return 10
    fi
    parent=$(state_parent 2>/dev/null) || return 10
    state_path_is_safe "$parent" || return 10
    [[ -f $STATE_PATH && ! -L $STATE_PATH && -O $STATE_PATH ]] || return 10
    line_count=$(wc -l <"$STATE_PATH" 2>/dev/null) || return 10
    [[ $line_count -eq 1 ]] || return 10
    record=$(cat -- "$STATE_PATH" 2>/dev/null) || return 10
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=interactive"
    [[ $record == "$expected" ]] && return 0
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=auto-review-flag"
    [[ $record == "$expected" ]] && return 0
    return 10
}

main() {
    case $COMMAND in
    payload|disclose|grant|check) parse_options "$@" ;;
    -h|--help) usage; exit 0 ;;
    '') usage >&2; exit 2 ;;
    *) die "unknown subcommand: $COMMAND" 2 ;;
    esac

    case $COMMAND in
    payload) payload_command ;;
    disclose) disclose_command ;;
    grant) grant_command ;;
    check) check_command ;;
    esac
}

main "$@"
