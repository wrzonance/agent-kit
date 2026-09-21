#!/usr/bin/env bash
# Verify that manifests agree and a published version still names one shipped tree.
set -euo pipefail

usage() {
    printf 'Usage: %s [--root ROOT] [--tag TAG]\n' "${0##*/}" >&2
    printf '  --root ROOT  checkout containing agentkit/ and plugin/ (default: repository root)\n' >&2
    printf '  --tag TAG    git tag to compare (default: tag context or v<manifest-version>)\n' >&2
}

tree_content_hash() {
    local tree=$1 path relative executable size link_target entries digest
    [[ -d $tree ]] || {
        printf 'release content check failed: shipped tree is missing: %s\n' "$tree" >&2
        return 1
    }

    if ! entries=$(mktemp); then
        printf 'release content check failed: could not create tree enumeration file\n' >&2
        return 1
    fi
    if ! (
        cd -- "$tree" || exit 1
        find . -mindepth 1 -print0 | LC_ALL=C sort -z
    ) > "$entries"; then
        rm -f -- "$entries" || true
        printf 'release content check failed: could not enumerate shipped tree: %s\n' \
            "$tree" >&2
        return 1
    fi

    if ! digest=$(
        (
            cd -- "$tree" || exit 1
            while IFS= read -r -d '' path; do
                relative=${path#./}
                if [[ -L $path ]]; then
                    link_target=$(readlink -- "$path") || exit 1
                    printf 'link\0%s\0%s\0' "$relative" "$link_target" || exit 1
                elif [[ -d $path ]]; then
                    printf 'dir\0%s\0' "$relative" || exit 1
                elif [[ -f $path ]]; then
                    executable=no
                    [[ -x $path ]] && executable=yes
                    size=$(wc -c < "$path") || exit 1
                    size=${size//[[:space:]]/}
                    printf 'file\0%s\0%s\0%s\0' \
                        "$relative" "$executable" "$size" || exit 1
                    command cat -- "$path" || exit 1
                    printf '\0' || exit 1
                else
                    printf 'release content check failed: unsupported entry: %s\n' \
                        "$tree/$relative" >&2
                    exit 1
                fi
            done < "$entries"
        ) | sha256sum | awk '{print $1}'
    ); then
        rm -f -- "$entries" || true
        printf 'release content check failed: could not hash shipped tree: %s\n' "$tree" >&2
        return 1
    fi
    if ! rm -f -- "$entries"; then
        printf 'release content check failed: could not remove tree enumeration file\n' >&2
        return 1
    fi
    printf '%s\n' "$digest"
}

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
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
if ! root=$(cd -- "$root" 2>/dev/null && pwd -P); then
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

if ! git_root=$(git -C "$root" rev-parse --show-toplevel 2> /dev/null) ||
        ! git_root=$(cd -- "$git_root" 2> /dev/null && pwd -P) ||
        [[ $git_root != "$root" ]]; then
    printf 'release content check failed: root is not a Git checkout: %s\n' "$root" >&2
    exit 1
fi

content_tag=$tag
if ((tag_set == 0)); then
    content_tag="v$expected"
fi
content_tag_name=${content_tag#refs/tags/}
content_tag_ref="refs/tags/$content_tag_name"

tag_commit=''
if ! tag_commit=$(git -C "$root" rev-parse --verify --end-of-options \
        "${content_tag}^{commit}" 2> /dev/null); then
    if git -C "$root" remote get-url origin > /dev/null 2>&1; then
        remote_rc=0
        GIT_TERMINAL_PROMPT=0 git -C "$root" ls-remote --exit-code --tags origin \
            "$content_tag_ref" > /dev/null 2>&1 || remote_rc=$?
        case $remote_rc in
            0)
                if ! GIT_TERMINAL_PROMPT=0 git -C "$root" fetch --quiet --no-tags origin \
                        "$content_tag_ref:$content_tag_ref"; then
                    printf 'release content check failed: tag %s exists on origin but could not be fetched\n' \
                        "$content_tag" >&2
                    exit 1
                fi
                if ! tag_commit=$(git -C "$root" rev-parse --verify --end-of-options \
                        "${content_tag}^{commit}" 2> /dev/null); then
                    printf 'release content check failed: fetched tag does not resolve to a commit: %s\n' \
                        "$content_tag" >&2
                    exit 1
                fi
                ;;
            2)
                ;;
            *)
                printf 'release content check failed: could not establish whether tag %s exists on origin; fetch the tag or make origin reachable\n' \
                    "$content_tag" >&2
                exit 1
                ;;
        esac
    fi

    if [[ -z $tag_commit ]]; then
        if ((tag_set == 1)); then
            printf 'release content check failed: tag does not exist locally or on origin: %s\n' \
                "$content_tag" >&2
            exit 1
        fi
        printf 'release content check: no existing tag %s; shipped content is eligible for a new version\n' \
            "$content_tag"
        content_tag=''
    fi
fi

if [[ -n $content_tag ]]; then
    content_tmp=$(mktemp -d)
    trap 'rm -rf -- "$content_tmp"' EXIT
    tagged_checkout=$content_tmp/tagged-checkout
    mkdir -p "$tagged_checkout"

    if ! git -C "$root" archive --format=tar "$tag_commit" |
            tar -xf - -C "$tagged_checkout"; then
        printf 'release content check failed: could not reconstruct tag %s\n' \
            "$content_tag" >&2
        exit 1
    fi
    if [[ ! -x $tagged_checkout/tests/build-plugin.sh ]]; then
        printf 'release content check failed: tag %s has no executable tests/build-plugin.sh\n' \
            "$content_tag" >&2
        exit 1
    fi
    if ! "$tagged_checkout/tests/build-plugin.sh" "$tagged_checkout/plugin" > /dev/null; then
        printf 'release content check failed: tag %s could not rebuild its shipped tree\n' \
            "$content_tag" >&2
        exit 1
    fi

    if ! current_hash=$(tree_content_hash "$root/plugin"); then
        exit 1
    fi
    if ! tagged_hash=$(tree_content_hash "$tagged_checkout/plugin"); then
        exit 1
    fi
    if [[ $current_hash != "$tagged_hash" ]]; then
        printf 'shipped content changed under existing version %s: current hash %s; tag %s content hash %s\n' \
            "$expected" "$current_hash" "$content_tag" "$tagged_hash" >&2
        exit 1
    fi
    printf 'release content check passed: shipped content matches tag %s (content hash %s)\n' \
        "$content_tag" "$current_hash"
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
