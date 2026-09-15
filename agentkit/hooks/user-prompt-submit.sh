#!/usr/bin/env bash
# Supported Codex/Claude UserPromptSubmit boundary; absence cannot self-detect.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
input=$(cat)
blocked='{"decision":"block","reason":"agentkit: activation-unavailable: invocation boundary failed; repair the installation and restart the session."}'
unknown='{"decision":"block","reason":"agentkit: activation-unavailable: hook input could not be classified safely; repair the installation and restart the session."}'

# The dispatcher owns the accepted selector grammar. Keep the equivalent
# anchored token match here so a broken dispatcher does not block ordinary chat
# or let an attempted workflow pass silently.
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input"; then
    printf '%s\n' "$unknown"
    exit 0
fi
prompt_type=$(jq -r 'if has("prompt") then (.prompt | type) else "missing" end' <<<"$input")
if [[ $prompt_type != string ]]; then
    printf '%s\n' "$unknown"
    exit 0
fi
token=$(jq -r 'try (.prompt | capture("^\\s*[$/](?<token>(?:agentkit:)?[a-z][a-z0-9-]*)(?=\\s|$)").token) catch ""' <<<"$input")
workflow_invocation=0
case $token in
    agentkit:*) workflow_invocation=1 ;;
    parallel-issues|pr-to-green|review-remote-pr|onboard-repo) workflow_invocation=1 ;;
esac

output=$(printf '%s\n' "$input" | "$here/../skills/.shared/scripts/workflow-activation.sh" hook) && {
    printf '%s\n' "$output"
    exit 0
}
if ((workflow_invocation)); then
    printf '%s\n' "$blocked"
else
    printf '%s\n' '{}'
fi
