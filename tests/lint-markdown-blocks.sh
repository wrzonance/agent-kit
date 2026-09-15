#!/usr/bin/env bash
# Extract every ```bash fenced block from the SKILL.md files -- from every
# references/*.md a skill splits out of its body, and from every .shared/*.md
# policy file both split skills paste into worker prompts -- and shellcheck it.
#
# Blocks are fragments: they routinely reference variables established in a
# neighbouring block, so SC2154 is excluded. Every other check stays on, and
# inline `# shellcheck disable=` directives already present in the markdown are
# honored because each block is checked verbatim. Explicit Bash heredocs are
# also checked as scripts: ShellCheck otherwise treats their bodies as data.
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

# Like the recipe safety scanner, inspect command positions rather than words
# in prose, comments, or printf arguments. This is a bounded builtin check,
# not a claim that every other shell construct is portable.
bash_only_commands() {
    awk '
        # Mask quoted text before splitting commands, so a semicolon in a
        # printed negative example never turns its text into a command.
        function command_text(line, result, j, c) {
            result = ""
            for (j = 1; j <= length(line); j++) {
                c = substr(line, j, 1)
                if (quote != sprintf("%c", 39) && c == "\\") { j++; result = result "Q"; continue }
                if (quote != "") {
                    if (c == quote) quote = ""
                    continue
                }
                if (c == "\"" || c == sprintf("%c", 39)) { quote = c; result = result "Q"; continue }
                if (c == "#" && (j == 1 || substr(line, j - 1, 1) ~ /[[:space:];&|]/)) break
                result = result c
            }
            return result
        }
        {
            count = split(command_text($0), segments, /[;&|]+/)
            for (i = 1; i <= count; i++) {
                segment = segments[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", segment)
                sub(/^(if|then|do|while|until)[[:space:]]+/, "", segment)
                n = split(segment, words, /[[:space:]]+/)
                p = 1
                while (p <= n && words[p] ~ /^[[:alnum:]_]+=/) p++
                while (words[p] ~ /^(!|command|builtin)$/) p++
                command = words[p]
                found = (command == "mapfile" || command == "readarray")
                if (command == "read") {
                    for (p++; p <= n && words[p] !~ /^[<>]/; p++)
                        if (words[p] ~ /^-[[:alpha:]]*a[[:alpha:]]*$/) found = 1
                }
                if (found) print "line " NR ": Bash-only builtin outside explicit Bash boundary: " $0
            }
        }
    ' "$1"
}

boundary_pattern='^bash -c "\$\(cat <<'\''([A-Za-z_][A-Za-z0-9_]*)'\''$'
while IFS= read -r skill_file; do
    rel=${skill_file#"$skills_dir"/}
    out="$work/${rel//\//__}"
    mkdir -p "$out"
    extract "$skill_file" "$out"
    for block in "$out"/block-*.sh; do
        [[ -e $block ]] || continue
        total=$((total + 1))
        first_line=$(head -n 1 "$block")
        if [[ $first_line =~ $boundary_pattern ]] &&
            [[ $(tail -n 2 "$block") == "${BASH_REMATCH[1]}"$'\n'")\"" ]]; then
            # Retain every inner byte, including ShellCheck directives. Check
            # the outer wrapper below as well so malformed quoting stays red.
            sed '1d;$d' "$block" | sed '$d' > "$block.body"
            if ! shellcheck -S style -e SC2154 -s bash "$block.body"; then
                failed=$((failed + 1))
                printf 'FAILED: %s block %s body\n' "$skill_file" "$(basename "$block")" >&2
            fi
        else
            findings=$(bash_only_commands "$block")
            if [[ -n $findings ]]; then
                failed=$((failed + 1))
                printf 'FAILED: %s block %s\n%s\n' "$skill_file" "$(basename "$block")" "$findings" >&2
            fi
        fi
        if ! shellcheck -S style -e SC2154 -s bash "$block"; then
            failed=$((failed + 1))
            printf 'FAILED: %s block %s\n' "$skill_file" "$(basename "$block")" >&2
        fi
    done
done < <(find "$skills_dir" -type f -name '*.md' \
    -not -path '*/.system/*' | sort)

printf 'markdown blocks: %d checked, %d failed\n' "$total" "$failed"
[[ $failed -eq 0 ]]
