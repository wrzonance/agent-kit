#!/usr/bin/env bash
# Prepare main for feature work after publishing a stable release.
set -euo pipefail

readonly PROGRAM=${0##*/}

usage() {
    printf 'usage: %s RELEASED_VERSION\n' "$PROGRAM" >&2
    exit 2
}

(( $# == 1 )) || usage
released_version=$1
if [[ ! $released_version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    printf '%s: RELEASED_VERSION must be a stable dotted version (for example 1.2.3): %s\n' \
        "$PROGRAM" "$released_version" >&2
    exit 2
fi
major=${BASH_REMATCH[1]}
minor=${BASH_REMATCH[2]}
patch=${BASH_REMATCH[3]}

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    printf '%s: not inside a Git repository\n' "$PROGRAM" >&2
    exit 1
}
repo_root=$(cd -- "$repo_root" && pwd -P) || exit 1

release_tag="v$released_version"
if ! release_commit=$(git -C "$repo_root" rev-parse --verify --end-of-options \
        "refs/tags/${release_tag}^{commit}" 2>/dev/null); then
    printf '%s: release tag does not exist locally: %s\n' "$PROGRAM" "$release_tag" >&2
    exit 1
fi
head_commit=$(git -C "$repo_root" rev-parse --verify HEAD) || exit 1
if [[ $release_commit != "$head_commit" ]]; then
    printf '%s: release tag %s does not point at HEAD\n' "$PROGRAM" "$release_tag" >&2
    exit 1
fi

checker="$repo_root/tests/check-release-version.sh"
bump="$repo_root/agentkit/skills/.shared/scripts/bump-version.sh"
builder="$repo_root/tests/build-plugin.sh"
for helper in "$checker" "$bump" "$builder"; do
    [[ -x $helper ]] || {
        printf '%s: required helper is missing or not executable: %s\n' \
            "$PROGRAM" "${helper#"$repo_root/"}" >&2
        exit 1
    }
done

# Verify the tag and built artifact before moving the checkout away from the
# published version. The existing bump helper then updates source manifests;
# rebuilding keeps every generated manifest on the same next version.
"$checker" --root "$repo_root" --tag "$release_tag"
next_version="$major.$minor.$((10#$patch + 1))"
(cd -- "$repo_root" && "$bump" "$next_version")
"$builder"
printf 'prepared next unpublished version %s\n' "$next_version"
