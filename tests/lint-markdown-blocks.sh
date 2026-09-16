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
        function normalize_prefix(value, previous) {
            do {
                previous = value
                sub(/^(if|then|do|while|until|elif|else)[[:space:]]+/, "", value)
                sub(/^![[:space:]]+/, "", value)
            } while (value != previous)
            return trim(value)
        }
        function command_substitution_body(line, start,   j, c, next_c, depth, subquote, body) {
            substitution_end = 0
            depth = 1
            for (j = start + 2; j <= length(line); j++) {
                c = substr(line, j, 1)
                next_c = substr(line, j + 1, 1)
                if (subquote != sprintf("%c", 39) && c == "\\") {
                    body = body c next_c
                    j++
                    continue
                }
                if (subquote != "") {
                    body = body c
                    if (c == subquote) subquote = ""
                    continue
                }
                if (c == "\"" || c == sprintf("%c", 39)) {
                    subquote = c
                    body = body c
                    continue
                }
                if (c == "$" && next_c == "(") {
                    depth++
                    body = body "$("
                    j++
                    continue
                }
                if (c == ")") {
                    depth--
                    if (!depth) {
                        substitution_end = j
                        return body
                    }
                }
                body = body c
            }
            return ""
        }
        # Preserve byte positions while masking non-executable text. Keeping
        # positions lets heredoc_delimiter read the corresponding raw token.
        function command_text(line, result, j, c, next_c, brace_depth, body, end, outer_quote, executable, tail, k) {
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
                    if (quote == "\"" && c == "$" && next_c == "(" &&
                        substr(line, j + 2, 1) != "(") {
                        body = command_substitution_body(line, j)
                        end = substitution_end
                        if (end) {
                            outer_quote = quote
                            quote = ""
                            executable = command_text(body)
                            quote = outer_quote
                            for (k = j; k <= end; k++) result = result "Q"
                            tail = tail "; " executable " ; "
                            j = end
                            continue
                        }
                    }
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
            return result tail
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
            if (in_test || in_arithmetic) return
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
        function split_commands(text, parts, separators,   n, j, c, next_c, remainder, close_at, terminator_at, pattern_pipe, buffer, operators, is_operator) {
            n = 0
            for (j = 1; j <= length(text); j++) {
                c = substr(text, j, 1)
                next_c = substr(text, j + 1, 1)
                pattern_pipe = 0
                if (c == "|") {
                    remainder = substr(text, j + 1)
                    close_at = index(remainder, ")")
                    terminator_at = index(remainder, ";")
                    pattern_pipe = (close_at && (!terminator_at || close_at < terminator_at))
                }
                is_operator = (c == ";" || c == "&" || (c == "|" && !pattern_pipe))
                if (is_operator) {
                    if (buffer != "") {
                        n++
                        parts[n] = buffer
                        separators[n] = ""
                        buffer = ""
                    }
                    operators = operators c
                    continue
                }
                if (operators != "") {
                    separators[n] = operators
                    operators = ""
                }
                buffer = buffer c
            }
            if (buffer != "") {
                n++
                parts[n] = buffer
                separators[n] = ""
            }
            if (operators != "") separators[n] = operators
            return n
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
            if (in_case && trim(masked) ~ /^(;;|;&|;;&)$/) {
                case_arm_body = 0
                next
            }
            count = split_commands(masked, segments, separators)
            for (i = 1; i <= count; i++) {
                segment = trim(segments[i])
                if (segment == "") continue
                context = normalize_prefix(segment)
                if (context ~ /^case([[:space:]]|$)/) {
                    in_case = 1
                    case_arm_body = 0
                    sub(/^case[[:space:]]+.*[[:space:]]in([[:space:]]|$)/, "", context)
                    context = trim(context)
                }
                if (in_case && context ~ /^esac([[:space:]]|$)/) {
                    in_case = 0
                    case_arm_body = 0
                    continue
                }
                if (in_case && !case_arm_body) {
                    close_at = index(context, ")")
                    if (!close_at) {
                        if (separators[i] ~ /;;|;&/) case_arm_body = 0
                        continue
                    }
                    context = trim(substr(context, close_at + 1))
                    case_arm_body = 1
                }
                if (context == "") {
                    if (separators[i] ~ /;;|;&/) case_arm_body = 0
                    continue
                }
                if (context ~ /^\[\[([[:space:]]|$)/) in_test = 1
                if (context ~ /(^|[^$])\(\(/ || context ~ /\$\(\(/) in_arithmetic = 1
                test_context = in_test
                report_globs(context, $0)
                n = split(context, words, /[[:space:]]+/)
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
                if (test_context && context ~ /(^|[[:space:]])=~([[:space:]]|$)/)
                    print "line " NR ": Bash-only syntax outside explicit Bash boundary: " $0
                if (context ~ /\]\]([[:space:]]|$)/) in_test = 0
                if (context ~ /\)\)/) in_arithmetic = 0
                if (separators[i] ~ /;;|;&/) case_arm_body = 0
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
