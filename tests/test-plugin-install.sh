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

# $HOME is not always writable, and that is not a failure of this tree.
#
# This suite is the declared VERIFY command for agent-kit itself, so Stop runs
# it at the end of every turn. Under a workspace-scoped sandbox $HOME is
# read-only, and a live onboarding session watched the whole suite fail here and
# then re-ran it with elevation -- a permission escalation per turn, to satisfy
# an integration test that was never the point of the turn.
#
# Probed by trying, not by checking permission bits: a read-only mount reports
# the same bits as a writable one, and a read-only mount is the case at issue.
if ! stage=$(mktemp -d "$HOME/.agentkit-test.XXXXXX" 2> /dev/null); then
    # shellcheck disable=SC2016  # HOME is named for the reader, not expanded
    printf '%s: $HOME is not writable here, skipping integration test\n' "$TEST_NAME"
    printf '%s: codex requires a local marketplace under the home directory, so\n' "$TEST_NAME"
    printf '%s: this suite cannot run in a workspace-scoped sandbox. Nothing was\n' "$TEST_NAME"
    printf '%s: verified about installation.\n' "$TEST_NAME"
    exit 0
fi
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
assert_eq 'yes' "$([[ -f $stage/agentkit/skills/pr-to-green/SKILL.md ]] && echo yes || echo no)" \
    'packages pr-to-green for both harness manifests'
assert_eq 'yes' "$([[ -x $stage/agentkit/skills/pr-to-green/scripts/review-transition.sh ]] && echo yes || echo no)" \
    'preserves the pr-to-green transition executable'
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
