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
# shellcheck source=../agentkit/hooks/lib/guard-lib.sh
source "$root/agentkit/hooks/lib/guard-lib.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Pull the single contract-absent fallback resolver out of the shipped
# markdown: the `agentkit=$(find ...)` continuation and standalone fallback
# inside the contract-absent branch.
extract_resolver() {
    awk '
        /^[[:space:]]*agentkit=\$\(find / { capture = 1 }
        capture                    { print }
        /^    \[ -n "\$agentkit" \]/ { if (capture) exit }
    ' "$skills/onboard-repo/SKILL.md"
}

resolver=$(extract_resolver)
printf '%s\n' "$resolver" > "$tmp/resolver.sh"
assert_contains "$resolver" 'plugins/cache' 'the shipped resolver looks in the plugin location'
assert_contains "$resolver" 'agentkit' 'and names the plugin directory'
assert_eq '3' "$(printf '%s\n' "$resolver" | grep -c .)" 'the fallback resolver is three lines'

# Run the extracted resolver against synthetic harness homes and print what it
# chose. BOTH are set every time: the resolver must not depend on one harness's
# variable being present, and a session on either CLI sets only its own.
resolve_with() {
    local codex_home=$1 claude_home=$2
    CODEX_HOME="$codex_home" CLAUDE_CONFIG_DIR="$claude_home" bash -c "
        set -uo pipefail
        $(cat "$tmp/resolver.sh")
        printf '%s' \"\$agentkit\"
    " 2>/dev/null
}

plugin_layout() { printf '%s/plugins/cache/agent-kit/agentkit/%s/skills' "$1" "${2:-0.1.0}"; }

# --- Codex only ------------------------------------------------------------
cx="$tmp/cx"; cl="$tmp/cl-empty"
mkdir -p "$(plugin_layout "$cx")/.shared/scripts" "$cl"
assert_eq "$(plugin_layout "$cx")" "$(resolve_with "$cx" "$cl")" \
    'a Codex plugin install resolves'

# --- Claude Code only ------------------------------------------------------
# Claude Code uses the SAME cache layout under its own config dir, so only the
# search root differs. Before this, every helper invocation in every SKILL.md
# looked under CODEX_HOME alone and resolved to nothing on a Claude-only machine.
cx="$tmp/cx-empty"; cl="$tmp/cl"
mkdir -p "$(plugin_layout "$cl")/.shared/scripts" "$cx"
assert_eq "$(plugin_layout "$cl")" "$(resolve_with "$cx" "$cl")" \
    'a Claude Code plugin install resolves'

# --- both harnesses installed ----------------------------------------------
# The realistic case for someone running both. Either answer is correct -- same
# plugin, same content -- so what is asserted is that it picks ONE that exists,
# deterministically, rather than concatenating or failing.
cx="$tmp/both-cx"; cl="$tmp/both-cl"
mkdir -p "$(plugin_layout "$cx")/.shared/scripts" "$(plugin_layout "$cl")/.shared/scripts"
picked=$(resolve_with "$cx" "$cl")
assert_eq 'yes' "$([[ -d $picked/.shared/scripts ]] && echo yes || echo no)" \
    'with both harnesses installed it picks a tree that exists'
assert_eq "$picked" "$(resolve_with "$cx" "$cl")" 'and picks the same one every time'

# --- several versions: the newest wins -------------------------------------
cx="$tmp/versions"; cl="$tmp/versions-cl"
mkdir -p "$cl"
for v in 0.1.0 0.2.0; do
    mkdir -p "$(plugin_layout "$cx" "$v")/.shared/scripts"
done
assert_eq "$(plugin_layout "$cx" 0.2.0)" "$(resolve_with "$cx" "$cl")" \
    'the highest version wins when several are installed'

# --- standalone layout (pre-plugin, still supported) -----------------------
cx="$tmp/standalone"; cl="$tmp/standalone-cl"
mkdir -p "$cx/skills/.shared/scripts" "$cl"
assert_eq "$cx/skills" "$(resolve_with "$cx" "$cl")" 'a standalone install still resolves'

# --- neither present: the documented default, not an error -----------------
cx="$tmp/empty"; cl="$tmp/empty-cl"
mkdir -p "$cx" "$cl"
assert_eq "$cx/skills" "$(resolve_with "$cx" "$cl")" 'with nothing installed it names the standard path'

# --- a missing harness home is not an error --------------------------------
# Someone who has never run the other CLI has no directory for it at all. find
# reports that on stderr and carries on; if that leaked, every invocation would
# print a spurious error into the agent's transcript.
cx="$tmp/one-only"
mkdir -p "$(plugin_layout "$cx")/.shared/scripts"
err=$(CODEX_HOME="$cx" CLAUDE_CONFIG_DIR="$tmp/does-not-exist" bash -c "
    set -uo pipefail
    $(cat "$tmp/resolver.sh")
    printf '%s' \"\$agentkit\"
" 2>&1 >/dev/null)
assert_eq '' "$err" 'an absent harness home produces no error output'

# A contract-absent checkout still has to keep the installed plugin path after
# contract-read.sh reports that there is no contract to read. This is the
# resolver boundary: the bootstrap path is valid even though the optional
# contract-derived value is empty.
contract_repo="$tmp/contract-absent-repo"
contract_home="$tmp/contract-absent-home"
contract_plugin=$(plugin_layout "$contract_home")
mkdir -p "$contract_repo/.agent" "$contract_plugin/.shared/scripts"
git -C "$contract_repo" init -q
cp -- "$root/agentkit/skills/.shared/scripts/contract-read.sh" \
    "$contract_plugin/.shared/scripts/contract-read.sh"
chmod +x -- "$contract_plugin/.shared/scripts/contract-read.sh"
resolved=''
rc=0
resolved=$(cd "$contract_repo" && \
    CODEX_HOME="$contract_home" CLAUDE_CONFIG_DIR="$tmp/contract-absent-claude" \
    bash -c "$RESOLVE_HINT; printf '%s' \"\$agentkit\"") || rc=$?
assert_eq '0' "$rc" 'contract-absent resolver exits successfully'
assert_eq "$contract_plugin" "$resolved" \
    'contract-absent resolver preserves the discovered plugin skills path'

# --- zsh safety ------------------------------------------------------------
# Codex runs shell commands through $SHELL -lc, which is zsh on the target
# machine. An unmatched glob is a FATAL error in zsh, so a resolver written with
# a shell glob would abort the whole block on any machine with no plugin
# installed. This is why the resolver uses find, which matches its own pattern.
if command -v zsh > /dev/null 2>&1; then
    cx="$tmp/zsh-empty"; cl="$tmp/zsh-empty-cl"
    mkdir -p "$cx" "$cl"
    out=$(CODEX_HOME="$cx" CLAUDE_CONFIG_DIR="$cl" zsh -c "
        $(cat "$tmp/resolver.sh")
        printf '%s' \"\$agentkit\"
    " 2>&1)
    rc=$?
    assert_eq '0' "$rc" 'the resolver runs cleanly under zsh with nothing installed'
    assert_not_contains "$out" 'no matches found' 'and never trips zsh nomatch'
    assert_eq "$cx/skills" "$out" 'and resolves identically under zsh'
else
    printf '  skip zsh checks: zsh not installed\n'
fi

# --- SessionStart onboarding advice follows the installed resolver ----------
# Exercise the hook from the layout users actually install. Running the source
# checkout would hide the defect because its self-relative path is not under a
# plugin cache.
installed="$tmp/codex/plugins/cache/agent-kit/agentkit/0.1.0"
mkdir -p "$installed"
cp -a "$root/agentkit/hooks" "$installed/hooks"
cp -a "$root/agentkit/skills" "$installed/skills"

unboarded="$tmp/unboarded"
mkdir -p "$unboarded/.agent"
git init -q "$unboarded"
session_input() {
    jq -nc --arg cwd "$1" \
        '{cwd:$cwd,source:"startup",session_id:"skill-path-resolution"}'
}

session_out=$(session_input "$unboarded" | \
    CODEX_HOME="$tmp/codex" CLAUDE_CONFIG_DIR="$tmp/claude" \
    "$installed/hooks/session-start.sh" 2>/dev/null)
session_ctx=$(jq -r '.hookSpecificOutput.additionalContext // ""' <<< "$session_out")
session_notice=$(sed -n '/ACTION REQUIRED/,$p' <<< "$session_ctx")
session_human=$(jq -r '.systemMessage // ""' <<< "$session_out")
pinned_path='plugins/cache/[^[:space:]]*agentkit/[0-9]'
bootstrap_cmd="\"\$agentkit/.shared/scripts/bootstrap-repo.sh\""

assert_contains "$session_notice" "$RESOLVE_HINT" \
    'SessionStart model advice emits the shared resolver verbatim'
assert_contains "$session_human" "$RESOLVE_HINT" \
    'SessionStart operator advice emits the shared resolver verbatim'
assert_contains "$session_notice" "$bootstrap_cmd --dry-run" \
    'model advice uses the resolver-relative inspect command'
assert_contains "$session_human" "$bootstrap_cmd" \
    'operator advice uses the resolver-relative write command'
assert_not_contains "$session_notice" 'hooks/../skills/.shared/scripts/bootstrap-repo.sh' \
    'model advice does not expose the hook-relative install path'
assert_not_contains "$session_human" 'hooks/../skills/.shared/scripts/bootstrap-repo.sh' \
    'operator advice does not expose the hook-relative install path'
if grep -qE "$pinned_path" <<< "$session_notice"; then
    _fail 'model advice does not teach a pinned plugin path' \
        "unexpected regex: $pinned_path"
else
    _pass 'model advice does not teach a pinned plugin path'
fi
if grep -qE "$pinned_path" <<< "$session_human"; then
    _fail 'operator advice does not teach a pinned plugin path' \
        "unexpected regex: $pinned_path"
else
    _pass 'operator advice does not teach a pinned plugin path'
fi

# --- every SKILL.md invocation goes through the resolver -------------------
for f in "$skills"/*/SKILL.md; do
    name=$(basename "$(dirname "$f")")
    stale=$(grep -c 'codex_home' "$f" || true)
    assert_eq '0' "$stale" "$name has no invocation bypassing the resolver"
done

finish
