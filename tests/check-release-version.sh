#!/usr/bin/env bash
# Verify that every source and built plugin manifest carries the same version.
set -euo pipefail

usage() {
    printf 'Usage: %s [--root ROOT] [--tag TAG]\n' "${0##*/}" >&2
    printf '  --root ROOT  checkout containing agentkit/ and plugin/ (default: repository root)\n' >&2
    printf '  --tag TAG    git tag to compare (default: tag-push context only)\n' >&2
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tag=''
tag_set=0

while (($#)); do
    case $1 in
        --root)
            (($# >= 2)) || { printf '%s: --root requires a value\n' "${0##*/}" >&2; usage; exit 2; }
            root=$2
            shift 2
            ;;
        --tag)
            (($# >= 2)) || { printf '%s: --tag requires a value\n' "${0##*/}" >&2; usage; exit 2; }
            tag=$2
            tag_set=1
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            if (($#)); then
                ((tag_set == 0)) || {
                    printf '%s: only one tag may be supplied\n' "${0##*/}" >&2
                    usage
                    exit 2
                }
                tag=$1
                tag_set=1
                shift
            fi
            ;;
        -*)
            printf '%s: unknown option: %s\n' "${0##*/}" "$1" >&2
            usage
            exit 2
            ;;
        *)
            ((tag_set == 0)) || {
                printf '%s: only one tag may be supplied\n' "${0##*/}" >&2
                usage
                exit 2
            }
            tag=$1
            tag_set=1
            shift
            ;;
    esac
done

root_input=$root
if ! root=$(cd -- "$root" 2>/dev/null && pwd); then
    printf 'release version check failed: root is not a directory: %s\n' "$root_input" >&2
    exit 2
fi

if ((tag_set == 0)) && [[ ${GITHUB_REF_TYPE:-} == tag ]]; then
    tag=${GITHUB_REF_NAME:-}
    tag_set=1
fi
if ((tag_set == 1)) && [[ -z $tag ]]; then
    printf 'release version check failed: tag context has no tag name\n' >&2
    exit 2
fi

manifest_names=(
    'agentkit/.claude-plugin/plugin.json'
    'agentkit/.codex-plugin/plugin.json'
    'plugin/agentkit/.claude-plugin/plugin.json'
    'plugin/agentkit/.codex-plugin/plugin.json'
)
versions=()
failed=0

for i in "${!manifest_names[@]}"; do
    name=${manifest_names[i]}
    manifest=$root/$name
    if [[ ! -f $manifest ]]; then
        printf 'missing manifest: %s\n' "$name" >&2
        failed=1
        continue
    fi
    if ! jq -e . < "$manifest" > /dev/null 2>&1; then
        printf 'invalid manifest JSON: %s\n' "$name" >&2
        failed=1
        continue
    fi
    if ! version=$(jq -er '.version | select(type == "string" and length > 0)' \
        < "$manifest" 2> /dev/null); then
        printf 'manifest has no non-empty string version: %s\n' "$name" >&2
        failed=1
        continue
    fi
    versions[i]=$version
done

if ((failed)); then
    exit 1
fi

expected=${versions[0]}
for i in "${!manifest_names[@]}"; do
    name=${manifest_names[i]}
    version=${versions[i]}
    if [[ $version != "$expected" ]]; then
        printf 'manifest version mismatch: %s declares %s; expected %s\n' \
            "$name" "$version" "$expected" >&2
        failed=1
    fi
done

# OpenCode is a third harness surface, packaged in-tree only (opencode/, plus
# the built plugin/opencode/ once tests/build-plugin.sh has run) -- it is
# checked whenever present rather than added to manifest_names outright, so a
# synthetic fixture that predates OpenCode packaging and never creates an
# opencode/ directory (see test-release-version.sh) keeps working unchanged. A
# real checkout always has opencode/package.json after this change, and CI
# builds the plugin before this script runs, so both files are present and
# fully enforced there; only a hand-built minimal fixture tree skips them.
opencode_checked=0
if [[ -e $root/opencode ]]; then
    opencode_checked=1
    for name in 'opencode/package.json' 'plugin/opencode/package.json'; do
        manifest=$root/$name
        if [[ ! -f $manifest ]]; then
            printf 'missing manifest: %s\n' "$name" >&2
            failed=1
            continue
        fi
        if ! version=$(jq -er '.version | select(type == "string" and length > 0)' \
            < "$manifest" 2> /dev/null); then
            printf 'manifest has no non-empty string version: %s\n' "$name" >&2
            failed=1
            continue
        fi
        if [[ $version != "$expected" ]]; then
            printf 'manifest version mismatch: %s declares %s; expected %s\n' \
                "$name" "$version" "$expected" >&2
            failed=1
        fi
    done
fi

if ((tag_set == 1)); then
    tag_version=${tag#refs/tags/}
    tag_version=${tag_version#v}
    if [[ $tag_version != "$expected" ]]; then
        printf 'tag version mismatch: %s resolves to %s; manifests declare %s\n' \
            "$tag" "$tag_version" "$expected" >&2
        failed=1
    fi
fi

if ((failed)); then
    exit 1
fi

if ((tag_set == 1)); then
    printf 'release version check passed: tag %s matches %s across %d manifests\n' \
        "$tag" "$expected" "${#manifest_names[@]}"
else
    printf 'release version check passed: all %d manifests agree on %s\n' \
        "${#manifest_names[@]}" "$expected"
fi
if ((opencode_checked)); then
    printf 'release version check: opencode manifests agree on %s too\n' "$expected"
fi
