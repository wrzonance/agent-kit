#!/usr/bin/env bash
# PostToolUse -> teach after the fact. Structurally incapable of blocking.
#
# The command has already run and returned real data by the time this fires, so
# the agent pays for the call it wanted once and knows the cheaper route before
# the second. That is the whole design: no guard has to choose between teaching a
# lesson and letting the work proceed.
#
# Rests on one MEASURED fact: PostToolUse additionalContext reaches the model.
# Given a code word through this channel and then asked for it while forbidden
# from using any tool, a live agent returned it exactly. The runtime keeps this
# field distinct from systemMessage, which was not shown to reach the model and
# is not used here.
#
# NEVER exits non-zero, and never emits a decision of any kind.
set -uo pipefail

emit_empty() { printf '{}\n'; exit 0; }
trap 'emit_empty' ERR

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || emit_empty

# The literal "$agentkit/..." in every lesson is text for the agent to read and
# retype. Expanding it would resolve against this hook's environment and hand
# back a path instead of the resolver.
teach() {
    jq -nc --arg ctx "$1" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}'
    exit 0
}

input=$(cat 2> /dev/null || true)
command_line=$(jq -r '.tool_input.command // empty' <<< "$input" 2> /dev/null || true)
cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
session=$(jq -r '.session_id // empty' <<< "$input" 2> /dev/null || true)
[[ -n $command_line ]] || emit_empty

guard_resolve_roots "$cwd" "$command_line"
((${#roots[@]})) || emit_empty
state_root=$(guard_state_root)

# Board discovery. Both helpers are named: offered only a status-mover, an agent
# that was trying to READ the board hand-rolled its own GraphQL query instead.
if guard_has_evidence .agent/board.json &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+project[[:space:]]+(list|item-list|field-list)' \
        <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" board-read; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "This repository declares its board in .agent/board.json, so its ids do not
need discovering. Next time:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"          # to READ the board
  \"\$agentkit/parallel-issues/scripts/move-github-project-item.sh\"  # to move an item
Each resolves the ids from that file in a single call, in place of about seven."
fi

# Per-issue triage. Reading ONE issue body is legitimate and stays that way --
# the digest deliberately omits bodies. What this replaces is walking every issue
# one call at a time.
if guard_has_evidence .agent/config.env &&
    grep -qE '(^|[[:space:];&|])gh[[:space:]]+(api[[:space:]]+[^[:space:]]*/timeline|issue[[:space:]]+view)' \
        <<< "$command_line" &&
    guard_should_advise "$state_root" "$session" issue-triage; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Triaging issues one call at a time is replaced by one query:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/triage-issues.sh\"
It returns board status and cross-referenced pull requests for every candidate
together. Reading a single issue body directly is still the right call -- the
digest does not carry bodies."
fi

# Blanket staging. Correct ignore rules are what actually protect .agent/; this
# is a nudge toward the helper, and it gates nothing.
if grep -qE '(^|[[:space:];&|])git[[:space:]]+add[[:space:]]+(-A|--all|\.)([[:space:]]|$)' \
    <<< "$(guard_strip_git_globals "$command_line")" &&
    guard_should_advise "$state_root" "$session" staging; then
    # shellcheck disable=SC2016  # literal text, see teach()
    teach "Blanket staging sweeps up .agent/ working state -- the environment contract
carries local paths and an account name. Ignore rules are the real protection
(bootstrap-repo.sh writes them); to stage and commit a worktree's own changes:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/worktree-commit.sh\""
fi

emit_empty
