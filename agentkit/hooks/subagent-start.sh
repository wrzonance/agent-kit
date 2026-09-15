#!/usr/bin/env bash
# SubagentStart -> role-specific context, without root helper interfaces.
# Only the dispatcher knows a worker's worktree; facts travel in its prompt.
#
# The payload's cwd is used only to find the repository's onboarding gate.
# NEVER exits non-zero.
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

# The event's explicit role selects context, never model/cwd/tool availability.
if [[ -r $root/.agent/config.env ]]; then
    curriculum=$(guard_subagent_curriculum "$self_dir/../skills" "$role" 2> /dev/null || true)
    if [[ -n $curriculum ]]; then
        [[ -z $context ]] || context+=$'\n\n'
        context+=$curriculum
    fi
fi

[[ -n $context ]] || emit_empty

jq -nc --arg ctx "$context" \
    '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$ctx}}'
exit 0
