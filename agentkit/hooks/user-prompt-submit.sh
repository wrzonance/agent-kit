#!/usr/bin/env bash
# Supported Codex/Claude UserPromptSubmit boundary; absence cannot self-detect.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
output=$("$here/../skills/.shared/scripts/workflow-activation.sh" hook) && {
    printf '%s\n' "$output"
    exit 0
}
printf '%s\n' '{"decision":"block","reason":"agentkit: activation-unavailable: invocation boundary failed; repair the installation and restart the session."}'
