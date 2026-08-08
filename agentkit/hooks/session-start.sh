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

# The built plugin lays hooks and skills out as siblings under the plugin root,
# so the helper is always ../skills/ from here. Located by parameter expansion
# rather than readlink/dirname: a hook must still work on a PATH that resolves
# nothing. The guard covers an invocation by bare name, where %/* strips nothing.
self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

input=$(cat 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
source_kind=$(jq -r '.source // "startup"' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || emit_empty

root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || printf '%s' "$cwd")
contract_file="$root/.agent/env-contract.txt"
contract=''

# Reuse a recent contract: the preflight probes gh, and this fires every session.
# Compaction is the exception -- it is precisely when this context was lost.
if [[ $source_kind != compact && -r $contract_file ]] &&
    [[ -n $(find "$contract_file" -mmin "-$CONTRACT_MAX_AGE_MINUTES" 2> /dev/null) ]]; then
    contract=$(cat -- "$contract_file" 2> /dev/null || true)
fi

if [[ -z $contract ]]; then
    preflight="$self_dir/../skills/.shared/scripts/agent-preflight.sh"
    if [[ -x $preflight ]]; then
        contract=$("$preflight" --worktree "$root" 2> /dev/null || true)
    fi
fi
[[ -n $contract ]] || emit_empty

jq -nc --arg ctx "Environment contract (established; do not re-probe):
$contract" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
exit 0
