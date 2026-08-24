#!/usr/bin/env bash
# Suite: the shipped reference manifest is discoverable, complete, and sound.
#
# The manifest exists so an agent that needs a companion reference reads ONE
# file and resolves absolute paths from it, instead of searching a tree whose
# most-referenced directory (`.shared/`) is invisible to `rg --files`, to shell
# globs without `dotglob`, and to naive `find`-based discovery. A manifest that
# can silently disagree with the filesystem would send the agent straight back
# to searching, so both directions are gated here.
#
# shellcheck disable=SC2016  # every single-quoted $agentkit below is literal
# manifest/SKILL.md text being matched, never a variable to expand here.
set -uo pipefail

TEST_NAME='reference manifest'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lint="$root/tests/lint-reference-manifest.sh"
helper_lint="$root/tests/lint-helper-refs.sh"
skills="$root/agentkit/skills"
manifest="$skills/references.md"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

LINT_RC=0
LINT_OUT=''
run_lint() {
    LINT_RC=0
    LINT_OUT=$("$lint" "$1" 2>&1) || LINT_RC=$?
}

# stage_tree DEST -- a copy of the shipped skills tree the fixtures mutate.
stage_tree() {
    mkdir -p "$1"
    cp -a "$skills/." "$1/"
}

# --- the shipped tree ----------------------------------------------------
assert_eq 0 "$([[ -x $lint ]] && printf 0 || printf 1)" \
    'the reference-manifest lint is executable'
assert_rc 0 'the shipped manifest and the shipped tree agree' -- "$lint" "$skills"

# --- discoverability: no --hidden, no search ----------------------------
# The whole point of the manifest's location. A dotted path would put it back
# behind the same flag that hid `.shared/` in the first place.
assert_eq 0 "$([[ -f $manifest ]] && printf 0 || printf 1)" \
    'the manifest ships at agentkit/skills/references.md'
assert_eq '' "$(printf '%s\n' "${manifest#"$root/"}" | grep -oE '(^|/)\.[^/]+' || true)" \
    'no path component of the manifest is dotted'
assert_contains "$(find "$skills" -maxdepth 1 -name '*.md' -type f)" 'references.md' \
    'a default depth-1 enumeration finds the manifest without --hidden'

# --- the manifest names every reference, with a purpose ------------------
# Computed here independently of the lint: a gate that derives both sides from
# the same parser can agree with itself while disagreeing with the tree.
mapfile -t shipped < <(
    {
        find "$skills/.shared" -maxdepth 1 -type f -name '*.md'
        find "$skills" -mindepth 3 -maxdepth 3 -type f -path '*/references/*.md'
    } | sed "s|^$skills/||" | sort
)
if ((${#shipped[@]} >= 10)); then
    _pass 'the shipped tree has a non-trivial number of reference files'
else
    _fail 'the shipped tree has a non-trivial number of reference files' \
        "found ${#shipped[@]}"
fi
manifest_text=$(<"$manifest")
for ref in "${shipped[@]}"; do
    assert_contains "$manifest_text" "\`\$agentkit/$ref\`" "the manifest lists $ref"
done
# Anchored on the `.md` suffix so the grammar example in the manifest's own
# fenced block (a `<placeholder>` path) is not counted as an entry.
mapfile -t entries < <(sed -n 's/^- `\$agentkit\/\([^`]*\.md\)` -- .*/\1/p' "$manifest")
assert_eq "${#shipped[@]}" "${#entries[@]}" \
    'the manifest carries exactly one entry per shipped reference file'
mapfile -t read_conditions < <(sed -n 's/^- `\$agentkit\/[^`]*\.md` -- .* | Read when: \([^ ].*\)$/\1/p' "$manifest")
assert_eq "${#shipped[@]}" "${#read_conditions[@]}" \
    'every manifest entry states when the reference must be read'
assert_contains "$manifest_text" 'verification-isolation.md` -- Compose project isolation and how to read an `agent-run.sh` failure, including the environment-retry-eligible finding | Read when: the repository declares a Compose-driven command or any `agent-run.sh` result must be interpreted' \
    'verification isolation applies to Compose commands and agent-run result interpretation'
assert_contains "$manifest_text" 'adversarial-review.md` -- the Step 1b adversarial-review contract: materiality, attribution, external-service authorization, cross-provider consent, and the exit-code table | Read when: review Phase A reaches Step 1b or any skill runs an adversarial cross-review' \
    'adversarial review applies to Step 1b and every cross-review caller'

# --- negative: an entry whose file does not exist ------------------------
fixture=$tmp/missing-file
stage_tree "$fixture"
printf -- '- `$agentkit/.shared/never-shipped.md` -- a reference that does not exist | Read when: testing a missing file\n' \
    >> "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a manifest entry with no file on disk fails'
assert_contains "$LINT_OUT" '.shared/never-shipped.md' \
    'the missing-file violation names the path'

# --- negative: a reference file the manifest does not list ---------------
fixture=$tmp/unlisted
stage_tree "$fixture"
printf '# Orphan\n' > "$fixture/.shared/unlisted-policy.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a reference file absent from the manifest fails'
assert_contains "$LINT_OUT" '.shared/unlisted-policy.md' \
    'the unlisted-reference violation names the path'

# --- negative: a deliberately RENAMED reference --------------------------
# The issue's named verification case. A rename must fail in BOTH directions
# and name both paths, so the report says what moved rather than "something
# is wrong".
fixture=$tmp/renamed
stage_tree "$fixture"
mv "$fixture/.shared/wait-discipline.md" "$fixture/.shared/waiting.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a renamed reference file fails the manifest gate'
assert_contains "$LINT_OUT" '.shared/wait-discipline.md' \
    'the rename is reported against the manifest path that no longer resolves'
assert_contains "$LINT_OUT" '.shared/waiting.md' \
    'and against the new path no manifest entry covers'

# --- negative: structural manifest defects -------------------------------
fixture=$tmp/duplicate
stage_tree "$fixture"
printf -- '- `$agentkit/.shared/wait-discipline.md` -- listed a second time | Read when: testing a duplicate\n' \
    >> "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a duplicated manifest entry fails'
assert_contains "$LINT_OUT" 'duplicate' 'the duplicate is named as such'

fixture=$tmp/empty-purpose
stage_tree "$fixture"
sed -i 's#^- `\$agentkit/\.shared/wait-discipline\.md` -- .*#- `$agentkit/.shared/wait-discipline.md` --  | Read when: testing an empty purpose#' \
    "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'an entry with no one-line purpose fails'

fixture=$tmp/missing-read-condition
stage_tree "$fixture"
sed -i 's| \| Read when: .*$||' "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'an entry with no read-when condition fails'
assert_contains "$LINT_OUT" 'Read when:' \
    'the missing-condition violation names the required field'

fixture=$tmp/empty-read-condition
stage_tree "$fixture"
sed -i 's#^\(- `\$agentkit/\.shared/wait-discipline\.md` -- .* | Read when:\) .*#\1 #' \
    "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'an entry with an empty read-when condition fails'

fixture=$tmp/malformed
stage_tree "$fixture"
printf -- '- `$agentkit/.shared/wait-discipline.md` - one dash is not the separator\n' \
    >> "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'an entry that does not follow the documented grammar fails'
assert_contains "$LINT_OUT" 'malformed manifest entry' \
    'the malformed entry is reported, not silently skipped'

# A traversal entry would resolve outside the tree the manifest describes, so
# an agent following it leaves the skills tree entirely.
fixture=$tmp/traversal
stage_tree "$fixture"
printf -- '- `$agentkit/../../etc/passwd.md` -- escapes the skills tree | Read when: testing traversal\n' \
    >> "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'an entry that escapes the skills tree fails'
assert_contains "$LINT_OUT" 'not a tree-relative markdown path' \
    'the traversal entry is named as such'

fixture=$tmp/absent-manifest
stage_tree "$fixture"
rm -f "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a skills tree with no manifest fails'
assert_contains "$LINT_OUT" 'references.md' 'the absent manifest is named'

# --- the gate must not pass by scanning nothing --------------------------
fixture=$tmp/vacuous
mkdir -p "$fixture"
printf '# Reference manifest\n\nNo entries.\n' > "$fixture/references.md"
run_lint "$fixture"
assert_eq 1 "$LINT_RC" 'a manifest with zero entries fails rather than passing vacuously'

run_lint "$tmp/does-not-exist"
assert_eq 2 "$LINT_RC" 'a missing skills directory is a usage error, not a violation'

# --- link integrity covers the manifest ----------------------------------
# Every path the manifest names is also checked by the helper/reference lint,
# so a manifest entry can never name a file that does not resolve.
assert_rc 0 'the helper/reference lint accepts the shipped manifest' \
    -- "$helper_lint" "$skills"
fixture=$tmp/broken-link
stage_tree "$fixture"
printf -- '- `$agentkit/.shared/broken-link-target.md` -- an unresolvable link | Read when: testing link integrity\n' \
    >> "$fixture/references.md"
link_rc=0
link_out=$("$helper_lint" "$fixture" 2>&1) || link_rc=$?
assert_eq 1 "$link_rc" 'a broken link in the manifest fails the link-integrity lint'
assert_contains "$link_out" 'broken-link-target.md' \
    'the link-integrity violation names the unresolved path'

# --- SKILL.md read instructions carry the resolvable form ----------------
# An agent should never have to reconstruct the prefix: the contract already
# resolved the tree, so a reference instruction spells the path it can open.
for skill in parallel-issues review-remote-pr pr-to-green; do
    body=$(<"$skills/$skill/SKILL.md")
    assert_contains "$body" '"$agentkit/references.md"' \
        "$skill/SKILL.md names the reference manifest"
    rooted=$(grep -c '"\$agentkit/[^"]*\.md"' "$skills/$skill/SKILL.md" || true)
    if ((rooted >= 2)); then
        _pass "$skill/SKILL.md spells its reference reads as \$agentkit-rooted paths"
    else
        _fail "$skill/SKILL.md spells its reference reads as \$agentkit-rooted paths" \
            "found $rooted rooted reference paths"
    fi
done

finish
