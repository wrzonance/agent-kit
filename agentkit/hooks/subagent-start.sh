#!/usr/bin/env bash
# SubagentStart -> role-specific context, without root helper interfaces.
set -uo pipefail

emit_empty() { printf '{}\n'; exit 0; }
trap 'emit_empty' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-curriculum.sh
source "$self_dir/lib/guard-curriculum.sh" 2> /dev/null || true

input=$(cat 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
role=$(jq -r '.agent_type // empty' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || emit_empty

root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || printf '%s' "$cwd")
context=''

if [[ -r $root/.agent/config.env ]]; then
    curriculum=$(guard_subagent_curriculum "$self_dir/../skills" "$role" 2> /dev/null || true)
    if [[ -n $curriculum ]]; then
        context+=$curriculum
        context+=$'\nOn activation-mismatch, return the one `agentkit activation-blocked: {...}` line to root and stop probes. Do not invoke an orchestration workflow or child. Run only the root-delivered fresh acknowledgement, then resume this worker and worktree.'
    fi
fi

[[ -n $context ]] || emit_empty

jq -nc --arg ctx "$context" \
    '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}'
exit 0
