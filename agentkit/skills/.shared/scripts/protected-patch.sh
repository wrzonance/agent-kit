#!/usr/bin/env bash
# Scope a hook/harness patch through a temporary index, or apply it only after
# the existing session ledger covers that exact prospective staged tree.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/protected-paths.sh"

command=${1:-}
[[ -z $command ]] || shift
patch_file=''
proposal_path=''
content_file=''
output_file=''
ledger=''
run_id=''
ledger_scope=''
temp_index=''
temp_output=''
failure_class=usage
failure_state=arguments
failure_action=correct-arguments

usage() {
    cat <<EOF
Usage:
  $PROGRAM draft --path REPO_PATH --content ABSOLUTE_FILE --output ABSOLUTE_PATCH
  $PROGRAM scope --patch FILE
  $PROGRAM apply --patch FILE --ledger FILE --run-id ID --ledger-scope SCOPE

draft turns proposed content stored outside the protected path into a reviewable
unified patch without writing live configuration. scope validates that patch,
configuration, applies it to a temporary index, and prints the exact
protected-tree:<base>:<tree> approval scope without touching the live index or
worktree. apply recomputes that scope, requires an existing covering
authorize:protected-commit decision, then applies and stages the reviewed patch.
EOF
}

failure_result() {
    local status=$?
    if ((status != 0)); then
        printf 'failure-v1 class=%q command=%q evidence=%q state=%q next_action=%q\n' \
            "$failure_class" protected-patch stderr "$failure_state" "$failure_action" >&2
    fi
    [[ -z $temp_index ]] || rm -f -- "$temp_index"
    [[ -z $temp_output ]] || rm -f -- "$temp_output"
    return "$status"
}
trap failure_result EXIT

die() {
    local status=$1
    shift
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    failure_state=$*
    ((status != 2)) || usage >&2
    exit "$status"
}

need_value() { (($# >= 2)) || die 2 "$1 requires a value"; }

parse_args() {
    while (($#)); do
        case $1 in
            --patch) need_value "$@"; patch_file=$2; shift 2 ;;
            --path) need_value "$@"; proposal_path=$2; shift 2 ;;
            --content) need_value "$@"; content_file=$2; shift 2 ;;
            --output) need_value "$@"; output_file=$2; shift 2 ;;
            --ledger) need_value "$@"; ledger=$2; shift 2 ;;
            --run-id) need_value "$@"; run_id=$2; shift 2 ;;
            --ledger-scope) need_value "$@"; ledger_scope=$2; shift 2 ;;
            --) shift; (($# == 0)) || die 2 "unexpected argument after --: $1"; break ;;
            -h|--help) usage; exit 0 ;;
            *) die 2 "unknown argument: $1" ;;
        esac
    done
}

validate_args() {
    [[ $command == draft || $command == scope || $command == apply ]] ||
        die 2 'subcommand must be draft, scope, or apply'
    if [[ $command == draft ]]; then
        [[ -n $proposal_path && -n $content_file && -n $output_file ]] ||
            die 2 'draft requires --path, --content, and --output together'
        [[ $content_file == /* && $output_file == /* ]] ||
            die 2 '--content and --output must be absolute paths'
        [[ $proposal_path != /* && $proposal_path != *[[:cntrl:]]* && $proposal_path != *\\* ]] ||
            die 2 '--path must be a safe repository-relative path'
        case /$proposal_path/ in *'/../'*|*'/./'*|*'//'*) die 2 '--path contains unsafe components' ;; esac
        [[ -f $content_file && ! -L $content_file && -r $content_file && -O $content_file ]] ||
            die 2 '--content must be an owned, readable regular file'
        [[ ! -e $output_file && ! -L $output_file ]] || die 2 '--output must not already exist'
        [[ -z $ledger && -z $run_id && -z $ledger_scope && -z $patch_file ]] ||
            die 2 'draft accepts only --path, --content, and --output'
        return 0
    fi
    [[ -n $patch_file ]] || die 2 '--patch is required'
    [[ -f $patch_file && ! -L $patch_file && -r $patch_file && -O $patch_file ]] ||
        die 2 '--patch must be an owned, readable regular file'
    if [[ $command == apply ]]; then
        [[ -n $ledger && -n $run_id && -n $ledger_scope ]] ||
            die 2 'apply requires --ledger, --run-id, and --ledger-scope together'
    elif [[ -n $ledger || -n $run_id || -n $ledger_scope ]]; then
        die 2 'ledger arguments are valid only for apply'
    fi
}

draft_proposal() {
    local root output_parent output_name output_relative declared old_file diff_rc=0
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die 1 'not inside a Git worktree'
    root=$(cd -- "$root" && pwd -P) || die 1 'could not resolve the repository root'
    cd -- "$root" || die 1 'could not enter the repository root'
    shared_preparation_restricted_pattern "$proposal_path" "$root" 0 >/dev/null ||
        die 2 "proposal path is not preparation-restricted: $proposal_path"
    [[ ! -L $proposal_path ]] || die 2 "proposal path must not be a symlink: $proposal_path"
    [[ $proposal_path != .git && $proposal_path != .git/* ]] || {
        failure_class=runtime-restriction
        failure_action=preserve-proposal-and-report-untrackable-git-metadata
        die 1 "Git metadata cannot be represented by a staged-tree grant: $proposal_path"
    }
    content_file=$(readlink -f -- "$content_file" 2>/dev/null) || die 1 'could not resolve proposed content'
    output_parent=$(dirname -- "$output_file")
    [[ -d $output_parent && -O $output_parent ]] ||
        die 2 '--output parent must be an owned, existing directory'
    output_parent=$(cd -- "$output_parent" && pwd -P) || die 1 'could not resolve the output parent'
    output_name=$(basename -- "$output_file")
    output_file=$output_parent/$output_name
    [[ ! -e $output_file && ! -L $output_file ]] || die 2 '--output must not already exist'
    if [[ $output_file == "$root"/* ]]; then
        output_relative=${output_file#"$root"/}
        declared=''
        if [[ -x $SCRIPT_DIR/repo-config.sh ]]; then
            declared=$("$SCRIPT_DIR/repo-config.sh" --repo-root "$root" \
                --get AGENT_PROTECTED_PATHS 2>/dev/null || true)
        fi
        shared_protected_pattern "$output_relative" "$root" "$declared" 0 >/dev/null &&
            die 2 '--output must be outside protected paths'
    fi
    temp_output=$(mktemp "$output_parent/.protected-patch.XXXXXX") || die 1 'could not allocate patch output'
    old_file=$proposal_path
    [[ -e $old_file ]] || old_file=/dev/null
    diff -u --label "a/$proposal_path" --label "b/$proposal_path" -- \
        "$old_file" "$content_file" >"$temp_output" || diff_rc=$?
    ((diff_rc == 1)) || {
        ((diff_rc == 0)) && die 2 'proposed content does not change the protected path'
        die 1 'could not generate the protected patch'
    }
    chmod 600 -- "$temp_output" || die 1 'could not secure the protected patch'
    ln -- "$temp_output" "$output_file" || die 1 'could not publish the protected patch'
    rm -f -- "$temp_output"
    temp_output=''
    printf 'patch=%s path=%s\n' "$output_file" "$proposal_path"
}

proposal_scope=''
proposal_paths=''
proposal_tree=''
build_proposal() {
    local root git_index base before_tree path patch_numstat matched=0
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die 1 'not inside a Git worktree'
    base=$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || die 1 'repository HEAD has no commit'
    patch_file=$(readlink -f -- "$patch_file" 2>/dev/null) || die 1 'could not resolve the patch path'
    cd -- "$root" || die 1 'could not enter the repository root'
    patch_numstat=$(git apply --numstat -- "$patch_file" 2>/dev/null) || die 1 'could not inspect patch paths'
    while IFS=$'\t' read -r _ _ path; do
        [[ $path != .git && $path != .git/* ]] || {
            failure_class=runtime-restriction
            failure_action=preserve-proposal-and-report-untrackable-git-metadata
            die 1 "Git metadata cannot be represented by a staged-tree grant: $path"
        }
    done <<< "$patch_numstat"
    git_index=$(git rev-parse --git-path index 2>/dev/null) || die 1 'could not resolve the live Git index'
    [[ $git_index == /* ]] || git_index=$root/$git_index
    temp_index=$(mktemp) || die 1 'could not allocate a temporary Git index'
    rm -f -- "$temp_index"
    if [[ -f $git_index ]]; then
        cp -- "$git_index" "$temp_index" || die 1 'could not copy the live Git index'
    else
        GIT_INDEX_FILE=$temp_index git read-tree HEAD >/dev/null 2>&1 ||
            die 1 'could not initialize the temporary Git index'
    fi
    before_tree=$(GIT_INDEX_FILE=$temp_index git write-tree 2>/dev/null) || {
        failure_class=content-conflict
        failure_action=resolve-index-conflicts-before-protected-approval
        die 1 'live index has unresolved entries; no concrete proposal tree exists'
    }
    GIT_INDEX_FILE=$temp_index git apply --cached --check --whitespace=nowarn -- "$patch_file" \
        >/dev/null 2>&1 || die 1 'patch does not apply cleanly to the current index'
    GIT_INDEX_FILE=$temp_index git apply --cached --whitespace=nowarn -- "$patch_file" \
        >/dev/null 2>&1 || die 1 'could not apply patch to the temporary index'
    proposal_tree=$(GIT_INDEX_FILE=$temp_index git write-tree 2>/dev/null) ||
        die 1 'could not derive the proposed Git tree'
    [[ $proposal_tree != "$before_tree" ]] || die 2 'patch produces no staged change'
    proposal_paths=$(git diff --name-only --no-renames "$before_tree" "$proposal_tree") ||
        die 1 'could not inspect proposed paths'
    while IFS= read -r path; do
        [[ -n $path ]] || continue
        matched=1
        shared_preparation_restricted_pattern "$path" "$root" 0 >/dev/null ||
            die 2 "proposal path is not preparation-restricted: $path"
    done <<< "$proposal_paths"
    ((matched)) || die 2 'patch has no proposal paths'
    proposal_scope=$(shared_protected_commit_scope "$base" "$proposal_tree") ||
        die 1 'could not format the protected proposal scope'
}

scope_proposal() {
    local joined
    joined=${proposal_paths//$'\n'/,}
    printf 'approval_scope=%s paths=%s\n' "$proposal_scope" "$joined"
}

apply_proposal() {
    if [[ $ledger_scope != "$proposal_scope" ]]; then
        failure_class=permission-trust-refusal
        failure_action=hand-back-protected-patch-for-authorization
        die 3 "ledger scope does not match the concrete proposal: expected $proposal_scope"
    fi
    if [[ ! -x $SCRIPT_DIR/session-ledger.sh ]] ||
        ! "$SCRIPT_DIR/session-ledger.sh" covers --ledger "$ledger" --run-id "$run_id" \
            --decision "$SHARED_PROTECTED_COMMIT_DECISION" --scope "$proposal_scope" \
            >/dev/null 2>&1; then
        failure_class=permission-trust-refusal
        failure_action=hand-back-protected-patch-for-authorization
        die 3 "no covering $SHARED_PROTECTED_COMMIT_DECISION decision for $proposal_scope"
    fi
    git apply --index --check --whitespace=nowarn -- "$patch_file" >/dev/null 2>&1 ||
        die 1 'approved patch no longer applies cleanly to the live index and worktree'
    git apply --index --whitespace=nowarn -- "$patch_file" >/dev/null 2>&1 ||
        die 1 'could not apply the approved patch to the live index and worktree'
    [[ $(git write-tree 2>/dev/null) == "$proposal_tree" ]] ||
        die 1 'applied index does not match the approved proposal tree'
    printf 'applied_scope=%s paths=%s\n' "$proposal_scope" "${proposal_paths//$'\n'/,}"
}

parse_args "$@"
validate_args
failure_class=unknown
failure_action=inspect-diagnostics
if [[ $command == draft ]]; then draft_proposal; exit 0; fi
build_proposal
if [[ $command == scope ]]; then scope_proposal; else apply_proposal; fi
