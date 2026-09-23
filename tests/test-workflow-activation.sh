#!/usr/bin/env bash
TEST_NAME=workflow-activation
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
skills=$(cd -- "$here/../agentkit/skills" && pwd -P)
wa="$skills/.shared/scripts/workflow-activation.sh"

repo=$(mktemp -d); trap 'rm -rf "$repo"' EXIT
git -C "$repo" init -q
install -d -m 700 "$repo/.agent"
session=probe-session-$$

hook() { # event tool json-tool-input [extra-json-fields]
    jq -nc --arg e "$1" --arg s "$session" --arg c "$repo" --arg t "$2" --argjson i "$3" \
        '{hook_event_name:$e, session_id:$s, cwd:$c, tool_name:$t, tool_input:$i}' | "$wa" hook
}

# Arm a pending record exactly as UserPromptSubmit does.
delivered=$(jq -nc --arg s "$session" --arg c "$repo" \
    '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:$c, prompt:"$agentkit:parallel-issues 1"}' | "$wa" hook)
assert_contains "$delivered" 'workflow-activation.sh ack' 'delivery names the receipt command'
receipt=$(ls "$repo/.agent/activation/"*.json)
assert_eq pending "$(jq -r .status "$receipt")" 'record starts pending'

out=$(hook PreToolUse Read "{\"file_path\":\"$skills/parallel-issues/SKILL.md\"}")
assert_eq '{}' "$out" 'pending: Read of the skill is allowed'
out=$(hook PreToolUse Bash '{"command":"git status --short"}')
assert_eq '{}' "$out" 'pending: an ordinary shell read is allowed'
out=$(hook PreToolUse Edit "{\"file_path\":\"$repo/notes.md\"}")
assert_eq '{}' "$out" 'pending: an edit is allowed (Codex does not enforce a deny for apply_patch anyway)'
out=$(hook PreToolUse apply_patch '{"patch":"*** Begin Patch\n*** End Patch"}')
assert_eq '{}' "$out" 'pending: apply_patch is allowed'

out=$(hook PreToolUse Bash '{"command":"git push -u origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: git push is denied'
out=$(hook PreToolUse Agent '{"prompt":"implement #1"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: spawning an agent is denied'
out=$(hook PreToolUse spawn_agent '{"prompt":"implement #1"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: Codex spawn_agent is denied'
out=$(hook PreToolUse Bash "{\"command\":\"$skills/parallel-issues/scripts/create-issue-worktree.sh --issue 1\"}")
assert_contains "$out" 'pending session acknowledgement' 'pending: worktree creation is denied'
out=$(hook PreToolUse Bash '{"command":"gh pr create --draft --title x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: opening a PR is denied'

# Promote, then everything is allowed.
nonce=$(jq -r .nonce "$receipt")
"$wa" ack --repo-root "$repo" --session "$session" --skill parallel-issues --nonce "$nonce" >/dev/null
assert_eq active "$(jq -r .status "$receipt")" 'ack promotes the record'
out=$(hook PreToolUse Bash '{"command":"git push -u origin fix/x"}')
assert_eq '{}' "$out" 'active: git push is allowed'

# No record at all: the cold-start contract.
session=cold-session-$$
out=$(hook PreToolUse Bash '{"command":"git push -u origin fix/x"}')
assert_eq '{}' "$out" 'no receipt: nothing is gated'

finish
