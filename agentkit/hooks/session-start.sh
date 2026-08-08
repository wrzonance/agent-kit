#!/usr/bin/env bash
# SessionStart -> the environment contract as additionalContext, so it is present
# before turn one instead of costing a tool call.
#
# NEVER exits non-zero: a hook that exits 2 halts the agent instead of informing
# it. Context hooks fail open -- no contract simply means no additionalContext.
set -uo pipefail

emit_empty() { printf '{}\n'; exit 0; }
trap 'emit_empty' ERR

readonly CONTRACT_MAX_AGE_MINUTES=30

# Shown when a repository has no .agent/config.env. Without it every
# evidence-gated guard stays inert and the skills fall back to probing, which
# looks identical to the tooling being broken -- the failure mode is silence, so
# the fix has to announce itself.
#
# Single-quoted deliberately: every $ below is literal text for the agent to read
# and retype. Expanding it here would bake this machine's paths into the advice.
# shellcheck disable=SC2016
readonly ONBOARD_HINT='ACTION REQUIRED, before you do anything else: tell the user this repository is
not onboarded, and offer to onboard it now. Do not silently continue -- the
board, triage, and commit guards have no facts to act on and stay inert, which
is indistinguishable from the tooling being broken.

If the user agrees, run this from the repository root (it is safe to inspect
first with --dry-run, and it writes only .agent/ and .gitignore):

  agentkit=$(find "${CODEX_HOME:-$HOME/.codex}/plugins/cache" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" -maxdepth 4 \
    -type d -path "*/agentkit/*/skills" 2>/dev/null | sort | tail -1)
  [ -n "$agentkit" ] || agentkit="${CODEX_HOME:-$HOME/.codex}/skills"
  "$agentkit/.shared/scripts/bootstrap-repo.sh" --dry-run   # inspect
  "$agentkit/.shared/scripts/bootstrap-repo.sh"             # then write

It writes two files the repository is expected to commit:
  .agent/config.env   repo slug, trunk branch, board number, Status vocabulary
  .agent/board.json   board node ids, so a status move costs one call not seven
and the .gitignore rules that keep everything else under .agent/ out of history.

Then declare this repository verify commands in .agent/config.env as
AGENT_CMD_<NAME>=<command>. Skills invoke them by name, so none of them assume
a toolchain. Consult the agentkit README for the full contract.'

# Shown when the session did not start inside a repository at all. Work can
# still be directed at one from here, and the guards do follow a command that
# names its target -- but the environment contract above describes THIS
# directory, and the end-of-turn verification check has no tree to watch. Say so
# rather than let a session run on facts about the wrong directory.
readonly NO_REPO_HINT='This session did not start inside a git repository, so the contract above
describes the launch directory and not any repository you may be asked to work
on. Repository-scoped guards follow a command that names its target, in the
form "cd <repo> && ..." or "git -C <repo> ...", but the end-of-turn
verification check has no working tree to watch and stays inert.

If the work targets a repository, prefer starting the session inside it.'

# The built plugin lays hooks and skills out as siblings under the plugin root,
# so the helper is always ../skills/ from here. Located by parameter expansion
# rather than readlink/dirname: a hook must still work on a PATH that resolves
# nothing. The guard covers an invocation by bare name, where %/* strips nothing.
self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || true


# True when a cached contract was written by the CLI now running. Unknown either
# way means "do not judge": re-probing costs a second, a wrong attribution
# outlives the session.
harness_matches() {
    local cached current
    cached=$(sed -n 's/^harness=[[:space:]]*name=\([^ ]*\).*/\1/p' <<< "$1" | head -1)
    current=$("$self_dir/../skills/.shared/scripts/harness-id.sh" --name 2> /dev/null || true)
    [[ -n $cached && -n $current ]] || return 0
    [[ $cached == "$current" ]]
}

input=$(cat 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
source_kind=$(jq -r '.source // "startup"' <<< "$input" 2> /dev/null || true)
session_id=$(jq -r '.session_id // empty' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || emit_empty

# Whether this IS a repository is tracked separately from where its root is: the
# onboarding notice must not fire in a plain directory, where bootstrapping is
# not a thing that can succeed.
in_repo=1
root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null) || { in_repo=0; root=$cwd; }
contract_file="$root/.agent/env-contract.txt"
contract=''

# Reuse a recent contract: the preflight probes gh, and this fires every session.
# Compaction is the exception -- it is precisely when this context was lost.
if [[ $source_kind != compact && -r $contract_file ]] &&
    [[ -n $(find "$contract_file" -mmin "-$CONTRACT_MAX_AGE_MINUTES" 2> /dev/null) ]]; then
    contract=$(cat -- "$contract_file" 2> /dev/null || true)
fi

# Age is not the only way a contract goes stale. Its harness= line is SESSION
# identity, and the file is shared between every CLI that opens this repository,
# so a contract written by one and served to the other credits every commit to
# the wrong agent. Seen live: a contract written at 13:26 by one CLI was reused
# two minutes later by the other, which then reported itself as its peer.
if [[ -n $contract ]] && ! harness_matches "$contract"; then
    contract=''
fi

if [[ -z $contract ]]; then
    preflight="$self_dir/../skills/.shared/scripts/agent-preflight.sh"
    if [[ -x $preflight ]]; then
        contract=$("$preflight" --worktree "$root" 2> /dev/null || true)
    fi
fi
# An un-onboarded repository still gets a session context, even when the probe
# produced no contract -- that combination is exactly the un-onboarded case, and
# staying silent there is how the gap goes unnoticed for a whole session.
context=''
if [[ -n $contract ]]; then
    context="Environment contract (established; do not re-probe):
$contract"
fi

# Compaction is exactly when an injected lesson was summarised away, so the
# once-per-session advisories are re-armed here. Session-scoped, so it clears
# only this session's claims.
if [[ $source_kind == compact && -n $session_id ]]; then
    rm -rf -- "$root/.agent/cache/brief/${session_id//[^A-Za-z0-9._-]/_}" 2> /dev/null || true
fi

# Old claims from sessions long gone. Cosmetic, but this sits next to committed
# files and should not accumulate.
if [[ -d $root/.agent/cache/brief ]]; then
    find "$root/.agent/cache/brief" -maxdepth 1 -mindepth 1 -type d -mtime +7 \
        -exec rm -rf -- {} + 2> /dev/null || true
fi

notice=''
if [[ $in_repo -eq 0 ]]; then
    notice=$NO_REPO_HINT
elif [[ ! -r $root/.agent/config.env ]]; then
    notice=$ONBOARD_HINT
else
    # An onboarded repository gets the tooling contract. An un-onboarded one
    # gets the notice above instead: naming board helpers to a repository with
    # no board declaration would teach a command that cannot work there.
    notice=$(guard_curriculum "$self_dir/../skills" 2> /dev/null || true)
fi

if [[ -n $notice ]]; then
    if [[ -n $context ]]; then
        context+=$'\n\n'
    fi
    context+=$notice
fi

# additionalContext reaches only the MODEL. Asked to run ls, a model that was
# handed the onboarding notice ran ls and said nothing -- correctly, from its
# point of view. systemMessage is the channel aimed at the person, so the notice
# goes to both and neither depends on the other relaying it.
human=''
if [[ $in_repo -eq 1 && ! -r $root/.agent/config.env ]]; then
    human="agentkit: this repository is not onboarded (.agent/config.env is absent), so the
board, triage and commit guards are inert. Ask the agent to onboard it, or run:
  \"\$(find \"\${CODEX_HOME:-\$HOME/.codex}/plugins/cache\" \"\${CLAUDE_CONFIG_DIR:-\$HOME/.claude}/plugins/cache\" -maxdepth 4 -type d -path '*/agentkit/*/skills' 2>/dev/null | sort | tail -1)/.shared/scripts/bootstrap-repo.sh\""
elif [[ $in_repo -eq 0 ]]; then
    human='agentkit: this session did not start inside a git repository, so repository-scoped
guards and the end-of-turn verification check are inert.'
fi

[[ -n $context$human ]] || emit_empty

jq -nc --arg ctx "$context" --arg msg "$human" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}
     + (if $msg == "" then {} else {systemMessage:$msg} end)'
exit 0
