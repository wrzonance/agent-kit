#!/usr/bin/env bash
# Suite: the skill tree locates itself under BOTH install layouts.
#
# Packaging moves the tree. Standalone it sits at $CODEX_HOME/skills; installed
# as a plugin it sits at
# $CODEX_HOME/plugins/cache/<marketplace>/agentkit/<version>/skills. Before this
# was fixed, every one of the 28 helper invocations in the SKILL.md files
# resolved to the standalone path only, so a plugin-installed skill could not
# find its own scripts -- and the plugin-install test did not catch it, because
# it checked structure rather than execution.
#
# The resolver is EXTRACTED FROM THE SHIPPED SKILL.md rather than copied here,
# so this suite cannot drift from the text agents actually run.
set -uo pipefail

TEST_NAME='skill-path-resolution'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Pull the resolver out of the shipped markdown: the `agentkit=$(find ...)`
# continuation plus the fallback line that follows it.
extract_resolver() {
    awk '
        /^agentkit=\$\(find /      { capture = 1 }
        capture                    { print }
        /^\[ -n "\$agentkit" \]/   { if (capture) exit }
    ' "$skills/review-remote-pr/SKILL.md"
}

resolver=$(extract_resolver)
printf '%s\n' "$resolver" > "$tmp/resolver.sh"
assert_contains "$resolver" 'plugins/cache' 'the shipped resolver looks in the plugin location'
assert_contains "$resolver" 'agentkit' 'and names the plugin directory'
assert_eq '3' "$(printf '%s\n' "$resolver" | grep -c .)" 'the resolver is three lines'

# Run the extracted resolver against a synthetic CODEX_HOME and print what it chose.
resolve_with() {
    local home=$1
    CODEX_HOME="$home" bash -c "
        set -uo pipefail
        $(cat "$tmp/resolver.sh")
        printf '%s' \"\$agentkit\"
    " 2>/dev/null
}

# --- standalone layout -----------------------------------------------------
h="$tmp/standalone"
mkdir -p "$h/skills/.shared/scripts"
assert_eq "$h/skills" "$(resolve_with "$h")" 'standalone install resolves to the CODEX_HOME skills dir'

# --- plugin layout ---------------------------------------------------------
h="$tmp/plugin"
mkdir -p "$h/plugins/cache/agent-kit/agentkit/0.1.0/skills/.shared/scripts"
assert_eq "$h/plugins/cache/agent-kit/agentkit/0.1.0/skills" "$(resolve_with "$h")" \
    'plugin install resolves into the plugin cache'

# --- both present: the managed plugin copy wins ----------------------------
h="$tmp/both"
mkdir -p "$h/skills/.shared/scripts"
mkdir -p "$h/plugins/cache/agent-kit/agentkit/0.1.0/skills/.shared/scripts"
assert_eq "$h/plugins/cache/agent-kit/agentkit/0.1.0/skills" "$(resolve_with "$h")" \
    'with both installed the plugin copy wins'

# --- several versions: the newest wins -------------------------------------
h="$tmp/versions"
for v in 0.1.0 0.2.0; do
    mkdir -p "$h/plugins/cache/agent-kit/agentkit/$v/skills/.shared/scripts"
done
assert_eq "$h/plugins/cache/agent-kit/agentkit/0.2.0/skills" "$(resolve_with "$h")" \
    'the highest version wins when several are installed'

# --- neither present: the documented default, not an error -----------------
h="$tmp/empty"
mkdir -p "$h"
assert_eq "$h/skills" "$(resolve_with "$h")" 'with nothing installed it names the standard path'

# --- zsh safety ------------------------------------------------------------
# Codex runs shell commands through $SHELL -lc, which is zsh on the target
# machine. An unmatched glob is a FATAL error in zsh, so a resolver written with
# a shell glob would abort the whole block on any machine with no plugin
# installed. This is why the resolver uses find, which matches its own pattern.
if command -v zsh > /dev/null 2>&1; then
    h="$tmp/zsh-empty"
    mkdir -p "$h"
    out=$(CODEX_HOME="$h" zsh -c "
        $(cat "$tmp/resolver.sh")
        printf '%s' \"\$agentkit\"
    " 2>&1)
    rc=$?
    assert_eq '0' "$rc" 'the resolver runs cleanly under zsh with nothing installed'
    assert_not_contains "$out" 'no matches found' 'and never trips zsh nomatch'
    assert_eq "$h/skills" "$out" 'and resolves identically under zsh'
else
    printf '  skip zsh checks: zsh not installed\n'
fi

# --- every SKILL.md invocation goes through the resolver -------------------
for f in "$skills"/*/SKILL.md; do
    name=$(basename "$(dirname "$f")")
    stale=$(grep -c 'codex_home' "$f" || true)
    assert_eq '0' "$stale" "$name has no invocation bypassing the resolver"
done

finish
