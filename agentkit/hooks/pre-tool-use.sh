#!/usr/bin/env bash
# PreToolUse -> one denial, for the one command that cannot succeed.
#
# Everything else is taught by PostToolUse AFTER the command has run and returned
# real data (see post-tool-use.sh). A measured runtime fact makes that possible:
# PostToolUse additionalContext reaches the model. So a guard no longer has to
# choose between teaching a lesson and letting the work proceed.
#
# That matters most where nobody is watching. A blocked main session has a human
# who can rephrase; a blocked worker is a dead branch, silently. This hook is
# therefore silent on every rule that has an alternative, which makes it
# structurally unable to halt autonomous work.
#
# Never exit 2 and never updatedInput: exit 2 halts the agent instead of
# informing it, and a rewrite hides the lesson a reason teaches.
set -uo pipefail

# Allow == say nothing. VERIFIED AGAINST THE RUNTIME, NOT THE SCHEMA: the JSON
# Schema embedded in the codex binary lists permissionDecision as
# ["allow","deny","ask"], but codex 0.147 rejects the allow value outright --
# `PreToolUse hook returned unsupported permissionDecision:allow` -- on EVERY
# tool call. An empty object is the correct way to express "no opinion".
#
# The schema fixtures verify output SHAPE; they are not a statement of what the
# runtime accepts. Only an interactive session proved this.
allow() { printf '{}\n'; exit 0; }
trap 'allow' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || allow

# The reason is single-quoted deliberately. The "$agentkit/..." form inside is
# literal text for the agent to read and type; expanding it here would resolve it
# against the hook's own environment and hand back a path instead of the lesson.
deny() {
    jq -nc --arg r "$1" \
        '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
          permissionDecisionReason:$r}}'
    exit 0
}

input=$(cat 2> /dev/null || true)
command_line=$(jq -r '.tool_input.command // empty' <<< "$input" 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
session=$(jq -r '.session_id // empty' <<< "$input" 2> /dev/null || true)
[[ -n $command_line ]] || allow

# A bare helper invocation. Nothing in the tree is on PATH, so this is a
# guaranteed "command not found" that the agent then recovers from by guessing a
# location. Letting it run would teach the same lesson one call later, so the
# denial is the cheaper path -- and unlike the rules that moved to PostToolUse,
# there is no result being withheld, because there would not have been one.
#
# Matched in COMMAND POSITION only -- start of line or after a separator,
# allowing an interpreter prefix, because `bash agent-run.sh` fails the same way.
# Any whitespace used to qualify, which denied ARGUMENT-position mentions too:
# `find ... -name agent-run.sh`, `command -v agent-run.sh`, `grep -rn
# agent-run.sh` -- the very commands that LOCATE the helper, and the shape this
# rule's own message invites. A live session burned two calls on it and then
# abandoned the shell entirely.
#
# This deliberately under-blocks (`x=$(agent-run.sh)` slips through). A false
# deny costs a call and teaches the wrong lesson; a missed deny costs one
# "command not found" that the agent corrects unaided.
# The denial fires ONCE per session, and the message says so. Without that
# promise -- and without the code that keeps it -- a two-stage guard collapses
# into a halt: denied once, a live agent answered "It was not run" and stopped
# rather than adapting.
if grep -qE "(^|[;&|])[[:space:]]*((sudo|bash|sh|env)[[:space:]]+)*($HELPERS)\.sh([[:space:]]|$)" \
    <<< "$command_line"; then
    guard_resolve_roots "$cwd" "$command_line"
    if guard_should_deny "$(guard_state_root)" "$session" helper-path; then
        # shellcheck disable=SC2016  # literal text, see deny()
        deny "Helper scripts are not on PATH, and the tree MOVES when installed as a
plugin. Resolve it first:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/<script>.sh\" ...
If this exact command is what the task needs, run it again -- it will be allowed."
    fi
fi

allow
