#!/usr/bin/env bash
# Suite: the skill tree locates itself under BOTH install layouts.
#
# Packaging installs the tree in a versioned plugin cache:
# $CODEX_HOME/plugins/cache/<marketplace>/agentkit/<version>/skills. The
# contract-absent bootstrap searches that cache rather than guessing a local
# skills directory that may not be the installed plugin.
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

# Pull the contract-absent plugin-cache resolver out of the shipped markdown.
extract_resolver() {
    awk '
        /^[[:space:]]*agentkit=\$\(find / { capture = 1 }
        capture                    { print }
        /^    \[ -n "\$agentkit" \]/ { if (capture) exit }
    ' "$skills/onboard-repo/SKILL.md"
}

extract_onboard_step_zero() {
    awk '
        /^agentkit=/ { capture = 1 }
        capture && /^```$/ { exit }
        capture { print }
    ' "$skills/onboard-repo/SKILL.md"
}

resolver=$(extract_resolver)
printf '%s\n' "$resolver" > "$tmp/resolver.sh"
assert_contains "$resolver" 'plugins/cache' 'the shipped resolver looks in the plugin location'
assert_contains "$resolver" 'agentkit' 'and names the plugin directory'
assert_contains "$resolver" 'sort -V | tail -1' 'the resolver chooses the highest installed version'
assert_contains "$resolver" 'agentkit is not installed in searched plugin caches' \
    'an empty plugin-cache search fails explicitly'
# shellcheck disable=SC2016 # this is the literal fallback spelling to reject
assert_not_contains "$resolver" 'agentkit="${CODEX_HOME:-$HOME/.codex}/skills"' \
    'the resolver has no standalone skills-path fallback'

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

# --- neither cache present: explicit installation failure -------------------
cx="$tmp/empty"; cl="$tmp/empty-cl"
mkdir -p "$cx" "$cl"
empty_out=''
empty_rc=0
empty_out=$(CODEX_HOME="$cx" CLAUDE_CONFIG_DIR="$cl" bash -c "
    set -uo pipefail
    $(cat "$tmp/resolver.sh")
    printf '%s' \"\$agentkit\"
" 2>&1) || empty_rc=$?
if ((empty_rc != 0)); then
    _pass 'an empty plugin-cache search fails nonzero'
else
    _fail 'an empty plugin-cache search fails nonzero' "want nonzero rc" "got: $empty_rc"
fi
assert_contains "$empty_out" 'agentkit is not installed in searched plugin caches' \
    'the empty plugin-cache failure explains remediation'

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

# A contract-absent checkout discovers the highest installed plugin version.
contract_repo="$tmp/contract-absent-repo"
contract_home="$tmp/contract-absent-home"
contract_plugin=$(plugin_layout "$contract_home" 0.2.0)
mkdir -p "$contract_repo/.agent" "$contract_plugin/.shared/scripts" \
    "$(plugin_layout "$contract_home" 0.1.0)/.shared/scripts"
git -C "$contract_repo" init -q
resolved=''
rc=0
resolved=$(cd "$contract_repo" && \
    CODEX_HOME="$contract_home" CLAUDE_CONFIG_DIR="$tmp/contract-absent-claude" \
    bash -c "$(cat "$tmp/resolver.sh"); printf '%s' \"\$agentkit\"") || rc=$?
assert_eq '0' "$rc" 'contract-absent resolver exits successfully'
assert_eq "$contract_plugin" "$resolved" \
    'contract-absent resolver selects the highest discovered plugin path'

# A readable, owned, untracked contract can still be incomplete. In that case
# onboarding must use its sole contract-absent plugin-cache bootstrap rather
# than treating the empty skills path as resolved.
onboard_step_zero=$(extract_onboard_step_zero)
printf '%s\n' "$onboard_step_zero" > "$tmp/onboard-step-zero.sh"
malformed_repo="$tmp/malformed-contract-repo"
malformed_home="$tmp/malformed-contract-home"
malformed_plugin=$(plugin_layout "$malformed_home" 0.3.0)
mkdir -p "$malformed_repo/.agent" "$malformed_plugin/.shared/scripts/lib"
git -C "$malformed_repo" init -q
printf '%s\n' 'repo=example-org/example-repo' > "$malformed_repo/.agent/env-contract.txt"
cp "$skills/.shared/scripts/contract-read.sh" "$malformed_plugin/.shared/scripts/contract-read.sh"
cp "$skills/.shared/scripts/lib/contract-cache.sh" "$malformed_plugin/.shared/scripts/lib/contract-cache.sh"
# shellcheck disable=SC2016 # writes the fixture's literal helper program
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -eu' \
    'worktree=' \
    'while (($#)); do case $1 in --worktree) worktree=$2; shift 2 ;; *) shift ;; esac; done' \
    '[ -n "$worktree" ]' \
    'mkdir -p "$worktree/.agent/cache"' \
    "printf '%s\\n' 'skills= path=$malformed_plugin' > \"\$worktree/.agent/env-contract.txt\"" \
    > "$malformed_plugin/.shared/scripts/agent-preflight.sh"
chmod +x "$malformed_plugin/.shared/scripts/agent-preflight.sh"
resolved=''
rc=0
resolved=$(cd "$malformed_repo" && \
    CODEX_HOME="$malformed_home" CLAUDE_CONFIG_DIR="$tmp/malformed-contract-claude" \
    bash -c "$(cat "$tmp/onboard-step-zero.sh"); printf '%s' \"\$agentkit\"") || rc=$?
assert_eq 0 "$rc" 'an incomplete contract falls back to plugin discovery'
assert_eq "$malformed_plugin" "$resolved" \
    'an incomplete contract selects the discovered plugin path'
assert_eq yes "$(test -f "$malformed_repo/.agent/cache/contract-session.env" && printf yes || printf no)" \
    'contract-absent bootstrap warms the session context after preflight'

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
    if ((rc != 0)); then
        _pass 'the zsh empty-cache resolver fails nonzero'
    else
        _fail 'the zsh empty-cache resolver fails nonzero' 'want nonzero rc' "got: $rc"
    fi
    assert_not_contains "$out" 'no matches found' 'and never trips zsh nomatch'
    assert_contains "$out" 'agentkit is not installed in searched plugin caches' \
        'and explains the empty-cache remediation under zsh'
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
