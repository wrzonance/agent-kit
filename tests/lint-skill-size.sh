#!/usr/bin/env bash
# Every SKILL.md pays its own way in context: this gate bounds body size,
# requires a trigger-only frontmatter description, and (forward-looking, since
# no skill has one yet) keeps references/ flat and navigable.
#
# .shared/*.md is out of scope -- it has no SKILL.md, so the discovery glob
# below never reaches it.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-size.sh SKILLS_DIR}

# A skill already over budget stays green here only by an explicit, named
# entry below, in the form LINES:TOKENS:TARGET. LINES and TOKENS are that
# skill's body-line and estimated-token counts as of the entry being written
# -- hard caps in BOTH dimensions, because the budget this gate defends is
# context, and a body can grow by hundreds of kilobytes without adding a
# single line. TARGET is the line count to eventually work back down to,
# tracked in the named issue. Remove the entry the moment the skill is back
# under the standard budget -- see the ratchet check further down. If a
# deliberate change legitimately grows an allowlisted skill, raise the
# ceiling it crosses in the same PR so this stays a conscious ratchet, not a
# rubber stamp.
declare -A KNOWN_OVERSIZE=(
    # LINES:TOKENS:TARGET
    [review-remote-pr]="2087:34808:450"  # target <=450 lines, tracked in issue #106
    [parallel-issues]="1783:29014:450"   # target <=450 lines, tracked in issue #107
    [onboard-repo]="464:5476:350"        # target <=350 lines, tracked in issue #108
)

readonly MAX_BODY_LINES=500
readonly MAX_BODY_TOKENS=5000
readonly MAX_DESC_CHARS=500
readonly MAX_REF_LINES_WITHOUT_TOC=100
readonly TOC_SCAN_WINDOW=30

violations=0
checked=0

report() {
    printf 'VIOLATION %s: %s\n' "$1" "$2" >&2
    violations=$((violations + 1))
}

# Prints the line number of the frontmatter's closing `---`, or nothing if the
# file has no frontmatter block. The opening delimiter must be line 1: without
# that anchor, any later pair of `---` rules in the body impersonates a
# frontmatter block, so a SKILL.md with no frontmatter at all passes every
# check below (its "description" being whatever sat between two horizontal
# rules). Deliberately reports nothing itself -- callers run this via command
# substitution, and a subshell's report() can't bump the parent's violation
# counter, so the caller must check for emptiness and call report() itself in
# the parent shell.
frontmatter_end() {
    awk '
        NR == 1 && !/^---[[:space:]]*$/ { exit }
        /^---[[:space:]]*$/ { c++; if (c == 2) { print NR; exit } }
    ' "$1"
}

# Prints "LINES BYTES" for the body -- everything after the frontmatter's
# closing `---` at line $2.
body_stats() {
    local file=$1 fm_end=$2
    local total_lines body_lines body_bytes
    total_lines=$(wc -l < "$file")
    body_lines=$((total_lines - fm_end))
    body_bytes=$(tail -n "+$((fm_end + 1))" "$file" | wc -c)
    printf '%s %s\n' "$body_lines" "$body_bytes"
}

check_size() {
    local file=$1 name=$2 body_lines=$3 body_bytes=$4
    local est_tokens=$((body_bytes / 4))
    local over=0
    if ((body_lines > MAX_BODY_LINES || est_tokens > MAX_BODY_TOKENS)); then
        over=1
    fi

    if [[ -v KNOWN_OVERSIZE[$name] ]]; then
        local entry=${KNOWN_OVERSIZE[$name]} line_ceiling token_ceiling target
        IFS=: read -r line_ceiling token_ceiling target <<< "$entry"
        # An entry missing a field would otherwise reach the arithmetic below
        # as an empty operand -- a bash syntax error that aborts the whole
        # lint instead of naming the malformed line.
        if [[ -z $line_ceiling || -z $token_ceiling || -z $target ]]; then
            report "$file" \
                "malformed KNOWN_OVERSIZE entry for '$name' ('$entry') -- expected LINES:TOKENS:TARGET"
            return 0
        fi
        if ((over == 0)); then
            report "$file" \
                "allowlisted skill '$name' is now within budget ($body_lines lines, ~$est_tokens tokens) -- remove the stale KNOWN_OVERSIZE entry (target <=$target lines)"
            return 0
        fi
        # Both dimensions ratchet: a skill that trades lines for longer lines
        # is still growing the context it costs.
        if ((body_lines > line_ceiling)); then
            report "$file" \
                "allowlisted skill '$name' grew to $body_lines lines, past its ratcheted ceiling of $line_ceiling lines -- the allowlist tracks a skill shrinking toward its target (<=$target lines), never growing; either shrink it back or, for a deliberate change, raise LINES in this file's KNOWN_OVERSIZE entry in the same PR"
        fi
        if ((est_tokens > token_ceiling)); then
            report "$file" \
                "allowlisted skill '$name' grew to ~$est_tokens estimated tokens, past its ratcheted ceiling of $token_ceiling tokens -- either shrink it back or, for a deliberate change, raise TOKENS in this file's KNOWN_OVERSIZE entry in the same PR"
        fi
        return 0
    fi

    if ((over)); then
        report "$file" \
            "body is $body_lines lines / ~$est_tokens estimated tokens (budget: $MAX_BODY_LINES lines, $MAX_BODY_TOKENS tokens)"
    fi
    return 0
}

# Prints the joined frontmatter description text (possibly empty).
extract_description() {
    local file=$1
    awk '
        BEGIN { in_fm = 0; found = 0; folding = 0; desc = "" }
        /^---[[:space:]]*$/ { in_fm++; if (in_fm == 2) exit; next }
        in_fm != 1 { next }
        !found && /^description:[[:space:]]*/ {
            found = 1
            line = $0
            sub(/^description:[[:space:]]*/, "", line)
            if (line ~ /^[>|][-+]?[[:space:]]*$/) { folding = 1 } else { desc = line }
            next
        }
        found && folding {
            # A blank line inside a block scalar is a paragraph break, not the
            # end of the value -- YAML keeps folding afterwards. Ending here
            # would leave everything past the blank line uncounted, which is a
            # free way to smuggle an over-long description past the limit.
            if ($0 ~ /^[[:space:]]*$/) { next }
            if ($0 ~ /^[[:space:]]+/) {
                val = $0
                sub(/^[[:space:]]+/, "", val)
                desc = (desc == "" ? val : desc " " val)
            } else {
                folding = 0
            }
            next
        }
        END { print desc }
    ' "$file"
}

# YAML lets a trailing `#` comment follow a scalar, and the comment is not part
# of the value. Scoring it as part of the description rejects legal frontmatter
# -- `description: "Use when ..." # note` was reported as not starting with
# "Use when", which is both a false failure and a misleading message.
# Deliberately simple: a quoted scalar ends at its first matching quote (a
# description has no use for escaped quotes), and a plain scalar ends at the
# first ` #', which is exactly where YAML ends it too.
strip_inline_comment() {
    local value=$1 quote=${1:0:1} rest
    if [[ $quote == '"' || $quote == "'" ]]; then
        rest=${value:1}
        if [[ $rest == *"$quote"* ]]; then
            printf '%s%s%s\n' "$quote" "${rest%%"$quote"*}" "$quote"
            return 0
        fi
    fi
    if [[ $value == *' #'* ]]; then
        value=${value%%' #'*}
    fi
    printf '%s\n' "$value"
}

check_description() {
    local file=$1 desc
    desc=$(extract_description "$file")
    desc=$(strip_inline_comment "$desc")
    if [[ -z $desc ]]; then
        report "$file" "frontmatter description is empty or missing"
        return 0
    fi
    # YAML allows (but doesn't require) quoting a scalar value; strip one
    # matching pair of leading/trailing quotes so a legally-quoted
    # `description: "Use when ..."` isn't scored on its quote characters.
    local first=${desc:0:1} last=${desc: -1}
    if ((${#desc} >= 2)) && [[ ($first == '"' && $last == '"') || ($first == "'" && $last == "'") ]]; then
        desc=${desc:1:-1}
    fi
    if ((${#desc} > MAX_DESC_CHARS)); then
        report "$file" "frontmatter description is ${#desc} characters (max $MAX_DESC_CHARS)"
    fi
    if [[ $desc != "Use when"* ]]; then
        report "$file" "frontmatter description must begin with \"Use when\": ${desc:0:60}..."
    fi
    return 0
}

check_references() {
    local skill_dir=$1 refs_dir=$1/references
    [[ -d $refs_dir ]] || return 0

    local sub
    while IFS= read -r sub; do
        report "$sub" "subdirectory not allowed under references/ (files must sit directly in it)"
    done < <(find "$refs_dir" -mindepth 1 -maxdepth 1 -type d)

    local doc lines has_toc
    while IFS= read -r doc; do
        lines=$(wc -l < "$doc")
        ((lines > MAX_REF_LINES_WITHOUT_TOC)) || continue
        has_toc=$(head -n "$TOC_SCAN_WINDOW" "$doc" |
            grep -ciE '^(## Contents|## Table of contents)' || true)
        if ((has_toc == 0)); then
            report "$doc" \
                "$lines lines with no '## Contents' / '## Table of contents' marker in the first $TOC_SCAN_WINDOW lines"
        fi
    done < <(find "$refs_dir" -maxdepth 1 -name '*.md')
    return 0
}

while IFS= read -r skill_file; do
    checked=$((checked + 1))
    skill_dir=$(dirname "$skill_file")
    name=$(basename "$skill_dir")

    fm_end=$(frontmatter_end "$skill_file")
    if [[ -z $fm_end ]]; then
        report "$skill_file" \
            "no YAML frontmatter block -- it must open with --- on line 1 and close with a later ---"
        continue
    fi

    stats=$(body_stats "$skill_file" "$fm_end")
    read -r body_lines body_bytes <<< "$stats"
    check_size "$skill_file" "$name" "$body_lines" "$body_bytes"

    check_description "$skill_file"
    check_references "$skill_dir"
done < <(find "$skills_dir" -maxdepth 2 -name SKILL.md -not -path '*/.system/*' | sort)

printf 'skill size: %d skills checked, %d violations\n' "$checked" "$violations"
if ((checked == 0)); then
    printf 'VIOLATION %s: no SKILL.md files found -- lint ran against nothing\n' "$skills_dir" >&2
    violations=$((violations + 1))
fi
[[ $violations -eq 0 ]]
