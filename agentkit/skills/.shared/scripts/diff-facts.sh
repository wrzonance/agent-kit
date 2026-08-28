#!/usr/bin/env bash
# Report changed-line facts split into operational and generated categories.
# This helper reports evidence only; it never decides whether a diff is large,
# small, trivial, or ready to merge.
set -euo pipefail

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 ]]; then
    printf '%s: requires Bash >= 4 (invoked interpreter: %s); run this helper with bash, not zsh\n' \
        "${0##*/}" "${SHELL:-unknown}" >&2
    exit 3
fi

readonly PROGRAM=${0##*/}

usage() {
    printf 'usage: %s [--worktree DIR|--repo-root DIR] [--base REF]\n' "$PROGRAM" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

repo_root=''
base=''
while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --worktree | --repo-root)
            (($# >= 2)) || usage
            repo_root=$2
            shift 2
            ;;
        --base)
            (($# >= 2)) || usage
            base=$2
            shift 2
            ;;
        -h | --help)
            usage
            ;;
        *)
            usage
            ;;
    esac
done

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null) || die 'not inside a Git worktree'
fi
repo_root=$(cd -- "$repo_root" 2> /dev/null && pwd -P) || die "repository root is not readable: $repo_root"

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
resolver="$script_dir/repo-config.sh"
[[ -x $resolver ]] || die "repo-config.sh is missing or not executable: $resolver"

if [[ -z $base ]]; then
    base=$("$resolver" --repo-root "$repo_root" --get AGENT_BASE_BRANCH 2> /dev/null || true)
fi
if [[ -z $base ]]; then
    remote_head=$(git -C "$repo_root" symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)
    base=${remote_head#origin/}
fi
[[ -n $base ]] || die 'no base ref; pass --base REF or declare AGENT_BASE_BRANCH'
git -C "$repo_root" rev-parse --verify --end-of-options "$base^{commit}" > /dev/null 2>&1 ||
    die "base ref does not resolve to a commit: $base"
merge_base=$(git -C "$repo_root" merge-base -- "$base" HEAD 2> /dev/null) ||
    die "could not resolve merge base for base ref: $base"

generated_paths=$("$resolver" --repo-root "$repo_root" --get AGENT_GENERATED_PATHS 2> /dev/null || true)

declare -a categories=(operational generated lockfile fixture non_operational)
declare -A file_counts=() insertions=() deletions=() changed_lines=()
for category in "${categories[@]}"; do
    file_counts[$category]=0
    insertions[$category]=0
    deletions[$category]=0
    changed_lines[$category]=0
done

matches_generated() {
    local path=$1 spec
    local -a paths=()
    [[ -n $generated_paths ]] || return 1
    IFS=, read -ra paths <<< "$generated_paths"
    for spec in "${paths[@]}"; do
        # An element that is empty BEFORE normalization is a stray comma, not a
        # declaration -- skip it. Without this, the empty-spec branch below would
        # let a trailing comma silently mark the entire repository generated.
        [[ -n $spec ]] || continue
        while [[ $spec == ./* ]]; do spec=${spec#./}; done
        while [[ $spec == */ ]]; do spec=${spec%/}; done
        # A spec naming the repository root normalizes to empty here. './' and
        # '.' denote the same directory, so they must classify the same way --
        # previously './' matched nothing while '.' matched everything.
        [[ -z $spec || $spec == . || $path == "$spec" || $path == "$spec/"* ]] && return 0
    done
    return 1
}

is_lockfile() {
    local name=${1##*/}
    local package_lock='package-lock.json' npm_shrinkwrap='npm-shrinkwrap.json'
    local yarn_lock='yarn.lock' pnpm_lock='pnpm-lock.yaml' bun_lock='bun.lock' # ecosystem-allow: lockfile names are classification data, not commands
    local bun_lock_binary='bun.lockb' cargo_lock='Cargo.lock' gemfile_lock='Gemfile.lock'
    local poetry_lock='poetry.lock' pipfile_lock='Pipfile.lock' composer_lock='composer.lock'
    local go_sum='go.sum' packages_lock='packages.lock.json' project_assets='project.assets.json'
    case $name in
        "$package_lock" | "$npm_shrinkwrap" | "$yarn_lock" | "$pnpm_lock" \
        | "$bun_lock" | "$bun_lock_binary" | "$cargo_lock" | "$gemfile_lock" \
        | "$poetry_lock" | "$pipfile_lock" | "$composer_lock" | "$go_sum" \
        | "$packages_lock" | "$project_assets" | *.lock | *.lock.json | *.lock.yaml)
            return 0
            ;;
    esac
    return 1
}

is_fixture() {
    local path=$1 name=${1##*/}
    case "/$path/" in
        */fixtures/* | */fixture/* | */testdata/* | */__snapshots__/*) return 0 ;;
    esac
    case $name in
        *.fixture | *.fixture.* | *.snap | *.golden) return 0 ;;
    esac
    return 1
}

category_for() {
    local path=$1
    if matches_generated "$path"; then
        printf '%s\n' generated
    elif is_lockfile "$path"; then
        printf '%s\n' lockfile
    elif is_fixture "$path"; then
        printf '%s\n' fixture
    else
        printf '%s\n' operational
    fi
}

to_count() {
    [[ $1 =~ ^[0-9]+$ ]] && printf '%s\n' "$1" || printf '0\n'
}

while IFS= read -r -d '' record; do
    added=${record%%$'\t'*}
    rest=${record#*$'\t'}
    [[ $rest == *$'\t'* ]] || die 'unexpected numstat record'
    removed=${rest%%$'\t'*}
    path=${rest#*$'\t'}
    [[ -n $path ]] || die 'numstat record has an empty path'
    added=$(to_count "$added")
    removed=$(to_count "$removed")
    category=$(category_for "$path")
    file_counts[$category]=$((file_counts[$category] + 1))
    insertions[$category]=$((insertions[$category] + added))
    deletions[$category]=$((deletions[$category] + removed))
    changed_lines[$category]=$((changed_lines[$category] + added + removed))
done < <(git -C "$repo_root" diff --numstat --no-renames -z "$merge_base" --)

file_counts[non_operational]=$((file_counts[generated] + file_counts[lockfile] + file_counts[fixture]))
insertions[non_operational]=$((insertions[generated] + insertions[lockfile] + insertions[fixture]))
deletions[non_operational]=$((deletions[generated] + deletions[lockfile] + deletions[fixture]))
changed_lines[non_operational]=$((changed_lines[generated] + changed_lines[lockfile] + changed_lines[fixture]))

printf 'base=%s\n' "$base"
printf 'files=%d\n' "$((file_counts[operational] + file_counts[non_operational]))"
printf 'total.insertions=%d\n' "$((insertions[operational] + insertions[non_operational]))"
printf 'total.deletions=%d\n' "$((deletions[operational] + deletions[non_operational]))"
printf 'total.lines=%d\n' "$((changed_lines[operational] + changed_lines[non_operational]))"
for category in operational generated lockfile fixture non_operational; do
    printf '%s.files=%d\n' "$category" "${file_counts[$category]}"
    printf '%s.insertions=%d\n' "$category" "${insertions[$category]}"
    printf '%s.deletions=%d\n' "$category" "${deletions[$category]}"
    printf '%s.lines=%d\n' "$category" "${changed_lines[$category]}"
done
