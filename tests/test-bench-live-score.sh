#!/usr/bin/env bash
# Suite: bench/live/score.py -- one scorer for Codex and Claude Code roots, same record shape,
# with root wakes counted by trigger. Fixtures are tiny hand-written transcripts.
set -uo pipefail

TEST_NAME='bench live score'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

score="$repo_root/bench/live/score.py"
fixtures="$repo_root/tests/fixtures/bench-live"

command -v python3 > /dev/null 2>&1 || { printf '%s: python3 is required\n' "$TEST_NAME" >&2; exit 1; }
command -v jq > /dev/null 2>&1 || { printf '%s: jq is required\n' "$TEST_NAME" >&2; exit 1; }

claude=$(python3 "$score" "$fixtures/claude/sess-1.jsonl" 2>&1)
field() { jq -r "$1" <<< "$2"; }

assert_eq 2 "$(field .root.wakes.by_trigger.agent_done "$claude")" 'claude: two agent notices are agent_done wakes'
assert_eq 1 "$(field .root.wakes.by_trigger.bash_done "$claude")" 'claude: one background command notice is a bash_done wake'
assert_eq 1 "$(field .root.wakes.by_trigger.human "$claude")" 'claude: one human prompt'
assert_eq 4 "$(field .root.wakes.total "$claude")" 'claude: tool results are not wakes'
assert_eq 1 "$(field .root.prompts "$claude")" 'claude: prompts counts human lines only'
assert_eq 10232 "$(field .root.tokens.total_tokens "$claude")" 'claude: tokens counted once per message.id'
assert_eq 10000 "$(field .root.cache_read_tokens "$claude")" 'claude: cache_read_tokens sums cache reads'
assert_eq 2 "$(field .root.calls "$claude")" 'claude: tool_use blocks counted'
assert_eq 1 "$(field .root.spawns "$claude")" 'claude: Agent tool_use is a spawn'
assert_eq 1 "$(field .root.help_calls "$claude")" 'claude: --help Bash call counted'
assert_eq 1 "$(field .workers.count "$claude")" 'claude: subagents/agent-*.jsonl are workers'
assert_eq 555 "$(field .workers.tokens "$claude")" 'claude: worker tokens'

forced=$(python3 "$score" "$fixtures/claude/sess-1.jsonl" --harness claude 2>&1)
assert_eq "$(field .root.wakes "$claude")" "$(field .root.wakes "$forced")" 'claude: --harness claude matches detection'

codex=$(python3 "$score" "$fixtures/codex/2026/10/23/rollout-root.jsonl" --sessions "$fixtures/codex" 2>&1)
assert_eq 4 "$(field .root.wakes.total "$codex")" 'codex: wakes = wait_agent returns + user turns'
assert_eq 2 "$(field .root.wakes.by_trigger.agent_done "$codex")" 'codex: wait_agent returns are agent_done'
assert_eq 2 "$(field .root.wakes.by_trigger.human "$codex")" 'codex: both user turns are human'
assert_eq 900 "$(field .root.cache_read_tokens "$codex")" 'codex: cache_read_tokens = final cached_input_tokens'
assert_eq 1500 "$(field .root.tokens.total_tokens "$codex")" 'codex: root tokens unchanged'
assert_eq 2 "$(field .root.prompts "$codex")" 'codex: prompts unchanged'
assert_eq 1 "$(field .root.steers "$codex")" 'codex: steers unchanged'
assert_eq 2 "$(field .root.waits "$codex")" 'codex: waits unchanged'
assert_eq 1 "$(field .workers.count "$codex")" 'codex: worker found'
assert_eq 2200 "$(field .system_tokens "$codex")" 'codex: system tokens unchanged'

finish
