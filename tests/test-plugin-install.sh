#!/usr/bin/env bash
# Suite: the built plugin is installable by codex.
#
# A real integration test, not a mock: it registers a marketplace and installs
# the plugin into a throwaway CODEX_HOME. Codex requires a local marketplace to
# live under $HOME, so the staging directory does too; it is removed on exit.
set -uo pipefail

TEST_NAME='plugin-install'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

if ! command -v codex > /dev/null 2>&1; then
    printf '%s: codex not installed, skipping integration test\n' "$TEST_NAME"
    exit 0
fi

stage=$(mktemp -d "$HOME/.agentkit-test.XXXXXX")
tmp=$(mktemp -d)
trap 'rm -rf -- "$stage" "$tmp"' EXIT

"$here/build-plugin.sh" "$stage" > /dev/null

# --- structure -------------------------------------------------------------
assert_eq 'yes' "$([[ -f $stage/.claude-plugin/marketplace.json ]] && echo yes || echo no)" \
    'writes the marketplace manifest both harnesses read'
# One manifest per harness. A plugin carrying only one of them simply does not
# install on the other CLI -- and the same person runs both, from more than one
# account, so a single-harness manifest is a silent half-install.
for manifest in .codex-plugin .claude-plugin; do
    assert_eq 'yes' "$([[ -f $stage/agentkit/$manifest/plugin.json ]] && echo yes || echo no)" \
        "writes the $manifest plugin manifest"
done
# Both harnesses look for the hook manifest at hooks/hooks.json.
assert_eq 'yes' "$([[ -f $stage/agentkit/hooks/hooks.json ]] && echo yes || echo no)" \
    'puts hooks.json where both harnesses look for it'
assert_eq './hooks/hooks.json' \
    "$(jq -r '.hooks' "$stage/agentkit/.codex-plugin/plugin.json")" \
    'and the declared hooks path points at it'
assert_eq 'yes' "$([[ -d $stage/agentkit/skills/parallel-issues ]] && echo yes || echo no)" \
    'carries the skills'
assert_eq 'yes' "$([[ -x $stage/agentkit/skills/.shared/scripts/agent-run.sh ]] && echo yes || echo no)" \
    'preserves the executable bit on scripts'
assert_eq 'yes' "$([[ -x $stage/agentkit/hooks/stop.sh ]] && echo yes || echo no)" \
    'packages the hooks the manifest points at, executable'
assert_contains "$(jq -r '.plugins[0].source.path' < "$stage/.claude-plugin/marketplace.json")" \
    './' 'plugin source paths start with ./ as codex requires'

# --- no test material ships ------------------------------------------------
found=$(find "$stage" \( -name 'test-*' -o -name fixtures -o -name stub \) | head -1)
assert_eq '' "$found" 'no test material is packaged'

# --- the vendor tree does not ship -----------------------------------------
# .system is codex's OWN system-skills tree, vendored into the source layout.
# Packaging it reinstalls codex's built-ins under this plugin's name and carries
# .codex-system-skills.marker into a third-party plugin.
assert_eq 'no' "$([[ -e $stage/agentkit/skills/.system ]] && echo yes || echo no)" \
    'the vendored system-skills tree is not packaged'

# --- codex installs it -----------------------------------------------------
export CODEX_HOME="$tmp/codexhome"
mkdir -p "$CODEX_HOME"
[[ -f $HOME/.codex/auth.json ]] && cp "$HOME/.codex/auth.json" "$CODEX_HOME/auth.json"

add_out=$(codex plugin marketplace add "$stage" 2>&1 | grep -v 'WARNING: proceeding')
assert_contains "$add_out" 'Added marketplace' 'codex accepts the marketplace'

install_out=$(codex plugin add agentkit@agent-kit 2>&1 | grep -v 'WARNING: proceeding')
assert_contains "$install_out" 'Added plugin' 'codex installs the plugin'

list_out=$(codex plugin list 2>&1 | grep -v 'WARNING: proceeding')
assert_contains "$list_out" 'installed, enabled' 'the plugin registers as enabled'

finish
