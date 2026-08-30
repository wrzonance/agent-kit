#!/usr/bin/env bash
# consent-record.sh — executable, fail-closed consent for cross-provider diff review.
set -euo pipefail
umask 077

readonly CONSENT_STATE_FILENAME='cross-provider-consent'
# adversarial-run.sh sources this file solely for the shared state filename.
# Keep that library surface side-effect free; the executable path below is
# entered only when this file is the process entry point.
if [[ ${BASH_SOURCE[0]} != "$0" ]]; then
    return 0
fi

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/canonical-diff.sh"
COMMAND=${1:-}
STATE_PATH=''
WORKTREE=''
RUN_DIR=''
PROVIDER=''
PAYLOAD=''
SOURCE=''
REPO=''
PR_NUMBER=''
DIFF_PATH=''
BASE_REF=''
DESTINATION=''
PURPOSE=''
# Global, not local to payload_command: an EXIT trap fires after the function
# that set it has returned, so a deferred "$var" expansion in the trap needs
# the variable to still be in scope at that point.
CANONICAL_DIFF_TMP=''

usage() {
    cat <<EOF
Usage:
  $PROGNAME payload --worktree DIR --run-dir DIR --repo OWNER/NAME --pr N [--base-ref BRANCH|SHA] [--diff PATH]
  $PROGNAME disclose --worktree DIR --run-dir DIR --payload ID --destination TEXT --purpose TEXT
  $PROGNAME grant --worktree DIR --run-dir DIR --provider NAME --payload ID --source interactive|auto-review-flag
  $PROGNAME check --worktree DIR --run-dir DIR --provider NAME --payload ID

--provider accepts either a peer CLI name (codex, claude) or its model-provider
token (openai, anthropic); grant and check both normalize the CLI name to its
token, so a grant recorded under either spelling satisfies the same check.

--base-ref accepts either a branch name (diffed against its freshly fetched
origin/<name>) or a full 40-character lowercase SHA that already resolves
locally in --worktree (diffed directly, with no fetch and no origin/ prefix --
for a frozen chain-base commit that may no longer be any branch's tip).

check exits 0 only for an exact granted provider/payload record, and 10 otherwise.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "${2:-1}"
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

require_value() {
    [[ -n ${2:-} ]] || die_usage "option $1 requires a value"
}

parse_options() {
    shift
    while (($#)); do
        case $1 in
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --worktree) require_value "$1" "${2:-}"; WORKTREE=$2; shift 2 ;;
        --worktree=*) WORKTREE=${1#*=}; shift ;;
        --run-dir) require_value "$1" "${2:-}"; RUN_DIR=$2; shift 2 ;;
        --run-dir=*) RUN_DIR=${1#*=}; shift ;;
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
        --base-ref) require_value "$1" "${2:-}"; BASE_REF=$2; shift 2 ;;
        --base-ref=*) BASE_REF=${1#*=}; shift ;;
        --destination) require_value "$1" "${2:-}"; DESTINATION=$2; shift 2 ;;
        --destination=*) DESTINATION=${1#*=}; shift ;;
        --purpose) require_value "$1" "${2:-}"; PURPOSE=$2; shift 2 ;;
        --purpose=*) PURPOSE=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown option: $1" ;;
        esac
    done
}

validate_context() {
    [[ -z $STATE_PATH || -z $RUN_DIR ]] ||
        die_usage '--state cannot be combined with --run-dir; use the shared consent state path'
    case $COMMAND in
    payload)
        # Canonical rendering needs a concrete checkout. Supplied diff bytes do
        # not, which keeps provider-helper compatibility without ever deriving
        # a worktree from the caller's current directory for the canonical path.
        if [[ -z $WORKTREE && -n $BASE_REF && -n ${CONSENT_WORKTREE:-} ]]; then
            WORKTREE=$CONSENT_WORKTREE
        fi
        if [[ -n $WORKTREE ]]; then
            [[ -d $WORKTREE && ! -L $WORKTREE && -O $WORKTREE ]] ||
                die "worktree must be an owned regular directory, not a symlink: $WORKTREE" 2
            WORKTREE=$(cd -- "$WORKTREE" && pwd -P) ||
                die "could not resolve worktree: $WORKTREE" 2
        elif [[ -n $BASE_REF ]]; then
            die_usage '--worktree is required when rendering a canonical diff'
        fi
        ;;
    grant|check)
        [[ -n $STATE_PATH || -n $RUN_DIR ]] ||
            die_usage "$COMMAND requires --run-dir or --state"
        ;;
    disclose)
        :
        ;;
    esac
    if [[ -n $RUN_DIR ]]; then
        private_dir_ensure "$RUN_DIR" '--run-dir'
    fi
}

consent_state_path() {
    printf '%s/state/%s\n' "$RUN_DIR" "$CONSENT_STATE_FILENAME"
}


# `peer-cli=` names a CLI (codex, claude); adversarial-run.sh checks the
# consent record against the model-provider token that CLI runs on (openai,
# anthropic). Normalizing here means a grant recorded under either spelling
# satisfies the same check, so the caller never has to read the runner
# source to find the "right" token. Unknown values pass through unchanged --
# field_is_safe still governs whether they are ultimately accepted.
normalize_provider() {
    case $1 in
    codex) printf '%s' openai ;;
    claude) printf '%s' anthropic ;;
    *) printf '%s' "$1" ;;
    esac
}

# is_full_sha -- true when a --base-ref candidate has the shape of a full
# commit SHA (40 lowercase hex characters), before any local-resolution
# attempt. Kept separate from resolution so a 40-hex value that fails to
# resolve locally is named as "a SHA, but one this worktree cannot resolve"
# rather than silently falling through to the branch-name validator.
is_full_sha() {
    [[ $1 =~ ^[0-9a-f]{40}$ ]]
}

# resolve_local_base_sha -- print the resolved commit SHA for a full-SHA
# base-ref candidate, only when it already resolves locally; never fetches
# to make it resolve. A frozen chain-base commit is often unreachable from
# any branch tip by the time a later PR's review runs (the predecessor
# branch moved on, or was deleted after merge) -- requiring local
# resolution, and never attempting `git fetch <sha>`, is what makes it
# usable at all: many Git servers refuse to serve an arbitrary commit by
# SHA regardless.
resolve_local_base_sha() {
    local candidate=$1
    git -C "$WORKTREE" rev-parse --verify --quiet "${candidate}^{commit}" 2>/dev/null
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
        die_usage '--repo must be OWNER/NAME using [A-Za-z0-9._-]'
    [[ $PR_NUMBER =~ ^[1-9][0-9]*$ ]] || die_usage '--pr must be a positive integer'
    if [[ -n $DIFF_PATH ]]; then
        [[ -f $DIFF_PATH && ! -L $DIFF_PATH && -O $DIFF_PATH ]] ||
            die "diff must be an owned regular file, not a symlink: $DIFF_PATH" 2
    elif [[ -z $BASE_REF ]]; then
        die_usage 'payload requires --base-ref or --diff'
    fi
    if [[ -n $BASE_REF ]]; then
        if is_full_sha "$BASE_REF"; then
            resolve_local_base_sha "$BASE_REF" >/dev/null ||
                die_usage '--base-ref must be a branch name or a full SHA that already resolves locally in --worktree'
        else
            git -C "$WORKTREE" check-ref-format --branch "$BASE_REF" >/dev/null 2>&1 ||
                die_usage '--base-ref must be a branch name or a full SHA that already resolves locally in --worktree'
        fi
    fi
}

cleanup_canonical_diff_tmp() {
    [[ -z $CANONICAL_DIFF_TMP ]] || rm -f -- "$CANONICAL_DIFF_TMP"
}

# Mirrors adversarial-run.sh's own build_diff emptiness check byte-for-byte:
# sha256sum of empty (or whitespace-only) input is still a well-formed 64-hex
# digest, so this has to run before hashing, not rely on digest shape.
diff_is_empty() {
    [[ -s $1 ]] || return 0
    grep -q '[^[:space:]]' -- "$1" || return 0
    return 1
}

new_canonical_diff_tmp() {
    CANONICAL_DIFF_TMP=$(mktemp) || die 'could not create a temporary file for the canonical diff'
    trap cleanup_canonical_diff_tmp EXIT
}

payload_command() {
    validate_payload_inputs
    local digest canonical_digest supplied_digest base_display resolved_sha
    if [[ -n $BASE_REF ]]; then
        if is_full_sha "$BASE_REF"; then
            # A frozen chain-base SHA is diffed directly, never via
            # canonical_diff()'s "origin/<ref>" form: that form requires a
            # branch name (check-ref-format rejects a bare SHA), and
            # refreshing "origin/<sha>" is not meaningful -- the commit is
            # already local by definition (see resolve_local_base_sha). The
            # flags below mirror canonical_diff() exactly so a SHA-based
            # render and an equivalent branch-based render hash identically.
            resolved_sha=$(resolve_local_base_sha "$BASE_REF") ||
                die "--base-ref SHA no longer resolves locally: $BASE_REF"
            base_display=$BASE_REF
            new_canonical_diff_tmp
            (cd -- "$WORKTREE" && git --no-pager diff --find-renames --unified=25 "$resolved_sha...HEAD") \
                >"$CANONICAL_DIFF_TMP" ||
                die "could not render canonical diff from $base_display"
        else
            git -C "$WORKTREE" fetch --quiet origin "$BASE_REF" ||
                die "could not refresh origin/$BASE_REF before rendering canonical diff"
            base_display="origin/$BASE_REF"
            new_canonical_diff_tmp
            (cd -- "$WORKTREE" && canonical_diff "$BASE_REF") >"$CANONICAL_DIFF_TMP" ||
                die "could not render canonical diff from origin/$BASE_REF"
        fi
        chmod 600 -- "$CANONICAL_DIFF_TMP" || die "could not secure the canonical diff temp file"
        diff_is_empty "$CANONICAL_DIFF_TMP" &&
            die "the canonical diff from $base_display for worktree $WORKTREE is empty; HEAD may already equal $base_display"
        canonical_digest=$(sha256sum -- "$CANONICAL_DIFF_TMP" | awk '{print $1}') ||
            die "could not hash canonical diff from $base_display"
        [[ $canonical_digest =~ ^[[:xdigit:]]{64}$ ]] ||
            die 'canonical diff renderer returned an invalid digest'
        if [[ -n $DIFF_PATH ]]; then
            diff_is_empty "$DIFF_PATH" &&
                die "the supplied diff is empty: $DIFF_PATH (worktree: ${WORKTREE:-<not resolved>}); HEAD may equal the base"
            supplied_digest=$(sha256sum -- "$DIFF_PATH" | awk '{print $1}') ||
                die "could not hash diff: $DIFF_PATH"
            [[ $supplied_digest == "$canonical_digest" ]] ||
                die 'supplied diff does not match the canonical adversarial rendering'
        fi
        digest=$canonical_digest
    else
        diff_is_empty "$DIFF_PATH" &&
            die "the supplied diff is empty: $DIFF_PATH (worktree: ${WORKTREE:-<not resolved>}); HEAD may equal the intended base"
        digest=$(sha256sum -- "$DIFF_PATH" | awk '{print $1}') ||
            die "could not hash diff: $DIFF_PATH"
    fi
    [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || die 'sha256sum returned an invalid digest'
    printf '%s:%s:%s\n' "$REPO" "$PR_NUMBER" "$digest"
}

validate_record_fields() {
    field_is_safe "$PROVIDER" || die_usage 'provider contains a record delimiter'
    field_is_safe "$PAYLOAD" || die_usage 'payload contains a record delimiter'
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
    parent=$(dirname -- "$STATE_PATH")
    private_dir_ensure "$parent" "state parent"
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
    field_is_safe "$PAYLOAD" || die_usage 'payload contains a record delimiter'
    [[ -n $DESTINATION && $DESTINATION != *$'\n'* && $DESTINATION != *$'\r'* ]] ||
        die_usage 'destination must be non-empty and single-line'
    [[ -n $PURPOSE && $PURPOSE != *$'\n'* && $PURPOSE != *$'\r'* ]] ||
        die_usage 'purpose must be non-empty and single-line'
    printf 'payload=%s\ndestination=%s\npurpose=%s\n' "$PAYLOAD" "$DESTINATION" "$PURPOSE"
}

grant_command() {
    [[ $SOURCE == interactive || $SOURCE == auto-review-flag ]] ||
        die_usage '--source must be interactive or auto-review-flag'
    PROVIDER=$(normalize_provider "$PROVIDER")
    [[ -z $STATE_PATH ]] && STATE_PATH=$(consent_state_path)
    validate_record_fields
    private_dir_ensure "$(dirname -- "$STATE_PATH")" 'consent state parent'
    validate_state_for_write
    write_record || die "cannot persist consent state: $STATE_PATH"
}

check_command() {
    local parent record expected line_count recorded_provider
    PROVIDER=$(normalize_provider "$PROVIDER")
    [[ -z $STATE_PATH ]] && STATE_PATH=$(consent_state_path)
    if ! field_is_safe "$PROVIDER" || ! field_is_safe "$PAYLOAD"; then
        printf '%s: check failed: --provider and --payload must be non-empty and delimiter-free\n' \
            "$PROGNAME" >&2
        return 10
    fi
    parent=$(state_parent 2>/dev/null) || {
        printf '%s: check failed: no consent record at %s (expected provider token: %s)\n' \
            "$PROGNAME" "$STATE_PATH" "$PROVIDER" >&2
        return 10
    }
    state_path_is_safe "$parent" || {
        printf '%s: check failed: consent record path is not an owned mode-0600 file: %s (expected provider token: %s)\n' \
            "$PROGNAME" "$STATE_PATH" "$PROVIDER" >&2
        return 10
    }
    [[ -f $STATE_PATH && ! -L $STATE_PATH && -O $STATE_PATH ]] || {
        printf '%s: check failed: no consent record found (expected provider token: %s)\n' \
            "$PROGNAME" "$PROVIDER" >&2
        return 10
    }
    line_count=$(wc -l <"$STATE_PATH" 2>/dev/null) || {
        printf '%s: check failed: consent record is unreadable: %s\n' "$PROGNAME" "$STATE_PATH" >&2
        return 10
    }
    [[ $line_count -eq 1 ]] || {
        printf '%s: check failed: consent record is malformed, expected exactly one line: %s\n' \
            "$PROGNAME" "$STATE_PATH" >&2
        return 10
    }
    record=$(cat -- "$STATE_PATH" 2>/dev/null) || {
        printf '%s: check failed: could not read consent record: %s\n' "$PROGNAME" "$STATE_PATH" >&2
        return 10
    }
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=interactive"
    [[ $record == "$expected" ]] && return 0
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=auto-review-flag"
    [[ $record == "$expected" ]] && return 0
    recorded_provider=$(sed -n 's/^cross_provider_consent=\([^;]*\);.*/\1/p' <<<"$record")
    printf '%s: check failed: expected provider token %s, recorded %s\n' \
        "$PROGNAME" "$PROVIDER" "${recorded_provider:-<unparseable>}" >&2
    return 10
}

main() {
    case $COMMAND in
    payload|disclose|grant|check) parse_options "$@" ;;
    -h|--help) usage; exit 0 ;;
    '') die_usage 'a subcommand is required: payload, disclose, grant, or check' ;;
    *) die_usage "unknown subcommand: $COMMAND" ;;
    esac

    validate_context
    case $COMMAND in
    payload) payload_command ;;
    disclose) disclose_command ;;
    grant) grant_command ;;
    check) check_command ;;
    esac
}

main "$@"
