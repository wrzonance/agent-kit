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

input=$(cat 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || emit_empty

root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || printf '%s' "$cwd")
contract_file="$root/.agent/env-contract.txt"
[[ -r $contract_file ]] || emit_empty
contract=$(cat -- "$contract_file" 2> /dev/null || true)
[[ -n $contract ]] || emit_empty

jq -nc --arg ctx "Environment contract inherited from the orchestrator (do not re-probe):
$contract" \
    '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}'
exit 0
