#!/usr/bin/env bash
# Update the three source manifests for a release without traversing linked
# worktrees. This helper is intentionally root-relative and fixed-scope.
set -euo pipefail

readonly PROGRAM=${0##*/}

usage() {
    printf 'usage: %s VERSION\n' "$PROGRAM" >&2
    exit 2
}

(( $# == 1 )) || usage
version=$1
[[ $version =~ ^[0-9]+(\.[0-9]+){2}([.-][0-9A-Za-z.-]+)?$ ]] || {
    printf '%s: VERSION must be a dotted release version (for example 0.7.3): %s\n' \
        "$PROGRAM" "$version" >&2
    exit 2
}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf '%s: not inside a Git repository\n' "$PROGRAM" >&2
    exit 1
}
repo_root=$(cd -- "$repo_root" && pwd -P) || exit 1

# A linked worktree can be created anywhere, not only below the conventional
# .worktrees/ directory. In the primary checkout Git's per-worktree and common
# metadata directories resolve to the same path; linked worktrees keep their
# own metadata below the shared common directory.
git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
    printf '%s: could not resolve Git metadata directory\n' "$PROGRAM" >&2
    exit 1
}
common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || {
    printf '%s: could not resolve Git common directory\n' "$PROGRAM" >&2
    exit 1
}
git_dir=$(cd -- "$git_dir" && pwd -P) || exit 1
common_dir=$(cd -- "$common_dir" && pwd -P) || exit 1
if [[ $git_dir != "$common_dir" ]]; then
    printf '%s: refusing to run inside a linked worktree; invoke it from the primary repository checkout\n' \
        "$PROGRAM" >&2
    exit 1
fi

current_dir=$(pwd -P)
case "$current_dir" in
    "$repo_root/.worktrees"|"$repo_root/.worktrees"/*)
        printf '%s: refusing to run inside .worktrees; invoke it from the repository root\n' \
            "$PROGRAM" >&2
        exit 1
        ;;
esac

readonly manifest_names=(
    'agentkit/.claude-plugin/plugin.json'
    'agentkit/.codex-plugin/plugin.json'
    'opencode/package.json'
)

command -v jq >/dev/null 2>&1 || {
    printf '%s: jq is required to update manifests safely\n' "$PROGRAM" >&2
    exit 1
}

tmp_dir=$(mktemp -d "$repo_root/.bump-version.XXXXXX") || {
    printf '%s: could not create a private staging directory\n' "$PROGRAM" >&2
    exit 1
}
cleanup() { rm -rf -- "$tmp_dir"; }
trap cleanup EXIT

for name in "${manifest_names[@]}"; do
    manifest=$repo_root/$name
    [[ -f $manifest && ! -L $manifest ]] || {
        printf '%s: missing or symlinked manifest: %s\n' "$PROGRAM" "$name" >&2
        exit 1
    }
    jq -e . < "$manifest" >/dev/null 2>&1 || {
        printf '%s: invalid manifest JSON: %s\n' "$PROGRAM" "$name" >&2
        exit 1
    }
    jq --arg version "$version" '.version = $version' "$manifest" > "$tmp_dir/${name//\//__}" || {
        printf '%s: could not render manifest: %s\n' "$PROGRAM" "$name" >&2
        exit 1
    }
done

for name in "${manifest_names[@]}"; do
    mv -- "$tmp_dir/${name//\//__}" "$repo_root/$name"
done

printf 'bumped version to %s (%d files)\n' "$version" "${#manifest_names[@]}"
