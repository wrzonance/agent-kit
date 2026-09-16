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

# Inspect the shell text that the parent harness will execute. Quoted strings,
# comments, parameter-expansion patterns, and heredoc bodies are data at this
# boundary; scanning their words would turn documentation examples into false
# positives. An explicit Bash subprocess owns its quoted command or stdin body.
recipe_portability_findings() {
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        # Preserve byte positions while masking non-executable text. Keeping
        # positions lets heredoc_delimiter read the corresponding raw token.
        function command_text(line, result, j, c, next_c, brace_depth) {
            result = ""
            for (j = 1; j <= length(line); j++) {
                c = substr(line, j, 1)
                next_c = substr(line, j + 1, 1)
                if (quote != sprintf("%c", 39) && c == "\\") {
                    result = result "QQ"
                    j++
                    continue
                }
                if (quote != "") {
                    if (c == quote) quote = ""
                    result = result "Q"
                    continue
                }
                if (c == "\"" || c == sprintf("%c", 39)) {
                    quote = c
                    result = result "Q"
                    continue
                }
                if (c == "#" && (j == 1 || substr(line, j - 1, 1) ~ /[[:space:];&|]/)) break
                if (c == "$" && next_c == "{") {
                    brace_depth = 1
                    result = result "QQ"
                    j++
                    while (j < length(line) && brace_depth) {
                        j++
                        c = substr(line, j, 1)
                        if (c == "{") brace_depth++
                        if (c == "}") brace_depth--
                        result = result "Q"
                    }
                    continue
                }
                if (c == "$" && next_c ~ /[?*#@!$0-9-]/) {
                    result = result "QQ"
                    j++
                    continue
                }
                result = result c
            }
            return result
        }
        function heredoc_delimiter(raw, masked, start, tail, token) {
            start = index(masked, "<<")
            if (!start) return ""
            if (substr(masked, start, 3) == "<<<") return ""
            tail = substr(raw, start + 2)
            sub(/^-[[:space:]]*/, "", tail)
            sub(/^[[:space:]]*/, "", tail)
            token = tail
            sub(/[[:space:];|&].*$/, "", token)
            gsub(/^\047|\047$/, "", token)
            gsub(/^"|"$/, "", token)
            return token
        }
        function report_globs(segment, line, n, words, w, word, glob_at) {
            if (in_test || in_arithmetic || in_case) return
            n = split(segment, words, /[[:space:]]+/)
            for (w = 1; w <= n; w++) {
                word = words[w]
                glob_at = index(word, "*")
                if (!glob_at) glob_at = index(word, "?")
                if (!glob_at && word !~ /\[[^]]+\]/) continue
                # A plain scalar-assignment RHS is not pathname-expanded.
                if (word ~ /^[[:alnum:]_]+=/ && word !~ /\(/) continue
                print "line " NR ": unquoted glob outside explicit Bash boundary: " line
                return
            }
        }
        {
            if (heredoc != "") {
                candidate = $0
                if (heredoc_tabs) sub(/^\t+/, "", candidate)
                if (candidate == heredoc) {
                    heredoc = ""
                    heredoc_tabs = 0
                }
                next
            }
            masked = command_text($0)
            delimiter = heredoc_delimiter($0, masked)
            if (delimiter != "") {
                heredoc = delimiter
                heredoc_tabs = (masked ~ /<<-/)
            }
            count = split(masked, segments, /[;&|]+/)
            for (i = 1; i <= count; i++) {
                segment = trim(segments[i])
                if (segment == "") continue
                if (segment ~ /^case([[:space:]]|$)/) in_case = 1
                if (segment ~ /^\[\[([[:space:]]|$)/) in_test = 1
                if (segment ~ /(^|[^$])\(\(/ || segment ~ /\$\(\(/) in_arithmetic = 1
                test_context = in_test
                report_globs(segment, $0)
                sub(/^(if|then|do|while|until)[[:space:]]+/, "", segment)
                n = split(segment, words, /[[:space:]]+/)
                p = 1
                while (p <= n && words[p] ~ /^[[:alnum:]_]+=/) p++
                while (words[p] ~ /^(!|command|builtin)$/) p++
                command = words[p]
                found = (command == "mapfile" || command == "readarray" || command == "shopt")
                if (command == "read") {
                    for (p++; p <= n && words[p] !~ /^[<>]/; p++)
                        if (words[p] ~ /^-[[:alpha:]]*a[[:alpha:]]*$/) found = 1
                }
                if (command == "declare") {
                    for (p++; p <= n && words[p] !~ /^[<>]/; p++)
                        if (words[p] ~ /^-[[:alpha:]]*A[[:alpha:]]*$/) found = 1
                }
                if (found) print "line " NR ": Bash-only syntax outside explicit Bash boundary: " $0
                if (test_context && segment ~ /(^|[[:space:]])=~([[:space:]]|$)/)
                    print "line " NR ": Bash-only syntax outside explicit Bash boundary: " $0
                if (segment ~ /\]\]([[:space:]]|$)/) in_test = 0
                if (segment ~ /\)\)/) in_arithmetic = 0
                if (segment ~ /(^|[[:space:]])esac([[:space:]]|$)/) in_case = 0
            }
        }
    ' "$1"
}

# A boundary may return data through command substitution and pass literal
# arguments after the heredoc. Never hide subsequent parent-shell commands.
extract_body() {
    local block=$1 delimiter=$2
    : > "$block.body"
    : > "$block.outer"
    awk -v delimiter="$delimiter" -v body="$block.body" -v outer="$block.outer" '
        NR == 1 { next }
        !closed && $0 == delimiter { closed=1; next }
        !closed { print > body; next }
        closed == 1 {
            if ($0 !~ /^\)"/) exit 1
            sub(/^\)"/, "")
            closed=2
        }
        { print > outer }
        END { if (closed != 2) exit 1 }
    ' "$block"
}
boundary_pattern='^([A-Za-z_][A-Za-z0-9_]*=\$\()?bash -c "\$\(cat <<'\''([A-Za-z_][A-Za-z0-9_]*)'\''$'
while IFS= read -r skill_file; do
    rel=${skill_file#"$skills_dir"/}
    out="$work/${rel//\//__}"
    mkdir -p "$out"
    extract "$skill_file" "$out"
    for block in "$out"/block-*.sh; do
        [[ -e $block ]] || continue
        total=$((total + 1))
        scan_block=$block
        first_line=$(head -n 1 "$block")
        if [[ $first_line =~ $boundary_pattern ]] &&
            extract_body "$block" "${BASH_REMATCH[2]}"; then
            # Retain every inner byte, including ShellCheck directives. Check
            # the outer wrapper below as well so malformed quoting stays red.
            scan_block="$block.outer"
            if ! shellcheck -S style -e SC2154 -s bash "$block.body"; then
                failed=$((failed + 1))
                printf 'FAILED: %s block %s body\n' "$skill_file" "$(basename "$block")" >&2
            fi
        fi
        findings=$(recipe_portability_findings "$scan_block")
        if [[ -n $findings ]]; then
            failed=$((failed + 1))
            printf 'FAILED: %s block %s\n%s\n' "$skill_file" "$(basename "$block")" "$findings" >&2
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
