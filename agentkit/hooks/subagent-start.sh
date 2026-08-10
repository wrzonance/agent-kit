#!/usr/bin/env bash
# SubagentStart -> the same environment contract, injected into every spawned
# worker. The skill currently instructs the agent to paste this verbatim into
# each worker prompt; an instruction can be forgotten, a hook cannot.
#
# Reads only the file the parent already wrote -- it performs no probe of its own.
# NEVER exits non-zero.
set -uo pipefail

emit_empty() { printf '{}\n'; exit 0; }
trap 'emit_empty' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || true

input=$(cat 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || emit_empty

root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || printf '%s' "$cwd")
contract_file="$root/.agent/env-contract.txt"
contract=''
# Same provenance gate as SessionStart, and a worker needs it more: it inherits
# this as authoritative context with no session history to weigh it against, and
# it is the agent least able to notice that its instructions arrived from the
# repository it is working on.
if [[ -r $contract_file ]] && guard_contract_is_ours "$contract_file" "$root"; then
    contract=$(cat -- "$contract_file" 2> /dev/null || true)
fi

# A contract written by the OTHER CLI names the wrong agent, and a worker has no
# way to notice. Dropping it costs the worker its inherited context; serving it
# would have the worker credit its commits to a CLI it is not running in.
if [[ -n $contract ]]; then
    # `| head -1` closes the pipe early, and under pipefail sed's SIGPIPE became
    # the hook's exit status (141) -- a hook that must never exit non-zero.
    cached=$(sed -n 's/^harness=[[:space:]]*name=\([^ ]*\).*/\1/p;/^harness=/q' <<< "$contract")
    current=$("$self_dir/../skills/.shared/scripts/harness-id.sh" --name 2> /dev/null || true)
    # Fail closed: our preflight always writes a harness= line, so a contract
    # without one did not come from it.
    if [[ -z $cached || -z $current || $cached != "$current" ]]; then
        contract=''
    fi
fi

context=''
[[ -z $contract ]] || context="Environment contract inherited from the orchestrator (do not
re-probe, EXCEPT any line marked measured-by=hook -- those were probed outside
your sandbox, so a denial you hit yourself overrides them):
$contract"

# A worker gets the tooling contract too, and this is the ONLY way it can. It
# never sees the parent's session context, and it is the agent least able to
# recover from a wrong guess -- nobody is watching it to rephrase.
if [[ -r $root/.agent/config.env ]]; then
    curriculum=$(guard_curriculum "$self_dir/../skills" 2> /dev/null || true)
    if [[ -n $curriculum ]]; then
        [[ -z $context ]] || context+=$'\n\n'
        context+=$curriculum
    fi
fi

[[ -n $context ]] || emit_empty

jq -nc --arg ctx "$context" \
    '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}'
exit 0
