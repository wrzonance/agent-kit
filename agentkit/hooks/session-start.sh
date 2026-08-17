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

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

# The built plugin lays hooks and skills out as siblings under the plugin root,
# so the helper is always ../skills/ from here. Located by parameter expansion
# rather than readlink/dirname: a hook must still work on a PATH that resolves
# nothing. The guard covers an invocation by bare name, where %/* strips nothing.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || true

# The guard library is optional so SessionStart can fail open on a partial
# install. Keep the resolver-relative command only when its hint is available;
# otherwise retain the hook-relative path that works from the source layout.
resolve_hint=${RESOLVE_HINT-}
if [[ -n $resolve_hint ]]; then
    bootstrap_command="\"\$agentkit/.shared/scripts/bootstrap-repo.sh\""
else
    bootstrap_command="\"$self_dir/../skills/.shared/scripts/bootstrap-repo.sh\""
fi

# Shown when a repository has no .agent/config.env. Without it every
# evidence-gated guard stays inert and the skills fall back to probing, which
# looks identical to the tooling being broken -- the failure mode is silence, so
# the fix has to announce itself.
#
# The hook and skills are siblings in both the source and packaged layouts, so
# this path is stable without asking the agent to rediscover the plugin cache.
readonly ONBOARD_HINT="ACTION REQUIRED, before you do anything else: tell the user this repository is
not onboarded, and offer to onboard it now. Do not silently continue -- the
board, triage, and commit guards have no facts to act on and stay inert, which
is indistinguishable from the tooling being broken.

If the user agrees, use the onboard-repo skill. The script alone, if the user
would rather do it by hand (safe to inspect first with --dry-run):

${resolve_hint}
  ${bootstrap_command} --dry-run   # inspect
  ${bootstrap_command}             # then write
"

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

# True when a cached contract was written by the CLI now running. Unknown either
# way means "do not judge": re-probing costs a second, a wrong attribution
# outlives the session.
harness_matches() {
    local cached current
    cached=$(sed -n 's/^harness=[[:space:]]*name=\([^ ]*\).*/\1/p;/^harness=/q' <<< "$1")
    current=$("$self_dir/../skills/.shared/scripts/harness-id.sh" --name 2> /dev/null || true)
    # Fail CLOSED. This returned "match" when the cached contract carried no
    # harness= line at all, so a file that never came from our preflight -- which
    # always writes one -- passed the only check standing between a repository
    # and the model's context. Regenerating costs one preflight run.
    [[ -n $cached && -n $current ]] || return 1
    [[ $cached == "$current" ]]
}

checkout_identity() {
    local branch head
    branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2> /dev/null) ||
        branch=$(git -C "$root" symbolic-ref --short HEAD 2> /dev/null) || return 1
    [[ $branch == HEAD ]] && branch=detached
    head=$(git -C "$root" rev-parse HEAD 2> /dev/null) || return 1
    printf '%s\n%s' "$branch" "$head"
}

cache_matches_checkout() {
    local cached_branch cached_head current_branch current_head
    [[ $in_repo -eq 1 ]] || return 0
    cached_branch=$(sed -n 's/^branch=\([^[:space:]]*\).*/\1/p' <<< "$1")
    cached_head=$(sed -n 's/^head=\([^[:space:]]*\).*/\1/p' <<< "$1")
    [[ -z $cached_branch ]] && return 0
    current_branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2> /dev/null) ||
        current_branch=$(git -C "$root" symbolic-ref --short HEAD 2> /dev/null) || return 0
    if ! current_head=$(git -C "$root" rev-parse HEAD 2> /dev/null); then
        # An unnamed unborn HEAD has no branch or commit identity to compare;
        # preserve the pre-existing cache behavior for that state. A named
        # unborn branch can still invalidate a cache from another branch.
        [[ $current_branch == HEAD ]] && return 0
        [[ $cached_branch == "$current_branch" ]]
        return
    fi
    [[ $current_branch == HEAD ]] && current_branch=detached
    [[ $cached_branch == "$current_branch" && $cached_head == "$current_head" ]]
}

write_cached_contract() {
    local content=$1 dir tmp
    [[ $in_repo -eq 1 ]] || return 0
    guard_contract_is_ours "$contract_file" "$root" || return 0
    dir=${contract_file%/*}
    [[ -d $dir && ! -L $dir ]] || return 0
    tmp=$(mktemp -- "$dir/.env-contract.XXXXXX" 2> /dev/null) || return 0
    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f -- "$tmp" 2> /dev/null || true
        return 0
    fi
    chmod 600 -- "$tmp" 2> /dev/null || true
    if ! mv -f -- "$tmp" "$contract_file" 2> /dev/null; then
        rm -f -- "$tmp" 2> /dev/null || true
    fi
}

record_checkout_identity() {
    local identity head
    [[ $in_repo -eq 1 ]] || return 0
    identity=$(checkout_identity) || return 0
    head=${identity#*$'\n'}
    contract+=$'\nhead='$head' source=git rev-parse HEAD'
    write_cached_contract "$contract"
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
    guard_contract_is_ours "$contract_file" "$root" &&
    [[ -n $(find "$contract_file" -mmin "-$CONTRACT_MAX_AGE_MINUTES" 2> /dev/null) ]]; then
    candidate=$(cat -- "$contract_file" 2> /dev/null || true)
    if harness_matches "$candidate" && cache_matches_checkout "$candidate"; then
        contract=$candidate
    fi
fi

# Age is not the only way a contract goes stale. Its branch= and head= lines are
# checkout identity, while harness= is session identity, and the file is shared
# between every CLI that opens this repository,
# so a contract written by one and served to the other credits every commit to
# the wrong agent. Seen live: a contract written at 13:26 by one CLI was reused
# two minutes later by the other, which then reported itself as its peer.
if [[ -n $contract ]] && ! harness_matches "$contract"; then
    contract=''
fi

if [[ -z $contract ]]; then
    preflight="$self_dir/../skills/.shared/scripts/agent-preflight.sh"
    if [[ -x $preflight ]]; then
        # --measured-from hook, because that is the truth: this process runs
        # outside the agent's sandbox, so its writability probes and its
        # CODEX_* sandbox variables describe the hook and not the shell that
        # will run the commands. Without the flag the block asserts
        # writable=yes and active=no to an agent that is about to be denied.
        contract=$("$preflight" --worktree "$root" --measured-from hook 2> /dev/null || true)
        [[ -n $contract ]] && record_checkout_identity
    fi
fi
# An un-onboarded repository still gets a session context, even when the probe
# produced no contract -- that combination is exactly the un-onboarded case, and
# staying silent there is how the gap goes unnoticed for a whole session.
context=''
if [[ -n $contract ]]; then
    context="Environment contract (established; do not re-probe, EXCEPT any line
marked measured-by=hook -- those were probed outside your sandbox, so a denial
you hit yourself overrides them):
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

# Onboarded repositories get one bounded drift probe. The helper aggregates
# components, proposal toolchains, generator version, and CI gaps so this hook
# does not re-probe each axis independently.
if [[ $in_repo -eq 1 && -r $root/.agent/config.env ]]; then
    drift=$("$self_dir/../skills/.shared/scripts/onboard-refresh.sh" \
        --repo-root "$root" --summary 2> /dev/null || true)
    if [[ -n $drift && $drift != 'drift= none' ]]; then
        drift_notice="agentkit drift advisory: $drift; report this in your handoff; defer onboarding refresh during the current work because config.env mutation is an operator/trunk decision."
        if [[ -n $context ]]; then
            context+=$'\n\n'
        fi
        context+=$drift_notice
    fi
fi

# additionalContext reaches only the MODEL. Asked to run ls, a model that was
# handed the onboarding notice ran ls and said nothing -- correctly, from its
# point of view. systemMessage is the channel aimed at the person, so the notice
# goes to both and neither depends on the other relaying it.
human=''
if [[ $in_repo -eq 1 && ! -r $root/.agent/config.env ]]; then
    human="agentkit: this repository is not onboarded (.agent/config.env is absent), so the
board, triage and commit guards are inert. Ask the agent to onboard it -- it has an onboard-repo skill that also fills in
the verify commands -- or run:
${resolve_hint}
  ${bootstrap_command}"
elif [[ $in_repo -eq 0 ]]; then
    human='agentkit: this session did not start inside a git repository, so repository-scoped
guards and the end-of-turn verification check are inert.'
fi

[[ -n $context$human ]] || emit_empty

jq -nc --arg ctx "$context" --arg msg "$human" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}
     + (if $msg == "" then {} else {systemMessage:$msg} end)'
exit 0
