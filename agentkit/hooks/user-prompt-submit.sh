#!/usr/bin/env bash
# Supported Codex/Claude UserPromptSubmit boundary; absence cannot self-detect.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
input=$(cat)
blocked='{"decision":"block","reason":"agentkit: activation-unavailable: invocation boundary failed; repair the installation and restart the session."}'
unknown='{"decision":"block","reason":"agentkit: activation-unavailable: hook input could not be classified safely; repair the installation and restart the session."}'

# Classification shares the dispatcher's grammar and needs no installed digest.
if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$input"; then
    printf '%s\n' "$unknown"
    exit 0
fi
prompt_type=$(jq -r 'if has("prompt") then (.prompt | type) else "missing" end' <<<"$input")
if [[ $prompt_type != string ]]; then
    printf '%s\n' "$unknown"
    exit 0
fi
token=$(python3 "$here/../skills/.shared/scripts/lib/workflow-activation.py" \
    --skills "$here/../skills" --digest '' classify <<<"$input") || {
    printf '%s\n' "$unknown"
    exit 0
}

output=$(printf '%s\n' "$input" | "$here/../skills/.shared/scripts/workflow-activation.sh" hook) && {
    printf '%s\n' "$output"
    exit 0
}
if [[ -n $token ]]; then
    printf '%s\n' "$blocked"
else
    printf '%s\n' '{}'
fi
