#!/usr/bin/env bash
# Suite: harness-tools.sh maps harness identities to runtime sub-agent tools.
set -uo pipefail

TEST_NAME='harness-tools'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

helper="$root/agentkit/skills/.shared/scripts/lib/harness-tools.sh"
codex_tools="tools= spawn=multi_agent_v1__spawn_agent wait=multi_agent_v1__wait_agent send=multi_agent_v1__send_input list='ALL_TOOLS.filter(t=>/multi_agent_v1__/.test(t.name)).map(t=>t.name)'"
claude_tools="tools= spawn=Agent wait=TaskOutput send=SendMessage list='Agent,TaskOutput,SendMessage'"
unknown_tools="tools= spawn=unknown wait=unknown send=unknown list='unknown'"

assert_eq \
    "$codex_tools" \
    "$(bash "$helper" codex)" \
    'Codex names the three runtime tools and the bounded registry query exactly'

assert_eq \
    "$claude_tools" \
    "$(bash "$helper" claude)" \
    'Claude names its Agent-tool equivalents exactly'

assert_eq \
    "$unknown_tools" \
    "$(bash "$helper" unknown)" \
    'an unmapped harness preserves unknown capability state for live inspection'

assert_eq \
    "$unknown_tools" \
    "$(bash "$helper" opencode)" \
    'OpenCode preserves unknown capability state instead of falsely degrading to self'

spawn_contract=$(<"$root/agentkit/skills/.shared/spawn-contract.md")
assert_contains "$spawn_contract" 'spawn=unknown' \
    'the spawn contract distinguishes an unmapped capability from a known absence'
assert_contains "$spawn_contract" 'inspect the live runtime' \
    'unknown capability state directs the root to inspect its live runtime tools'
assert_contains "$spawn_contract" 'only when that inspection shows no spawn capability' \
    'unknown capability state reaches the degraded path only after live inspection proves absence'

# shellcheck disable=SC1090
source "$helper"
assert_rc 0 'a Codex mapping matches only the detected Codex harness' -- \
    harness_tools_record_matches "$codex_tools" codex
assert_rc 1 'a Claude mapping is rejected for the detected Codex harness' -- \
    harness_tools_record_matches "$claude_tools" codex
assert_rc 1 'a Codex mapping is rejected for the detected Claude harness' -- \
    harness_tools_record_matches "$codex_tools" claude
assert_rc 0 'OpenCode retains the unknown live-inspection mapping' -- \
    harness_tools_record_matches "$unknown_tools" opencode

finish
