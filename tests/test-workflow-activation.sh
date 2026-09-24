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
assert_contains "$delivered" 'agent-preflight.sh' 'delivery names the preflight line'
assert_contains "$delivered" '--activation-nonce' 'delivery carries the nonce flag'
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

# Dispatch matching is executed-text only: heredoc bodies and quoted data
# never trigger a false deny; a real dispatch command hidden after a shell
# operator is still caught.
heredoc_input=$(jq -nc --arg c $'cat <<EOF\ngit push origin main\nEOF' '{command:$c}')
out=$(hook PreToolUse Bash "$heredoc_input")
assert_eq '{}' "$out" 'pending: a heredoc body containing dispatch-shaped text is allowed'
out=$(hook PreToolUse Bash '{"command":"printf '\''git push origin x'\''"}')
assert_eq '{}' "$out" 'pending: dispatch-shaped text inside quotes is allowed'
out=$(hook PreToolUse Bash '{"command":"cd /tmp && git push -u origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: git push after a shell operator is still denied'
out=$(hook PreToolUse Task '{"prompt":"x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: the Task tool is denied'
newline_input=$(jq -nc --arg c $'cd /tmp\ngit push origin main' '{command:$c}')
out=$(hook PreToolUse Bash "$newline_input")
assert_contains "$out" 'pending session acknowledgement' 'pending: a dispatch command on its own line after a newline is still denied'

# A quoted absolute helper path is the kit's own documented invocation form
# and must still be denied while pending, not treated as inert quoted data.
quoted_helper=$(jq -nc --arg c "\"$skills/parallel-issues/scripts/create-issue-worktree.sh\" --issue 1" '{command:$c}')
out=$(hook PreToolUse Bash "$quoted_helper")
assert_contains "$out" 'pending session acknowledgement' 'pending: a quoted absolute helper path is still denied'

# git/gh prefixes agents actually compose: -C/-c flags, leading whitespace, loops.
out=$(hook PreToolUse Bash '{"command":"git -C .worktrees/x push origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: git -C push is denied'
out=$(hook PreToolUse Bash '{"command":"  git push origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: leading-whitespace git push is denied'
# git/gh count as dispatch only in command position: at the start, after a shell operator, or after
# a known wrapper (env, timeout, xargs, sudo, do/then). A command that merely prints the words is not.
out=$(hook PreToolUse Bash '{"command":"echo git push origin main"}')
assert_eq '{}' "$out" 'pending: echo of dispatch-shaped words is allowed'
out=$(hook PreToolUse Bash '{"command":"printf %s git push origin main"}')
assert_eq '{}' "$out" 'pending: printf of dispatch-shaped words is allowed'
out=$(hook PreToolUse Bash '{"command":"env GIT_TERMINAL_PROMPT=0 git push origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: env-wrapped git push is denied'
out=$(hook PreToolUse Bash '{"command":"GIT_TERMINAL_PROMPT=0 timeout 60 git push origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: assignment- and timeout-wrapped git push is denied'
out=$(hook PreToolUse Bash '{"command":"printf %s fix/x | xargs git push origin"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: xargs git push is denied'
out=$(hook PreToolUse Bash '{"command":"/usr/bin/git push origin fix/x"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: absolute-path git push is denied'
out=$(hook PreToolUse Bash '{"command":"echo gh pr create --draft"}')
assert_eq '{}' "$out" 'pending: echo of gh pr create words is allowed'
loop_input=$(jq -nc --arg c $'for b in x; do git push origin $b; done' '{command:$c}')
out=$(hook PreToolUse Bash "$loop_input")
assert_contains "$out" 'pending session acknowledgement' 'pending: git push inside a for-loop body is denied'

# Helper-name patterns match the invoked command, not a read of the helper file.
read_helper=$(jq -nc --arg c "sed -n 1,20p $skills/parallel-issues/scripts/create-issue-worktree.sh" '{command:$c}')
out=$(hook PreToolUse Bash "$read_helper")
assert_eq '{}' "$out" 'pending: reading the helper file with sed is allowed'
invoke_helper=$(jq -nc --arg c "$skills/parallel-issues/scripts/create-issue-worktree.sh --issue 1" '{command:$c}')
out=$(hook PreToolUse Bash "$invoke_helper")
assert_contains "$out" 'pending session acknowledgement' 'pending: invoking the absolute helper path is still denied'

# <<- heredocs with a tab-indented terminator strip like plain heredocs.
tab_heredoc=$(jq -nc --arg c $'cat <<-EOF\n\tgit push origin main\n\tEOF' '{command:$c}')
out=$(hook PreToolUse Bash "$tab_heredoc")
assert_eq '{}' "$out" 'pending: a <<- heredoc with a tab-indented terminator is allowed'

# bash -c bodies are executed text (the kit's own recipes wrap commands this
# way; the harness shell is zsh), not inert quoted data.
out=$(hook PreToolUse Bash '{"command":"bash -c '\''git push origin HEAD'\''"}')
assert_contains "$out" 'pending session acknowledgement' 'pending: bash -c git push is denied'
out=$(hook PreToolUse Bash '{"command":"bash -c \"cd /tmp && git push origin x\""}')
assert_contains "$out" 'pending session acknowledgement' 'pending: bash -c with double quotes and a shell operator is denied'
out=$(hook PreToolUse Bash '{"command":"bash -c '\''printf \"git push\"'\''"}')
assert_eq '{}' "$out" 'pending: dispatch-shaped text inside a nested quote of a bash -c body is still inert'
out=$(hook PreToolUse Bash '{"command":"bash -c '\''ls -la'\''"}')
assert_eq '{}' "$out" 'pending: a harmless bash -c body is allowed'

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

# Delivery carries identity and the first command, never the skill body.
session=delivery-session-$$
delivered=$(jq -nc --arg s "$session" --arg c "$repo" \
    '{hook_event_name:"UserPromptSubmit", session_id:$s, cwd:$c, prompt:"$agentkit:parallel-issues 1"}' | "$wa" hook)
context=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$delivered")
assert_not_contains "$context" '### Step' 'delivery does not embed the skill body'
assert_contains "$context" 'skill=parallel-issues version=' 'delivery names the workflow identity'
assert_contains "$context" '--activation-nonce' 'delivery names the preflight line'
(( ${#context} < 1500 )) || assert_eq 'under-1500' "${#context}" 'delivery stays under the harness context caps'
receipt="$repo/.agent/activation/$(printf '%s' "$session" | sha256sum | cut -d' ' -f1).json"
assert_eq "$(sha256sum "$skills/parallel-issues/SKILL.md" | cut -d' ' -f1)" "$(jq -r .deliveredDigest "$receipt")" \
    'deliveredDigest is still the on-disk skill digest'

# A resumed session with a pending record re-delivers the first command and stays short.
resumed=$(jq -nc --arg s "$session" --arg c "$repo" \
    '{hook_event_name:"SessionStart", source:"resume", session_id:$s, cwd:$c}' | "$wa" hook)
rcontext=$(jq -r '.hookSpecificOutput.additionalContext' <<<"$resumed")
assert_contains "$rcontext" '--activation-nonce' 'resume re-delivers the preflight line'
(( ${#rcontext} < 1500 )) || assert_eq 'under-1500' "${#rcontext}" 'resume context stays short'

finish
