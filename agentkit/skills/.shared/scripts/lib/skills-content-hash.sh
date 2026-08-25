#!/usr/bin/env bash
# Content hash over the shipped skill/script tree (issue #453).
#
# Independent of the environment contract's `skills= path=` record: this
# stamps WHAT is on disk, not where. Two trees with identical shipped content
# hash identically regardless of what version string either one claims; two
# trees that differ do not -- so a session (or an operator diffing an
# installed tree against `main`) has something byte-derived to compare
# instead of trusting a version string that can name two different trees.

SKILLS_CONTENT_HASH_LIB_DIR=${BASH_SOURCE[0]%/*}
[[ $SKILLS_CONTENT_HASH_LIB_DIR != "${BASH_SOURCE[0]}" ]] || SKILLS_CONTENT_HASH_LIB_DIR=.
# shellcheck source=contract-cache.sh
source "$SKILLS_CONTENT_HASH_LIB_DIR/contract-cache.sh"

# The exact prune filter tests/build-plugin.sh applies when it packages this
# same tree (vendor + test-shaped paths, at any depth) -- so hashing a source
# checkout and hashing an installed copy that already had those paths
# stripped land on the same stamp for the same shipped content.
skills_content_hash() {
    local dir=$1 files file hash
    [[ -n $dir && -d $dir ]] || return 1
    files=$(
        cd -- "$dir" 2> /dev/null || exit 1
        find . \( -name 'test-*' -o -name fixtures -o -name stub -o -name .agent -o -name .system \) -prune \
            -o -type f -print
    ) || return 1
    files=$(LC_ALL=C sort <<< "$files")
    while IFS= read -r file; do
        [[ -n $file ]] || continue
        hash=$(contract_cache_hash_file "$dir/$file") || return 1
        printf '%s  %s\n' "$hash" "$file"
    done <<< "$files" | contract_cache_hash_stream
}
