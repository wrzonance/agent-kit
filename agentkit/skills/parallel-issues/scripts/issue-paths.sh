#!/usr/bin/env bash
# Derive literal repository paths named by an issue body.
set -euo pipefail

readonly PROGRAM=${0##*/}
issue=''
repo_root=''
body_file=''

die() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
usage() {
    printf 'usage: %s --issue N [--repo-root DIR] [--body-file FILE|-]\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --issue) (($# >= 2)) || usage; issue=$2; shift 2 ;;
        --repo-root) (($# >= 2)) || usage; repo_root=$2; shift 2 ;;
        --body-file) (($# >= 2)) || usage; body_file=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        --) shift; (($# == 0)) || usage; break ;;
        *) usage ;;
    esac
done

[[ $issue =~ ^[1-9][0-9]*$ ]] || usage
for tool in git jq; do command -v "$tool" >/dev/null 2>&1 || die "$tool is required"; done
[[ -n $repo_root ]] || repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'no repository root'
repo_root=$(cd -P -- "$repo_root" 2>/dev/null && pwd -P) || die 'repository root is not a directory'
top=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null) || die 'repository root is not a git worktree'
top=$(cd -P -- "$top" && pwd -P) || die 'could not resolve repository root'
[[ $repo_root == "$top" ]] || die 'repository root must name the worktree root'
git -C "$repo_root" rev-parse --verify 'HEAD^{tree}' >/dev/null 2>&1 || die 'repository HEAD has no tree'

if [[ -n $body_file ]]; then
    if [[ $body_file == - ]]; then
        body=$(cat)
    else
        [[ -f $body_file && ! -L $body_file ]] || die 'body file must be a regular file, not a symlink'
        body=$(cat -- "$body_file")
    fi
else
    command -v gh >/dev/null 2>&1 || die 'gh is required to fetch the issue body'
    issue_json=$(cd -- "$repo_root" && gh issue view "$issue" --json body 2>/dev/null) ||
        die "could not read issue #$issue"
    body=$(jq -er '.body | strings' <<<"$issue_json") || die "issue #$issue has no body"
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
protected_lib=$script_dir/../../.shared/scripts/lib/protected-paths.sh
[[ -f $protected_lib && ! -L $protected_lib ]] || die 'protected-path policy is unavailable'
# shellcheck source=../../.shared/scripts/lib/protected-paths.sh
source "$protected_lib"
declared_protected=''
config_reader=$script_dir/../../.shared/scripts/repo-config.sh
if [[ -x $config_reader ]]; then
    declared_protected=$("$config_reader" --repo-root "$repo_root" --get AGENT_PROTECTED_PATHS 2>/dev/null || true)
fi

tree_listing=$(mktemp) || die 'could not create repository tree buffer'
trap 'rm -f -- "$tree_listing"' EXIT HUP INT TERM
git -C "$repo_root" ls-tree -rz 'HEAD^{tree}' >"$tree_listing" ||
    die 'could not list repository tree'

declare -A modes=() directories=() symlinks=()
while IFS= read -r -d '' record; do
    [[ $record == *$'\t'* ]] || die 'repository tree returned malformed evidence'
    metadata=${record%%$'\t'*}
    path=${record#*$'\t'}
    mode=${metadata%% *}
    modes["$path"]=$mode
    [[ $mode != 120000 ]] || symlinks["$path"]=1
    parent=$path
    while [[ $parent == */* ]]; do
        parent=${parent%/*}
        directories["$parent"]=1
    done
done <"$tree_listing"

candidate_is_safe() {
    local candidate=$1 segment prefix=''
    [[ $candidate =~ ^[A-Za-z0-9._@+-]+(/[A-Za-z0-9._@+-]+)*$ ]] || return 1
    [[ $candidate != -* ]] || return 1
    [[ $candidate != . && $candidate != .. ]] || return 1
    IFS=/ read -ra segments <<<"$candidate"
    for segment in "${segments[@]}"; do
        [[ $segment != . && $segment != .. ]] || return 1
        prefix=${prefix:+$prefix/}$segment
        [[ -z ${symlinks[$prefix]+yes} ]] || return 1
    done
    ! shared_protected_pattern "$candidate" '' "$declared_protected" 0 >/dev/null
}

classify() {
    local candidate=${1#./} parent
    candidate=${candidate%/}
    candidate_is_safe "$candidate" || return 0
    if [[ -n ${modes[$candidate]+yes} || -n ${directories[$candidate]+yes} ]]; then
        printf 'exists %s\n' "$candidate"
        return 0
    fi
    [[ $candidate == */* ]] || return 0
    parent=${candidate%/*}
    if [[ -n ${directories[$parent]+yes} ]]; then
        printf 'create %s\n' "$candidate"
    fi
    return 0
}

while IFS= read -r candidate; do
    classify "$candidate"
done < <(jq -Rrs -r '
  ([scan("`([^`\\r\\n]+)`") | .[0]]
   + [scan("/?[A-Za-z0-9_.@+-]+(?:/[A-Za-z0-9_.@+-]*[A-Za-z0-9_@+-])+")]
   + [scan("[A-Za-z0-9_@+-]+(?:\\.[A-Za-z0-9_@+-]+)+")])[]
' <<<"$body") | sort -u
