#!/usr/bin/env bash
# Suite: helper/reference paths are resolvable and placement policy is enforced.
set -uo pipefail

TEST_NAME='helper-refs'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lint="$root/tests/lint-helper-refs.sh"
skills="$root/agentkit/skills"

assert_eq 0 "$([[ -x $lint ]] && printf 0 || printf 1)" \
    'helper-reference lint is executable'
assert_rc 0 'the shipped skill tree has no unresolved helper references' \
    -- "$lint" "$skills"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fixture="$tmp/agentkit/skills"
mkdir -p "$fixture/demo/references" "$fixture/.shared/scripts"
printf '%s\n' \
    '---' \
    'name: demo' \
    'description: Use when testing helper references.' \
    '---' \
    "\"\$agentkit/demo/scripts/missing-helper.sh\"" \
    'skills/demo/scripts/missing-skills-relative.sh' \
    'scripts/missing-script.sh' \
    'references/missing-plain.md' \
    '[missing](references/missing-reference.md)' \
    > "$fixture/demo/SKILL.md"
printf '%s\n' '---' 'name: shared' 'description: Use when testing shared policy.' '---' \
    > "$fixture/.shared/policy.md"

missing_output=''
missing_rc=0
missing_output=$("$lint" "$fixture" 2>&1) || missing_rc=$?
assert_eq 1 "$missing_rc" 'a nonexistent helper/reference path fails the lint'
assert_contains "$missing_output" 'missing-helper.sh' \
    'the lint names the missing helper path'
assert_contains "$missing_output" 'missing-skills-relative.sh' \
    'the lint names a skills-relative helper path'
assert_contains "$missing_output" 'missing-script.sh' \
    'the lint names a skill-relative scripts path'
assert_contains "$missing_output" 'missing-plain.md' \
    'the lint names a plain references-relative path'
assert_contains "$missing_output" 'missing-reference.md' \
    'the lint names the missing reference path'

printf '%s\n' 'incorrect placement' > "$fixture/.shared/misplaced.sh"
chmod +x -- "$fixture/.shared/misplaced.sh"
placement_output=''
placement_rc=0
placement_output=$("$lint" "$fixture" 2>&1) || placement_rc=$?
assert_eq 1 "$placement_rc" 'an executable directly under .shared fails the lint'
assert_contains "$placement_output" 'misplaced.sh' \
    'the placement violation names the misplaced helper'

bfixture="$tmp/bracket/agentkit/skills"
mkdir -p "$bfixture/demo/references"
printf '%s\n' \
    '---' \
    'name: demo' \
    'description: Use when testing bracket-text references.' \
    '---' \
    'See [references/DOES-NOT-EXIST.md](references/hit.md) for details.' \
    'Contrast: [some text](references/REALLY-MISSING.md) has a bad destination.' \
    'Prose stays quiet: [the chains contract](references/hit.md) is not path-shaped.' \
    > "$bfixture/demo/SKILL.md"
printf 'target\n' > "$bfixture/demo/references/hit.md"

bracket_output=''
bracket_rc=0
bracket_output=$("$lint" "$bfixture" 2>&1) || bracket_rc=$?
assert_eq 1 "$bracket_rc" 'a bad bracket text with a good destination fails the lint'
assert_contains "$bracket_output" 'link bracket text' \
    'a bad bracket text is labeled distinctly from a bad destination'
assert_contains "$bracket_output" 'DOES-NOT-EXIST.md' \
    'the lint names the unresolved bracket text'
assert_contains "$bracket_output" 'link destination' \
    'a bad destination is labeled distinctly from a bad bracket text'
assert_contains "$bracket_output" 'REALLY-MISSING.md' \
    'the lint names the unresolved destination'
bracket_lines=$(printf '%s\n' "$bracket_output" | grep -c '^VIOLATION' || true)
assert_eq 2 "$bracket_lines" \
    'ordinary prose bracket text produces no extra violation'

# A markdown-link destination such as skills/demo2/foo.md is independently
# re-matched, byte for byte, by the separate $agentkit/$shared/skills/.shared
# scan of the same raw line -- that is what the shared `seen` dedup exists to
# collapse. Labeling violations by kind must not defeat that: the dedup key
# stays token-only, so the same broken path found via two extraction loops is
# still reported once, not twice under two different labels.
mkdir -p "$bfixture/demo2"
printf '%s\n' \
    '---' \
    'name: demo2' \
    'description: Use when testing cross-loop dedup.' \
    '---' \
    'See [here](skills/demo2/definitely-missing.md) for details.' \
    > "$bfixture/demo2/SKILL.md"
dedup_output=''
dedup_output=$("$lint" "$bfixture" 2>&1) || true
dedup_lines=$(printf '%s\n' "$dedup_output" | grep -c 'definitely-missing.md' || true)
assert_eq 1 "$dedup_lines" \
    'the same broken path found via two extraction loops is reported once, not twice'

# A labelled path containing interior whitespace ("the policy.md") is prose
# that happens to end in .md, not a path claim -- validating it as a token
# produced a false positive on a perfectly valid link (adversarial finding
# on PR #378, finding 1). It must never be reported, regardless of whether
# its destination resolves.
mkdir -p "$bfixture/demo3/references"
printf 'target\n' > "$bfixture/demo3/references/policy.md"
printf '%s\n' \
    '---' \
    'name: demo3' \
    'description: Use when testing a whitespace-containing bracket label.' \
    '---' \
    'See [the policy.md](references/policy.md) for details.' \
    > "$bfixture/demo3/SKILL.md"
whitespace_output=''
whitespace_output=$("$lint" "$bfixture" 2>&1) || true
whitespace_lines=$(printf '%s\n' "$whitespace_output" | grep -c 'demo3/SKILL.md' || true)
assert_eq 0 "$whitespace_lines" \
    'a labelled path with interior whitespace is prose, not a path claim, and is never reported'

# A link label containing an escaped `]` (e.g. "[policy \] archive](dest)")
# must not blind the lint to a genuinely broken destination: pairing the
# whole `[label](` to extract a destination lets the label swallow the `]`
# and hide the entire link from a label-anchored extraction (adversarial
# finding on PR #378, finding 2 -- a real coverage regression this issue's
# own fix introduced and then had to repair).
mkdir -p "$bfixture/demo4/references"
printf '%s\n' \
    '---' \
    'name: demo4' \
    'description: Use when testing an escaped bracket in a link label.' \
    '---' \
    'See [policy \] archive](references/escaped-bracket-missing.md) for details.' \
    > "$bfixture/demo4/SKILL.md"
escaped_output=''
escaped_output=$("$lint" "$bfixture" 2>&1) || true
assert_contains "$escaped_output" 'escaped-bracket-missing.md' \
    'a bad destination behind a label with an escaped bracket still fails the lint'

policy_needle="helpers invoked by more than one skill live in \`.shared/scripts/\`"
assert_contains "$(<"$root/agentkit/skills/.shared/six-step-loop.md")" \
    "$policy_needle" \
    'the shared policy states the helper placement rule'
assert_contains "$(<"$root/agentkit/skills/review-remote-pr/references/grooming.md")" \
    'no helper script — this step is judgment' \
    'the prose-only grooming judgment carries an explicit no-script marker'

finish
