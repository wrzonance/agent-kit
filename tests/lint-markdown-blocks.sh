#!/usr/bin/env bash
# Extract every ```bash fenced block from the SKILL.md files and shellcheck it.
#
# Blocks are fragments: they routinely reference variables established in a
# neighbouring block, so SC2154 is excluded. Every other check stays on, and
# inline `# shellcheck disable=` directives already present in the markdown are
# honored because each block is checked verbatim.
set -euo pipefail

skills_dir=${1:?usage: lint-markdown-blocks.sh SKILLS_DIR}
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

total=0
failed=0

extract() {
    local file=$1 out_dir=$2
    awk -v dir="$out_dir" '
        /^```bash$/ { inblock = 1; n += 1; next }
        /^```$/     { inblock = 0; next }
        inblock     { print > sprintf("%s/block-%03d.sh", dir, n) }
    ' "$file"
}

while IFS= read -r skill_file; do
    name=$(basename "$(dirname "$skill_file")")
    out="$work/$name"
    mkdir -p "$out"
    extract "$skill_file" "$out"
    for block in "$out"/block-*.sh; do
        [[ -e $block ]] || continue
        total=$((total + 1))
        if ! shellcheck -S style -e SC2154 -s bash "$block"; then
            failed=$((failed + 1))
            printf 'FAILED: %s block %s\n' "$skill_file" "$(basename "$block")" >&2
        fi
    done
done < <(find "$skills_dir" -maxdepth 2 -name SKILL.md -not -path '*/.system/*' | sort)

printf 'markdown blocks: %d checked, %d failed\n' "$total" "$failed"
[[ $failed -eq 0 ]]
