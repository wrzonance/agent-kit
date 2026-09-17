#!/usr/bin/env bash
# Suite: harness-tools.sh maps harness identities to runtime sub-agent tools.
set -uo pipefail

TEST_NAME='harness-tools'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

helper="$root/agentkit/skills/.shared/scripts/lib/harness-tools.sh"

assert_eq \
    "tools= spawn=multi_agent_v1__spawn_agent wait=multi_agent_v1__wait_agent send=multi_agent_v1__send_input list='ALL_TOOLS.filter(t=>/multi_agent_v1__/.test(t.name)).map(t=>t.name)'" \
    "$(bash "$helper" codex)" \
    'Codex names the three runtime tools and the bounded registry query exactly'

assert_eq \
    "tools= spawn=Agent wait=TaskOutput send=SendMessage list='Agent,TaskOutput,SendMessage'" \
    "$(bash "$helper" claude)" \
    'Claude names its Agent-tool equivalents exactly'

assert_eq \
    "tools= spawn=unavailable wait=unavailable send=unavailable list='unavailable'" \
    "$(bash "$helper" unknown)" \
    'an unmapped harness is explicit and never borrows another runtime mapping'

assert_eq \
    "tools= spawn=unavailable wait=unavailable send=unavailable list='unavailable'" \
    "$(bash "$helper" opencode)" \
    'a known harness without a declared sub-agent interface remains unavailable'

finish
