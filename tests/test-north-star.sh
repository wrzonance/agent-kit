#!/usr/bin/env bash
# The project's north star is the first thing any agent in this checkout reads.
set -uo pipefail

TEST_NAME='north star'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

agents="$root/AGENTS.md"
claude="$root/CLAUDE.md"
assert_eq yes "$([[ -f $agents ]] && printf yes || printf no)" 'AGENTS.md exists at the repo root'
assert_eq '## North star' "$(grep -m1 '^## ' "$agents" 2>/dev/null)" \
    'the first section of AGENTS.md is the north star'
assert_contains "$(sed -n '1,12p' "$agents" 2>/dev/null)" 'fast' \
    'the north star is stated in the opening lines, not buried'
assert_contains "$(tr '\n' ' ' < "$agents" 2>/dev/null)" 'which measured turn, token, or failure does it remove' \
    'AGENTS.md carries the test every new rule must pass'
assert_eq '@AGENTS.md' "$(sed -n '1p' "$claude" 2>/dev/null)" \
    'CLAUDE.md imports AGENTS.md so Claude agents read the same north star'
assert_eq yes "$([[ $(wc -c < "$agents") -le 8000 && $(wc -l < "$agents") -le 200 ]] && printf yes || printf no)" \
    'AGENTS.md stays within 8000 bytes and 200 lines (every session in this repo loads it)'

finish
