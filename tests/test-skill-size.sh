#!/usr/bin/env bash
# Suite: SKILL.md context-budget gate.
#
# Each case gets its own root so the lint's discovery glob sees exactly one
# skill: a shared root would let an unrelated fixture's violation satisfy an
# assertion about this one.
set -uo pipefail

TEST_NAME='skill size'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lint="$here/lint-skill-size.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

LINT_RC=0
LINT_OUT=''

# make_skill ROOT NAME  -- SKILL.md content on stdin
make_skill() {
    local root=$1 name=$2
    mkdir -p "$root/$name"
    cat > "$root/$name/SKILL.md"
}

run_lint() {
    LINT_RC=0
    LINT_OUT=$("${2:-$lint}" "$1" 2>&1) || LINT_RC=$?
}

repeat_lines() {
    local count=$1 i
    for ((i = 0; i < count; i++)); do printf 'body line %d\n' "$i"; done
}

wide_line() {
    head -c "$1" /dev/zero | tr '\0' x
    printf '\n'
}

# --- the happy path -----------------------------------------------------
root=$tmp/compliant
make_skill "$root" tidy <<'EOF'
---
name: tidy
description: Use when the skill is small and its frontmatter is well formed.
---
A short body that costs almost nothing to load.
EOF
run_lint "$root"
assert_eq '0' "$LINT_RC" 'a compliant skill passes'

# --- body budget --------------------------------------------------------
root=$tmp/oversize
mkdir -p "$root/fat"
{
    printf -- '---\nname: fat\ndescription: Use when the body is over budget.\n---\n'
    repeat_lines 600
} > "$root/fat/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an over-budget body fails'
assert_contains "$LINT_OUT" 'budget: 500 lines' 'the body violation names the budget'

# --- description rules --------------------------------------------------
root=$tmp/nodesc
make_skill "$root" bare <<'EOF'
---
name: bare
---
Body.
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a missing description fails'
assert_contains "$LINT_OUT" 'description is empty or missing' 'the missing description is named'

root=$tmp/notrigger
make_skill "$root" prose <<'EOF'
---
name: prose
description: Reviews pull requests and does other things.
---
Body.
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a description not starting with "Use when" fails'

# A folded scalar containing a blank line: YAML treats the blank as a
# paragraph break and keeps folding, so everything after it counts toward the
# limit. Stopping at the blank line made an unbounded description free.
root=$tmp/folded-blank
mkdir -p "$root/folded"
{
    printf -- '---\nname: folded\ndescription: >-\n'
    printf '  Use when a folded description hides its length behind a blank line.\n'
    printf '\n'
    printf '  '
    wide_line 600
    printf -- '---\nBody.\n'
} > "$root/folded/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a folded description keeps counting past a blank line'
assert_contains "$LINT_OUT" 'characters (max 500)' 'the over-long folded description is measured'

# A trailing YAML comment is not part of the scalar. Scoring it rejected legal
# frontmatter and reported it as not starting with "Use when".
root=$tmp/commented
make_skill "$root" commented <<'EOF'
---
name: commented
description: "Use when a quoted description carries a trailing comment." # trigger note
---
Body.
EOF
run_lint "$root"
assert_eq '0' "$LINT_RC" 'a quoted description with an inline comment passes'

# Interior quotes must not be mistaken for the end of the scalar. Cutting at
# the first one truncated a 600-character description to a handful, so it
# measured short and sailed past the limit.
# Each paragraph break folds to one newline character in the YAML value, so it
# counts as one character rather than nothing.
root=$tmp/folded-breaks
mkdir -p "$root/breaks"
{
    printf -- '---\nname: breaks\ndescription: >-\n'
    printf '  Use when the length is carried by paragraph breaks.\n'
    for _ in $(seq 1 520); do printf '\n'; done
    printf '  End.\n---\nBody.\n'
} > "$root/breaks/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'paragraph breaks in a folded description count toward the limit'

root=$tmp/escaped-quote
mkdir -p "$root/escaped"
{
    printf -- '---\nname: escaped\ndescription: "Use when a value has an escaped quote: \\"q\\" '
    wide_line 600 | tr -d '\n'
    printf '"\n---\nBody.\n'
} > "$root/escaped/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an over-long description with escaped double quotes is measured in full'
assert_contains "$LINT_OUT" 'characters (max 500)' 'the escaped-quote description is measured, not truncated'

root=$tmp/doubled-quote
mkdir -p "$root/doubled"
{
    printf -- "---\nname: doubled\ndescription: 'Use when it''s doubled-single-quoted "
    wide_line 600 | tr -d '\n'
    printf "'\n---\nBody.\n"
} > "$root/doubled/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an over-long description with doubled single quotes is measured in full'

# --- frontmatter must actually be frontmatter ---------------------------
# Without anchoring the opening delimiter to line 1, any later pair of ---
# rules impersonates a frontmatter block, and a file with none at all passes
# every check with a body-derived "description".
root=$tmp/nofrontmatter
make_skill "$root" impostor <<'EOF'
This file has no frontmatter.

---
description: Use when two horizontal rules pretend to be frontmatter.
---
Body.
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a file whose frontmatter does not start on line 1 fails'
assert_contains "$LINT_OUT" 'must open with --- on line 1' 'the frontmatter violation says what is wrong'

# --- the oversize allowlist ratchets in both dimensions -----------------
# Lines and tokens ratchet independently: a skill that trades line count for
# longer lines still grows the context it costs.
root=$tmp/ratchet-tokens
mkdir -p "$root/review-remote-pr"
{
    printf -- '---\nname: review-remote-pr\ndescription: Use when an allowlisted skill grows in bytes only.\n---\n'
    wide_line 80000
    wide_line 80000
} > "$root/review-remote-pr/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted skill that grows in tokens alone fails'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 8144 tokens' 'the token ratchet names its ceiling'

root=$tmp/ratchet-lines
mkdir -p "$root/review-remote-pr"
{
    printf -- '---\nname: review-remote-pr\ndescription: Use when an allowlisted skill grows in lines.\n---\n'
    repeat_lines 2100
} > "$root/review-remote-pr/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted skill that grows past its line ceiling fails'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 513 lines' 'the line ratchet names its ceiling'

root=$tmp/stale
make_skill "$root" review-remote-pr <<'EOF'
---
name: review-remote-pr
description: Use when an allowlisted skill has shrunk back under the budget.
---
Now small.
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted skill back under budget fails as a stale entry'
assert_contains "$LINT_OUT" 'remove the stale KNOWN_OVERSIZE entry' 'the stale entry is named'

# The stacked parallel-issues skill is intentionally over the standard budget;
# keep its measured ratchet explicit so the lint ceiling cannot drift back to
# the predecessor's 1003-line / 16735-token values.
root=$tmp/parallel-ratchet
mkdir -p "$root/parallel-issues"
{
    printf -- '---\nname: parallel-issues\ndescription: Use when an allowlisted skill grows past its stacked ceiling.\n---\n'
    for ((i = 0; i < 1126; i++)); do
        printf 'body line %04d ' "$i"
        head -c 80 /dev/zero | tr '\0' x
        printf '\n'
    done
} > "$root/parallel-issues/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'the parallel-issues ratchet fixture exceeds its measured ceiling'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 1125 lines' \
    'the parallel-issues line ratchet pins the stacked ceiling'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 19173 tokens' \
    'the parallel-issues token ratchet pins the stacked ceiling'

# A bad allowlist field must be named, never evaluated. Under `set -u` these
# do not degrade to a loud zero: a non-numeric field aborts the whole lint with
# "unbound variable", `08` dies as an invalid octal literal, and an expression
# is silently evaluated into a different ceiling.
with_entry() { # prints the path to a lint copy whose review-remote-pr entry is $1
    local replacement=$1 copy=$tmp/lint-${2}.sh escaped
    # Match the entry by KEY, not by its current value. Pinning the literal
    # numbers meant every ratchet silently invalidated these fixtures: the
    # substitution matched nothing, the copy equalled the original, and the
    # malformed-entry cases stopped testing anything. The cmp guard below still
    # fails loudly if the entry is renamed or its shape changes.
    escaped=${replacement//\\/\\\\}
    escaped=${escaped//&/\\&}
    sed -E "s|KNOWN_OVERSIZE\[review-remote-pr\]=\"[^\"]*\"|KNOWN_OVERSIZE[review-remote-pr]=\"$escaped\"|" "$lint" > "$copy"
    chmod +x "$copy"
    if cmp -s "$lint" "$copy"; then
        _fail "the '$replacement' fixture actually edits the allowlist" \
            'the KNOWN_OVERSIZE entry format changed; update this substitution'
    fi
    printf '%s\n' "$copy"
}

for bad in '497:450' 'foo:7503:450' '497:08:450' '497:1+1:450' '497:7503:'; do
    label=$(printf '%s' "$bad" | tr -c 'a-zA-Z0-9' '-')
    run_lint "$tmp/stale" "$(with_entry "$bad" "$label")"
    assert_eq '1' "$LINT_RC" "a malformed allowlist entry ('$bad') fails"
    assert_contains "$LINT_OUT" 'malformed KNOWN_OVERSIZE entry' \
        "'$bad' is reported, not evaluated or crashed on"
done

# --- references/ shape ---------------------------------------------------
root=$tmp/refs-nested
make_skill "$root" nested <<'EOF'
---
name: nested
description: Use when references/ has a subdirectory.
---
Body.
EOF
mkdir -p "$root/nested/references/deeper"
printf 'text\n' > "$root/nested/references/deeper/note.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a subdirectory under references/ fails'

root=$tmp/refs-toc
make_skill "$root" untocd <<'EOF'
---
name: untocd
description: Use when a long reference file has no table of contents.
---
Body.
EOF
mkdir -p "$root/untocd/references"
repeat_lines 150 > "$root/untocd/references/long.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a long reference file without a TOC fails'

{
    printf '## Contents\n'
    repeat_lines 150
} > "$root/untocd/references/long.md"
run_lint "$root"
assert_eq '0' "$LINT_RC" 'a long reference file with a TOC passes'

# --- a missing final newline is still a line ----------------------------
# `wc -l` counts newlines, so an unterminated last line measured one short --
# exactly enough to sit on a boundary and pass. Both size checks use logical
# lines now, so both fixtures stop one over their limit.
root=$tmp/unterminated-body
mkdir -p "$root/frayed"
{
    printf -- '---\nname: frayed\ndescription: Use when the last body line has no newline.\n---\n'
    repeat_lines 500
    printf 'body line 500'
} > "$root/frayed/SKILL.md"
# Guards the fixture itself: 4 frontmatter lines + 501 body lines, and `wc -l`
# sees only 504 of them.
assert_eq '505' "$(awk 'END { print NR }' "$root/frayed/SKILL.md")" \
    'the unterminated body fixture is 505 logical lines (501 of body)'
assert_eq '504' "$(wc -l < "$root/frayed/SKILL.md")" \
    'wc -l undercounts that same fixture by one'
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a 501-line body without a final newline fails'

root=$tmp/unterminated-ref
make_skill "$root" frayed-ref <<'EOF'
---
name: frayed-ref
description: Use when a reference file's last line has no newline.
---
Body.
EOF
mkdir -p "$root/frayed-ref/references"
{
    repeat_lines 100
    printf 'body line 100'
} > "$root/frayed-ref/references/long.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a 101-line reference without a final newline fails'

# --- the gate must not pass by scanning nothing -------------------------
root=$tmp/empty
mkdir -p "$root"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a tree with no SKILL.md fails rather than passing vacuously'
assert_contains "$LINT_OUT" 'no SKILL.md files found' 'the empty scan is named'

finish
