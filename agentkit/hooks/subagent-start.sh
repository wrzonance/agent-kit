#!/usr/bin/env bash
# SubagentStart -> worktree-independent tooling curriculum for every spawned
# worker. Only the dispatcher knows a worker's worktree, so its per-worktree
# environment contract travels through the worker prompt instead.
#
# The payload's cwd is used only to find the repository's onboarding gate.
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
context=''

# A worker gets the tooling curriculum too, and this is the only worktree-
# independent channel that can reach it. It never sees the parent's session
# context, so the dispatcher must paste its authoritative contract separately.
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
