#!/usr/bin/env bash
set -euo pipefail
TEST_NAME=rewrite-wiring
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir -p "$temporary/kit" "$temporary/repo"
git -C "$temporary/repo" init -q
cp -a "$here/../agentkit/hooks" "$here/../agentkit/skills" "$temporary/kit/"
cat > "$temporary/kit/hooks/lib/rewrite_runtime.py" <<'PY'
import json
import os
import sys
from pathlib import Path

event = json.load(sys.stdin)
if event["tool_input"]["command"] != "agent-run.sh --cmd test":
    print("{}")
    raise SystemExit(0)
if os.environ.get("AGENT_REWRITE_TEST_RUNTIME_LOG"):
    Path(os.environ["AGENT_REWRITE_TEST_RUNTIME_LOG"]).write_text("validator invoked")
replacement = event["tool_input"] | {"command": "/fixture/agent-run.sh --cmd test"}
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": replacement}}))
PY
if [[ -n ${AGENT_REWRITE_LINTER:-} ]]; then
    "$AGENT_REWRITE_LINTER" check "$temporary/kit/hooks/lib/rewrite_runtime.py"
fi
input=$(jq -nc --arg cwd "$temporary/repo" '{cwd:$cwd,session_id:"fixture",tool_use_id:"fixture-call",
    hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"agent-run.sh --cmd test",timeout:10000}}')
output=$(AGENTKIT_REWRITE_PROFILE=/fixture/operator/profile "$temporary/kit/hooks/pre-tool-use.sh" <<< "$input")
assert_eq '/fixture/agent-run.sh --cmd test' "$(jq -r '.hookSpecificOutput.updatedInput.command // ""' <<< "$output")" \
    'pre hook emits validated runtime replacement before legacy helper correction'
assert_eq null "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" 'rewrite wiring never grants permission'
dangerous=$(jq -c '.tool_input.command="git reset --hard"' <<< "$input")
output=$(AGENTKIT_REWRITE_PROFILE=/fixture/operator/profile "$temporary/kit/hooks/pre-tool-use.sh" <<< "$dangerous")
assert_eq deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$output")" 'hard refusal precedes rewrite wiring'
assert_not_contains "$output" updatedInput 'hard refusal cannot consume or emit a rewrite'
while IFS= read -r command; do
    nested=$(jq -c --argjson command "$command" '.tool_input.command=$command' <<< "$input")
    output=$(AGENTKIT_REWRITE_PROFILE=/fixture/operator/profile AGENT_REWRITE_TEST_RUNTIME_LOG="$temporary/invoked" \
        "$temporary/kit/hooks/pre-tool-use.sh" <<< "$nested")
    assert_not_contains "$output" updatedInput 'nested and inert command data cannot be rewritten with an active profile pointer'
done < <(jq -c '.[]' "$here/fixtures/tool-rewrite-ineligible.json")
assert_rc 1 'original nested input cannot issue a rewrite or create rewrite telemetry' -- test -e "$temporary/invoked"
post=$(jq -c '.hook_event_name="PostToolUse"|.tool_input.command="printf PostToolUseFailure"' <<< "$input")
AGENTKIT_REWRITE_PROFILE='' AGENT_REWRITE_TEST_RUNTIME_LOG="$temporary/invoked" \
    "$temporary/kit/hooks/post-tool-use.sh" <<< "$post" >/dev/null
assert_rc 1 'disabled post hook never invokes the validator' -- test -e "$temporary/invoked"
finish
