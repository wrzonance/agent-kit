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
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 34808 tokens' 'the token ratchet names its ceiling'

root=$tmp/ratchet-lines
mkdir -p "$root/review-remote-pr"
{
    printf -- '---\nname: review-remote-pr\ndescription: Use when an allowlisted skill grows in lines.\n---\n'
    repeat_lines 2100
} > "$root/review-remote-pr/SKILL.md"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted skill that grows past its line ceiling fails'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 2087 lines' 'the line ratchet names its ceiling'

root=$tmp/stale
make_skill "$root" onboard-repo <<'EOF'
---
name: onboard-repo
description: Use when an allowlisted skill has shrunk back under the budget.
---
Now small.
EOF
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted skill back under budget fails as a stale entry'
assert_contains "$LINT_OUT" 'remove the stale KNOWN_OVERSIZE entry' 'the stale entry is named'

# A short allowlist entry reaches the ratchet arithmetic with an empty
# operand, which aborts the whole lint instead of naming the bad line.
malformed=$tmp/malformed-lint.sh
sed 's|\[onboard-repo\]="464:5476:350"|[onboard-repo]="464:350"|' "$lint" > "$malformed"
chmod +x "$malformed"
if cmp -s "$lint" "$malformed"; then
    _fail 'the malformed-entry fixture actually edits the allowlist' \
        'the KNOWN_OVERSIZE entry format changed; update this substitution'
else
    _pass 'the malformed-entry fixture actually edits the allowlist'
fi
run_lint "$tmp/stale" "$malformed"
assert_eq '1' "$LINT_RC" 'a malformed allowlist entry fails'
assert_contains "$LINT_OUT" 'malformed KNOWN_OVERSIZE entry' 'a malformed entry is reported, not a crash'

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

# --- the gate must not pass by scanning nothing -------------------------
root=$tmp/empty
mkdir -p "$root"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a tree with no SKILL.md fails rather than passing vacuously'
assert_contains "$LINT_OUT" 'no SKILL.md files found' 'the empty scan is named'

finish
