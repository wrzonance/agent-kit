#!/usr/bin/env bash
# Suite: compose-pr-body.sh emits the fixed, file-backed PR body layout.
# shellcheck disable=SC2016  # literal body fixtures must stay unexpanded
set -uo pipefail

TEST_NAME='compose-pr-body'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

compose="$root/agentkit/skills/parallel-issues/scripts/compose-pr-body.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

why="$tmp/why.md"
what="$tmp/what.md"
decisions="$tmp/decisions.md"
testing="$tmp/testing.md"
output="$tmp/body.md"
expected="$tmp/expected.md"

printf '%s\n\n' 'Motivation with `bytes` and $(literal).' >"$why"
printf '%s\n' 'A terse outcome.' >"$what"
printf '%s\n' 'A pivot containing & and backslashes.' >"$decisions"
printf '%s\n' '- [ ] focused check' '- [x] full suite' >"$testing"

printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    '## Why' \
    '' \
    'Motivation with `bytes` and $(literal).' \
    '' \
    '## What' \
    '' \
    'A terse outcome.' \
    '' \
    '## Decisions' \
    '' \
    'A pivot containing & and backslashes.' \
    '' \
    '## Testing' \
    '' \
    '- [ ] focused check' \
    '- [x] full suite' \
    '' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' \
    '' \
    'Closes #137' >"$expected"

assert_rc 0 'composer emits the canonical body' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
if cmp -s "$expected" "$output"; then
    _pass 'canonical body bytes and section order are exact'
else
    _fail 'canonical body bytes and section order are exact' \
        "$(diff -u "$expected" "$output" | head -n 30)"
fi

assert_rc 0 'composer supports stdout output' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna'

assert_rc 1 'composer rejects a zero issue number' -- bash "$compose" \
    --issue 0 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects a missing section file' -- bash "$compose" \
    --issue 137 --why-file "$tmp/missing" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects non-checkbox Testing content' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$what" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects an empty agent identity' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent '' --output "$output"



# --- a section file named like an option is a file, not a flag -------------
# The validator hands the path straight to grep. Under GNU grep an unguarded
# `--help` operand is consumed as an option: grep exits 0 with usage text, so a
# whitespace-only Testing section passes validation and emits no checkbox. The
# argument itself must start with `--` to reproduce it, so this runs from the
# directory holding the file and passes a relative path.
optdir=$(mktemp -d "$tmp/optlike.XXXXXX")
printf '   \n' >"$optdir/--help"
cp -- "$why" "$optdir/why.md"
cp -- "$what" "$optdir/what.md"
cp -- "$decisions" "$optdir/decisions.md"
set +e
optlike_output=$(cd -- "$optdir" && bash "$compose" \
    --issue 137 --why-file why.md --what-file what.md \
    --decisions-file decisions.md --testing-file '--help' \
    --agent 'Codex gpt-5.6-luna' --output out.md 2>&1)
optlike_rc=$?
set -e
assert_eq '1' "$optlike_rc" 'a whitespace-only section named --help is rejected, not parsed as an option'
assert_not_contains "$optlike_output" 'Usage: grep' \
    'grep usage text never reaches the output'

# --- worker baseline exclusion is rendered inside Testing ------------------
exclusion="$tmp/baseline-exclusion.md"
printf '%s\n' '- [ ] Baseline exclusion: `demo-test` is unchanged and red on trunk `abc123` (evidence: `.agent/logs/demo-test.log`)' \
    >"$exclusion"
exclusion_body="$tmp/exclusion-body.md"
assert_rc 0 'composer accepts a worker baseline-exclusion file' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --baseline-exclusion-file "$exclusion" \
    --agent 'Codex gpt-5.6-luna' --output "$exclusion_body"
exclusion_text=$(<"$exclusion_body")
assert_contains "$exclusion_text" '- [ ] Baseline exclusion: `demo-test`' \
    'the worker exclusion is an unchecked Testing box'
assert_contains "$exclusion_text" '`abc123`' \
    'the Testing box carries the chain-base SHA'
testing_idx=$(grep -n '^## Testing$' "$exclusion_body" | head -n1 | cut -d: -f1)
box_idx=$(grep -n 'Baseline exclusion:' "$exclusion_body" | head -n1 | cut -d: -f1)
if [[ -n $testing_idx && -n $box_idx ]] && ((box_idx > testing_idx)); then
    _pass 'the exclusion box is emitted inside the Testing section'
else
    _fail 'the exclusion box is emitted inside the Testing section' \
        "Testing line=$testing_idx exclusion line=$box_idx"
fi

finish
