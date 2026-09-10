#!/usr/bin/env bash
# Suite: helper-script size ratchet (tests/lint-helper-size.sh).
#
# Each case gets its own plugin root so the lint's discovery glob sees exactly
# the fixtures that case wrote. Allowlisted fixtures reuse a real KNOWN_OVERSIZE
# key (hooks/lib/guard-lib.sh) so the ratchet cases exercise the live table.
set -uo pipefail

TEST_NAME='helper size'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lint="$here/lint-helper-size.sh"
plugin="$(dirname -- "$here")/agentkit"
tmp=$(mktemp -d)
# u+rwx first: a case that locks down a fixture subdirectory (chmod 000) must
# not leave rm -rf unable to remove it.
trap 'chmod -R u+rwx -- "$tmp" 2> /dev/null; rm -rf -- "$tmp"' EXIT

LINT_RC=0
LINT_OUT=''

run_lint() {
    LINT_RC=0
    LINT_OUT=$("${2:-$lint}" "$1" 2>&1) || LINT_RC=$?
}

# write_script ROOT REL LINES WIDTH -- a shell file of LINES lines, each WIDTH
# bytes wide (newline included), under ROOT/REL.
write_script() {
    local root=$1 rel=$2 lines=$3 width=$4 i
    mkdir -p "$(dirname -- "$root/$rel")"
    {
        printf '#!/usr/bin/env bash\n'
        for ((i = 1; i < lines; i++)); do
            printf '# '
            head -c "$((width - 3))" /dev/zero | tr '\0' x
            printf '\n'
        done
    } > "$root/$rel"
}

# --- the live tree ------------------------------------------------------
run_lint "$plugin"
assert_eq '0' "$LINT_RC" 'the shipped helper tree passes its own ratchet'
assert_contains "$LINT_OUT" '0 violations' 'the live tree reports no violations'

# --- the happy path -----------------------------------------------------
root=$tmp/compliant
write_script "$root" skills/.shared/scripts/tidy.sh 40 30
write_script "$root" hooks/pre-tool-use.sh 40 30
printf 'not a script\n' > "$root/skills/.shared/scripts/README.md"
run_lint "$root"
assert_eq '0' "$LINT_RC" 'a compliant tree passes'
assert_contains "$LINT_OUT" 'helper size: 2 helpers checked, 0 violations' \
    'only .sh files under skills/ and hooks/ are counted'

# --- per-file budget ----------------------------------------------------
root=$tmp/oversize-lines
write_script "$root" skills/x/scripts/fat.sh 900 30
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a helper over the line budget fails'
assert_contains "$LINT_OUT" 'is 900 lines' 'the line count is reported'

root=$tmp/oversize-tokens
write_script "$root" skills/x/scripts/wide.sh 100 500
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a helper over the token budget fails on tokens alone'
assert_contains "$LINT_OUT" 'tokens (budget:' 'the token budget is named'

# --- ratchet ------------------------------------------------------------
root=$tmp/ratchet-lines
write_script "$root" hooks/lib/guard-lib.sh 2400 30
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted helper that grows past its line ceiling fails'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 2298 lines' \
    'the line ratchet names its ceiling'

root=$tmp/ratchet-tokens
write_script "$root" hooks/lib/guard-lib.sh 900 130
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted helper that grows in tokens alone fails'
assert_contains "$LINT_OUT" 'past its ratcheted ceiling of 25215 tokens' \
    'the token ratchet names its ceiling'

root=$tmp/stale
write_script "$root" hooks/lib/guard-lib.sh 20 30
run_lint "$root"
assert_eq '1' "$LINT_RC" 'an allowlisted helper back under budget fails as a stale entry'
assert_contains "$LINT_OUT" 'remove the stale KNOWN_OVERSIZE entry' 'the stale entry is named'

# A bad allowlist field must be named, never evaluated (see the same case in
# test-skill-size.sh for why `set -u` makes this a crash, not a zero).
with_entry() { # prints the path to a lint copy whose guard-lib entry is $1
    local replacement=$1 copy=$tmp/lint-${2}.sh escaped
    escaped=${replacement//\\/\\\\}
    escaped=${escaped//&/\\&}
    sed -E "s|\[hooks/lib/guard-lib\.sh\]=\"[^\"]*\"|[hooks/lib/guard-lib.sh]=\"$escaped\"|" \
        "$lint" > "$copy"
    chmod +x "$copy"
    if [[ ! -e $tmp/lib/token-estimate.sh ]]; then
        mkdir -p "$tmp/lib"
        cp "$here/lib/token-estimate.sh" "$tmp/lib/token-estimate.sh"
    fi
    if cmp -s "$lint" "$copy"; then
        _fail "the '$replacement' fixture actually edits the allowlist" \
            'the KNOWN_OVERSIZE entry format changed; update this substitution'
    fi
    printf '%s\n' "$copy"
}

for bad in '2298:25215' 'foo:25215:800' '2298:08:800' '2298:1+1:800' '2298:25215:'; do
    label=$(printf '%s' "$bad" | tr -c 'a-zA-Z0-9' '-')
    run_lint "$tmp/stale" "$(with_entry "$bad" "$label")"
    assert_eq '1' "$LINT_RC" "a malformed allowlist entry ('$bad') fails"
    assert_contains "$LINT_OUT" 'malformed KNOWN_OVERSIZE entry' \
        "'$bad' is reported, not evaluated or crashed on"
done

# --- tree total ---------------------------------------------------------
# Forty-five helpers each under both per-file caps, together over the tree
# ceiling: diffuse growth must fail even when no single file does.
root=$tmp/tree-total
for ((n = 0; n < 45; n++)); do
    write_script "$root" "skills/x/scripts/part-$n.sh" 790 48
done
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a tree over the total token ceiling fails'
assert_contains "$LINT_OUT" 'tree total' 'the tree ceiling is named'
assert_not_contains "$LINT_OUT" 'part-0.sh: body is' 'no per-file violation is reported'

# --- subscript injection -------------------------------------------------
# `-v arr[$key]` re-expands $key as a subscript for an associative array on
# Bash 5.1+, so a helper path containing a command substitution must never
# have that substitution executed while linting.
root=$tmp/inject
marker=$tmp/pwned-marker
rm -f -- "$marker"
write_script "$root" "skills/x/scripts/\$(touch $marker).sh" 10 30
run_lint "$root"
if [[ -e $marker ]]; then
    _fail 'a command substitution in a helper path is never executed' \
        "marker file was created: $marker"
else
    _pass 'a command substitution in a helper path is never executed'
fi

# --- scan failure ---------------------------------------------------------
# A `find`/`sort` failure (an unreadable subtree) must fail the lint loudly
# rather than being silently discarded by an unchecked process substitution.
if ((EUID == 0)); then
    printf '  skip  unreadable subtree fails the scan (running as root; chmod is a no-op)\n'
else
    root=$tmp/unreadable
    write_script "$root" skills/x/scripts/ok.sh 10 30
    write_script "$root" skills/locked/hidden.sh 10 30
    chmod 000 "$root/skills/locked"
    run_lint "$root"
    assert_eq '1' "$LINT_RC" 'an unreadable subtree fails the lint rather than passing on a partial scan'
    assert_contains "$LINT_OUT" 'scan failed' 'the scan failure is named as a violation'
    chmod u+rwx "$root/skills/locked"
fi

# --- nothing scanned ----------------------------------------------------
root=$tmp/empty
mkdir -p "$root/skills/x" "$root/hooks"
run_lint "$root"
assert_eq '1' "$LINT_RC" 'a tree with no helpers fails rather than passing vacuously'
assert_contains "$LINT_OUT" 'lint ran against nothing' 'the empty scan is named'

finish
