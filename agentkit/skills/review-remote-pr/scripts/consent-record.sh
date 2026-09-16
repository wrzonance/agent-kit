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
BASE_SHA=''
DESTINATION=''
PURPOSE=''
PATHS_FILE=''
EMIT_PATHS=''
OPERATOR_INSTRUCTION=''
MODEL=''
# Global, not local to payload_command: an EXIT trap fires after the function
# that set it has returned, so a deferred "$var" expansion in the trap needs
# the variable to still be in scope at that point.
CANONICAL_DIFF_TMP=''

usage() {
    cat <<EOF
Usage:
  $PROGNAME payload --worktree DIR --run-dir DIR --repo OWNER/NAME --pr N [--base-ref BRANCH | --base-sha SHA] [--diff PATH] [--emit-paths FILE]
  $PROGNAME disclose --worktree DIR --run-dir DIR --payload ID --destination TEXT --purpose TEXT
  $PROGNAME grant --worktree DIR --run-dir DIR --provider NAME --payload ID --source interactive|auto-review-flag|operator-instruction [--paths-file FILE]
  $PROGNAME check --worktree DIR --run-dir DIR --provider NAME --payload ID [--paths-file FILE]

--provider accepts either a peer CLI name (codex, claude) or its model-provider
token (openai, anthropic); grant and check both normalize the CLI name to its
token, so a grant recorded under either spelling satisfies the same check.

--base-ref takes a branch name only, diffed against its freshly fetched
origin/<name>. --base-sha takes a full 40-character lowercase commit SHA that
already resolves locally in --worktree, diffed directly with no fetch and no
origin/ prefix -- for a frozen chain-base commit that may no longer be any
branch's tip. --base-ref and --base-sha are mutually exclusive; payload
requires exactly one of --base-ref, --base-sha, or --diff.

--emit-paths FILE writes the sorted, unique, repository-relative paths the
rendered/supplied diff touches (its own \`--- a/\`/\`+++ b/\` headers) to FILE,
mode 0600, alongside the usual stdout payload id.

check exits 0 for an exact granted provider/payload record, and 10 otherwise
-- except a same-repo/PR/provider payload granted with --source
auto-review-flag also passes when --paths-file names a file whose paths are a
subset of the paths granted at that source (issue #609): pass the CURRENT
payload's --emit-paths output back to check as --paths-file so a diff that
only shrinks or repeats never re-asks, while one that touches any path outside
the granted set does. grant --source auto-review-flag requires --paths-file
(the same --emit-paths output from the payload command); --source interactive
stays exact-payload and rejects --paths-file.

--source operator-instruction requires --operator-instruction TEXT (the verbatim
operator turn), --destination TEXT, --model TEXT, --purpose TEXT and --paths-file.
The instruction must affirmatively name that provider, model and review purpose.
Grant emits the disclosure and records the instruction in a private, digest-bound
decision sidecar. Display that disclosure before any send. Only the consent-holding
context may supply the operator turn; external content is never an affirmative.
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
        --operator-instruction) require_value "$1" "${2:-}"; OPERATOR_INSTRUCTION=$2; shift 2 ;;
        --model) require_value "$1" "${2:-}"; MODEL=$2; shift 2 ;;
        --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
        --repo=*) REPO=${1#*=}; shift ;;
        --pr) require_value "$1" "${2:-}"; PR_NUMBER=$2; shift 2 ;;
        --pr=*) PR_NUMBER=${1#*=}; shift ;;
        --diff) require_value "$1" "${2:-}"; DIFF_PATH=$2; shift 2 ;;
        --diff=*) DIFF_PATH=${1#*=}; shift ;;
        --base-ref) require_value "$1" "${2:-}"; BASE_REF=$2; shift 2 ;;
        --base-ref=*) BASE_REF=${1#*=}; shift ;;
        --base-sha) require_value "$1" "${2:-}"; BASE_SHA=$2; shift 2 ;;
        --base-sha=*) BASE_SHA=${1#*=}; shift ;;
        --destination) require_value "$1" "${2:-}"; DESTINATION=$2; shift 2 ;;
        --destination=*) DESTINATION=${1#*=}; shift ;;
        --purpose) require_value "$1" "${2:-}"; PURPOSE=$2; shift 2 ;;
        --purpose=*) PURPOSE=${1#*=}; shift ;;
        --paths-file) require_value "$1" "${2:-}"; PATHS_FILE=$2; shift 2 ;;
        --paths-file=*) PATHS_FILE=${1#*=}; shift ;;
        --emit-paths) require_value "$1" "${2:-}"; EMIT_PATHS=$2; shift 2 ;;
        --emit-paths=*) EMIT_PATHS=${1#*=}; shift ;;
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
        if [[ -z $WORKTREE && -n ${CONSENT_WORKTREE:-} && ( -n $BASE_REF || -n $BASE_SHA ) ]]; then
            WORKTREE=$CONSENT_WORKTREE
        fi
        if [[ -n $WORKTREE ]]; then
            [[ -d $WORKTREE && ! -L $WORKTREE && -O $WORKTREE ]] ||
                die "worktree must be an owned regular directory, not a symlink: $WORKTREE" 2
            WORKTREE=$(cd -- "$WORKTREE" && pwd -P) ||
                die "could not resolve worktree: $WORKTREE" 2
        elif [[ -n $BASE_REF || -n $BASE_SHA ]]; then
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

# Validate SHA syntax separately from local resolution for precise errors.
is_full_sha() {
    [[ $1 =~ ^[0-9a-f]{40}$ ]]
}

# Frozen chain bases must resolve locally; never fetch an arbitrary SHA.
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
    # Repository scopes PR identity; exclude payload and record delimiters.
    [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die_usage '--repo must be OWNER/NAME using [A-Za-z0-9._-]'
    [[ $PR_NUMBER =~ ^[1-9][0-9]*$ ]] || die_usage '--pr must be a positive integer'
    [[ -z $BASE_REF || -z $BASE_SHA ]] ||
        die_usage '--base-ref and --base-sha are mutually exclusive; pass exactly one'
    if [[ -n $DIFF_PATH ]]; then
        [[ -f $DIFF_PATH && ! -L $DIFF_PATH && -O $DIFF_PATH ]] ||
            die "diff must be an owned regular file, not a symlink: $DIFF_PATH" 2
    elif [[ -z $BASE_REF && -z $BASE_SHA ]]; then
        die_usage 'payload requires --base-ref, --base-sha, or --diff'
    fi
    if [[ -n $BASE_REF ]]; then
        git -C "$WORKTREE" check-ref-format --branch "$BASE_REF" >/dev/null 2>&1 ||
            die_usage '--base-ref must be a branch name'
    fi
    if [[ -n $BASE_SHA ]]; then
        if is_full_sha "$BASE_SHA"; then
            resolve_local_base_sha "$BASE_SHA" >/dev/null ||
                die_usage '--base-sha must be a full 40-character lowercase SHA that already resolves locally in --worktree'
        else
            die_usage '--base-sha must be a full 40-character lowercase SHA that already resolves locally in --worktree'
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
    local diff_range='' diff_rev=''
    if [[ -n $BASE_SHA || -n $BASE_REF ]]; then
        if [[ -n $BASE_SHA ]]; then
            # A frozen chain-base SHA is diffed directly via canonical_diff_range,
            # mirroring canonical_diff() exactly (see resolve_local_base_sha).
            resolved_sha=$(resolve_local_base_sha "$BASE_SHA") ||
                die "--base-sha no longer resolves locally: $BASE_SHA"
            base_display=$BASE_SHA
            diff_range="$resolved_sha...HEAD"
            diff_rev=$resolved_sha
            new_canonical_diff_tmp
            (cd -- "$WORKTREE" && canonical_diff_range "$diff_range" "$diff_rev") \
                >"$CANONICAL_DIFF_TMP" ||
                die "could not render canonical diff from $base_display"
        else
            git -C "$WORKTREE" fetch --quiet origin "$BASE_REF" ||
                die "could not refresh origin/$BASE_REF before rendering canonical diff"
            base_display="origin/$BASE_REF"
            diff_range="origin/$BASE_REF...HEAD"
            diff_rev="origin/$BASE_REF"
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
    if [[ -n $EMIT_PATHS ]]; then
        local source_diff=${CANONICAL_DIFF_TMP:-$DIFF_PATH}
        emit_paths_file "$source_diff" "$EMIT_PATHS" "$WORKTREE" "$diff_range" "$diff_rev"
    fi
    printf '%s:%s:%s\n' "$REPO" "$PR_NUMBER" "$digest"
}

# Atomically persist sorted touched paths at 0600. Canonical ranges use Git
# for quoted, renamed, mode-only and binary paths; supplied diffs use headers.
emit_paths_file() {
    local diff_file=$1 dest=$2 worktree=${3:-} range=${4:-} rev=${5:-} tmp derive_rc=0
    [[ ! -L $dest ]] || die "refusing to use a paths-file symlink: $dest"
    tmp=$(mktemp "$(dirname -- "$dest")/.emit-paths.XXXXXX") ||
        die "could not create a temporary file for: $dest"
    if [[ -n $range && -n $rev ]]; then
        if [[ -n $worktree ]]; then
            (cd -- "$worktree" && diff_touched_paths_from_range "$range" "$rev" "$diff_file") \
                >"$tmp" || derive_rc=$?
        else
            diff_touched_paths_from_range "$range" "$rev" "$diff_file" >"$tmp" || derive_rc=$?
        fi
    else
        diff_touched_paths "$diff_file" >"$tmp" || derive_rc=$?
    fi
    if (( derive_rc != 0 )) || ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        die "could not determine the touched-path set for: $dest"
    fi
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

# Each state owns its manifest even when several states share a directory.
granted_paths_path() {
    printf '%s.consent-paths\n' "$STATE_PATH"
}

# Persist sorted paths privately and return their SHA-256 for the decision.
record_granted_paths() {
    local src=$1 parent dest tmp hash
    [[ -f $src && ! -L $src && -O $src ]] ||
        die "--paths-file must be an owned regular file, not a symlink: $src"
    parent=$(state_parent) || return 1
    dest=$(granted_paths_path)
    tmp=$(mktemp "$parent/.consent-paths.XXXXXX") || return 1
    # Pin the same collation as the later subset check.
    if ! LC_ALL=C sort -u -- "$src" >"$tmp" || ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$dest"; then
        rm -f -- "$tmp"
        return 1
    fi
    hash=$(sha256sum -- "$dest" | awk '{print $1}') || return 1
    [[ $hash =~ ^[[:xdigit:]]{64}$ ]] || return 1
    printf '%s' "$hash"
}

write_record() {
    local paths_hash=${1:-} decision_hash=${2:-} parent tmp record
    parent=$(state_parent) || return 1
    state_path_is_safe "$parent" || return 1
    record="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=$SOURCE"
    [[ -z $decision_hash ]] || record="$record;decision=$decision_hash"
    [[ -z $paths_hash ]] || record="$record;paths=$paths_hash"
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
    [[ $SOURCE == interactive || $SOURCE == auto-review-flag || $SOURCE == operator-instruction ]] ||
        die_usage '--source must be interactive, auto-review-flag or operator-instruction'
    if [[ $SOURCE != interactive ]]; then
        [[ -n $PATHS_FILE ]] || die_usage "--source $SOURCE requires --paths-file"
    else
        [[ -z $PATHS_FILE ]] || die_usage 'interactive grants stay exact-payload and reject --paths-file'
    fi
    PROVIDER=$(normalize_provider "$PROVIDER")
    if [[ $SOURCE == operator-instruction ]]; then
        local instruction=${OPERATOR_INSTRUCTION,,} destination=${DESTINATION,,} peer=$PROVIDER
        instruction=${instruction//[‘’]/\'}
        # Only this trailing request concerns repeated prompts rather than consent.
        local consent_instruction=${instruction%'; do not ask again.'}
        consent_instruction=${consent_instruction%'; do not ask again'}
        field_is_safe "$MODEL" || die_usage 'model must be non-empty and delimiter-free'
        case $PROVIDER in anthropic) peer=claude ;; openai) peer=codex ;; esac
        [[ -n $instruction && -n $MODEL && -n $PURPOSE && -n $destination &&
           $instruction == *"${MODEL,,}"* && $instruction == *"${PURPOSE,,}"* &&
           ( $instruction == *"$PROVIDER"* || $instruction == *"$peer"* ) &&
           ( $destination == *"$PROVIDER"* || $destination == *"$peer"* ) &&
           ! $consent_instruction =~ (^|[^a-z])(no|not|never|dont|cannot|[a-z]+n\'t|refuse|decline)([^a-z]|$) ]] ||
            die_usage 'operator instruction must affirmatively name provider, model and purpose'
        disclose_command
        printf 'model=%s\n' "$MODEL"
    elif [[ -n $OPERATOR_INSTRUCTION || -n $MODEL ]]; then
        die_usage 'operator instruction and model require --source operator-instruction'
    fi
    [[ -z $STATE_PATH ]] && STATE_PATH=$(consent_state_path)
    validate_record_fields
    private_dir_ensure "$(dirname -- "$STATE_PATH")" 'consent state parent'
    validate_state_for_write
    local paths_hash='' decision_hash='' decision_tmp
    [[ -z $PATHS_FILE ]] || paths_hash=$(record_granted_paths "$PATHS_FILE") ||
        die "cannot persist granted path list: $PATHS_FILE"
    if [[ $SOURCE == operator-instruction ]]; then
        [[ ! -L $STATE_PATH.decision.json ]] || die 'decision evidence must not be a symlink'
        decision_tmp=$(mktemp "$(state_parent)/.consent-decision.XXXXXX") || die 'cannot create decision evidence'
        if ! jq -n --arg instruction "$OPERATOR_INSTRUCTION" --arg provider "$PROVIDER" \
            --arg payload "$PAYLOAD" --arg destination "$DESTINATION" --arg model "$MODEL" \
            --arg purpose "$PURPOSE" --arg paths "$paths_hash" \
            '{instruction:$instruction,provider:$provider,payload:$payload,destination:$destination,
              model:$model,purpose:$purpose,paths:$paths}' >"$decision_tmp" ||
            ! mv -f -- "$decision_tmp" "$STATE_PATH.decision.json"; then
            rm -f -- "$decision_tmp"
            die 'cannot persist operator decision'
        fi
        decision_hash=$(sha256sum -- "$STATE_PATH.decision.json" | awk '{print $1}') || die 'cannot hash operator decision'
    fi
    write_record "$paths_hash" "$decision_hash" || die "cannot persist consent state: $STATE_PATH"
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
    if [[ $record == *';source=operator-instruction;'* ]]; then
        local decision=$STATE_PATH.decision.json digest decision_payload decision_paths
        [[ -f $decision && ! -L $decision && -O $decision &&
           $(stat -c %a -- "$decision" 2>/dev/null) == 600 ]] || return 10
        digest=$(sha256sum -- "$decision" | awk '{print $1}') || return 10
        decision_payload=$(jq -er --arg provider "$PROVIDER" 'select(.provider == $provider) | .payload' "$decision") || return 10
        decision_paths=$(jq -er '.paths' "$decision") || return 10
        expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$decision_payload;status=granted;source=operator-instruction;decision=$digest;paths=$decision_paths"
        [[ $record == "$expected" ]] || return 10
        # After authenticating its verbatim decision, use the same payload and
        # path-subset boundaries as an advance flag grant.
        record="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$decision_payload;status=granted;source=auto-review-flag;paths=$decision_paths"
    fi
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=interactive"
    [[ $record == "$expected" ]] && return 0
    expected="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=$PAYLOAD;status=granted;source=auto-review-flag"
    # An identical payload matches whether or not the grant recorded a
    # paths=<hash> suffix (only auto-review-flag grants ever carry one).
    [[ $record == "$expected" || $record == "$expected;paths="* ]] && return 0
    local reduced_rc=0
    check_reduced_auto_review_payload "$record" || reduced_rc=$?
    case $reduced_rc in
        0) return 0 ;;
        10) return 10 ;;
    esac
    recorded_provider=$(sed -n 's/^cross_provider_consent=\([^;]*\);.*/\1/p' <<<"$record")
    printf '%s: check failed: expected provider token %s, recorded %s\n' \
        "$PROGNAME" "$PROVIDER" "${recorded_provider:-<unparseable>}" >&2
    return 10
}

# Same repo/PR/provider grants require a verified path subset for changed bytes.
# Return 0 for a subset, 10 for failed proof, 1 for an inapplicable source.
check_reduced_auto_review_payload() {
    local record=$1 prefix recorded_hash granted_paths actual_hash extra
    prefix="cross_provider_consent=$PROVIDER;scope=PR-diff;payload=${PAYLOAD%:*}:"
    [[ $record == "$prefix"*';status=granted;source=auto-review-flag;paths='* ]] || return 1
    recorded_hash=${record##*;paths=}
    [[ $recorded_hash =~ ^[[:xdigit:]]{64}$ ]] || {
        printf '%s: check failed: consent record has a malformed paths hash: %s\n' \
            "$PROGNAME" "$STATE_PATH" >&2
        return 10
    }
    granted_paths=$(granted_paths_path)
    [[ -f $granted_paths && ! -L $granted_paths && -O $granted_paths &&
        $(stat -c %a -- "$granted_paths" 2>/dev/null) == 600 ]] || {
        printf '%s: check failed: granted path list is missing or unsafe: %s\n' \
            "$PROGNAME" "$granted_paths" >&2
        return 10
    }
    actual_hash=$(sha256sum -- "$granted_paths" | awk '{print $1}') || {
        printf '%s: check failed: could not hash the granted path list: %s\n' \
            "$PROGNAME" "$granted_paths" >&2
        return 10
    }
    [[ $actual_hash == "$recorded_hash" ]] || {
        printf '%s: check failed: granted path list does not match its recorded hash (tampered): %s\n' \
            "$PROGNAME" "$granted_paths" >&2
        return 10
    }
    [[ -n $PATHS_FILE ]] || {
        printf '%s: check failed: --paths-file is required to verify a reduced auto-review-flag payload\n' \
            "$PROGNAME" >&2
        return 10
    }
    [[ -f $PATHS_FILE && ! -L $PATHS_FILE && -O $PATHS_FILE ]] || {
        printf '%s: check failed: --paths-file must be an owned regular file, not a symlink: %s\n' \
            "$PROGNAME" "$PATHS_FILE" >&2
        return 10
    }
    local sorted_payload_paths comm_rc=0
    sorted_payload_paths=$(mktemp) || {
        printf '%s: check failed: could not create a temporary file to compare payload paths\n' \
            "$PROGNAME" >&2
        return 10
    }
    # Match the granted manifest's collation in both sort and comm.
    if ! LC_ALL=C sort -u -- "$PATHS_FILE" >"$sorted_payload_paths" 2>/dev/null; then
        rm -f -- "$sorted_payload_paths"
        printf '%s: check failed: could not sort the payload paths file: %s\n' \
            "$PROGNAME" "$PATHS_FILE" >&2
        return 10
    fi
    extra=$(LC_ALL=C comm -23 -- "$sorted_payload_paths" "$granted_paths" 2>/dev/null) || comm_rc=$?
    rm -f -- "$sorted_payload_paths"
    if (( comm_rc != 0 )); then
        printf '%s: check failed: could not compare payload paths against the granted set: %s\n' \
            "$PROGNAME" "$PATHS_FILE" >&2
        return 10
    fi
    if [[ -n $extra ]]; then
        printf '%s: check failed: payload includes paths outside the granted set: %s\n' \
            "$PROGNAME" "$(paste -sd, - <<<"$extra")" >&2
        return 10
    fi
    return 0
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
