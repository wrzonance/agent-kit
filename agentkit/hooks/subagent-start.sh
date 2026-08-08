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
[[ ! -r $contract_file ]] || contract=$(cat -- "$contract_file" 2> /dev/null || true)

context=''
[[ -z $contract ]] || context="Environment contract inherited from the orchestrator (do not re-probe):
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
