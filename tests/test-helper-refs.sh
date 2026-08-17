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

policy_needle="helpers invoked by more than one skill live in \`.shared/scripts/\`"
assert_contains "$(<"$root/agentkit/skills/.shared/six-step-loop.md")" \
    "$policy_needle" \
    'the shared policy states the helper placement rule'
assert_contains "$(<"$root/agentkit/skills/review-remote-pr/references/grooming.md")" \
    'no helper script — this step is judgment' \
    'the prose-only grooming judgment carries an explicit no-script marker'

finish
