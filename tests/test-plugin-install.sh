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
# This suite is the declared VERIFY command for agent-kit itself. Under a
# workspace-scoped sandbox $HOME is read-only, and a live onboarding session
# watched the whole suite fail here and then re-ran it with elevation -- a
# permission escalation per turn, to satisfy an integration test that was
# never the point of the turn.
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
assert_eq 'no' "$([[ -e $stage/agentkit/hooks/stop.sh ]] && echo yes || echo no)" \
    'does not package the removed stop.sh turn-gate hook'
assert_contains "$(jq -r '.plugins[0].source' < "$stage/.claude-plugin/marketplace.json")" \
    './' 'plugin source paths start with ./ as both harnesses require'

# --- opencode surface -------------------------------------------------------
# OpenCode is a third harness, packaged alongside (never in place of) the
# Claude/Codex manifests above: this block must not perturb any assertion
# before it. There is no OpenCode plugin registry install to exercise here --
# unlike Claude/Codex, OpenCode loads a local file straight out of a plugins
# directory, so the closest thing to "installs it" is importing the shipped
# module the way OpenCode's runtime would.
assert_eq 'yes' "$([[ -f $stage/opencode/package.json ]] && echo yes || echo no)" \
    'writes the opencode package manifest'
assert_eq 'yes' "$([[ -f $stage/opencode/index.js ]] && echo yes || echo no)" \
    'writes the opencode plugin module'
assert_eq "$(jq -r .version < "$here/../agentkit/.codex-plugin/plugin.json" 2> /dev/null)" \
    "$(jq -r .version < "$stage/opencode/package.json" 2> /dev/null)" \
    'opencode manifest version matches the codex/claude manifests'

if command -v node > /dev/null 2>&1; then
    smoke_out=$(node --input-type=module -e "
        import('file://' + process.argv[1]).then(async (m) => {
            if (typeof m.AgentKitPlugin !== 'function') throw new Error('AgentKitPlugin missing');
            if (typeof m.default !== 'function') throw new Error('default export missing');
            const hooks = await m.AgentKitPlugin({});
            if (typeof hooks !== 'object' || hooks === null) throw new Error('hooks not an object');
            if (!('session.idle' in hooks)) throw new Error('session.idle hook missing');
            if (!('experimental.chat.system.transform' in hooks)) throw new Error('experimental.chat.system.transform hook missing');
            process.stdout.write('ok');
        }).catch((e) => { process.stderr.write(String(e)); process.exit(1); });
    " "$stage/opencode/index.js" 2>&1)
    assert_eq 'ok' "$smoke_out" \
        'node imports the built opencode module with no server and no install step'
else
    printf '%s: node not installed, skipping opencode module smoke test\n' "$TEST_NAME"
fi

# --- claude validates it ---------------------------------------------------
# The string source form is the one shape both schemas accept: claude rejects
# the {"source":"local","path":...} object outright, and codex installs the
# string form (proven below). Guarded like the codex half: absence skips, it
# never fails the suite.
if command -v claude > /dev/null 2>&1; then
    validate_out=$(claude plugin validate "$stage" 2>&1 || true)
    assert_contains "$validate_out" 'Validation passed' \
        'claude accepts the marketplace manifest'
else
    printf '%s: claude not installed, skipping claude validation\n' "$TEST_NAME"
fi

# --- no test material ships ------------------------------------------------
found=$(find "$stage" \( -name 'test-*' -o -name fixtures -o -name stub \) | head -1)
assert_eq '' "$found" 'no test material is packaged'

# --- the vendor tree does not ship -----------------------------------------
# .system is codex's OWN system-skills tree, vendored into the source layout.
# Packaging it reinstalls codex's built-ins under this plugin's name and carries
# .codex-system-skills.marker into a third-party plugin.
assert_eq 'no' "$([[ -e $stage/agentkit/skills/.system ]] && echo yes || echo no)" \
    'the vendored system-skills tree is not packaged'

# --- no stray hook-error log ships ------------------------------------------
# .agent/ is per-machine hook/session state; a stray hook-errors.jsonl written
# from a cwd inside the skills tree must never reach a plugin consumer,
# regardless of where in the copied tree it landed (issue #370).
found_agent=$(find "$stage" -name '.agent' | head -1)
assert_eq '' "$found_agent" 'no .agent/ directory is packaged anywhere in the built plugin'

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
