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

finish
