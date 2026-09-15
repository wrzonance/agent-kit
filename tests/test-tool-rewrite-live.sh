#!/usr/bin/env bash
# Local boundary fixtures; this suite never invokes a provider session.
set -uo pipefail
TEST_NAME=tool-rewrite-live
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
driver="$here/probe/tool-rewrite-live.sh"
if [[ ! -f $driver ]]; then
    _fail 'standalone probe preparer exists' "missing $driver"
    finish
    exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
probe="$tmp/probe"
bash "$driver" prepare "$probe"
cat > "$tmp/cli" <<'SH'
#!/bin/bash
printf invoked > "$0.called"
exit 93
SH
chmod +x "$tmp/cli"
shellcheck "$tmp/cli"
assert_rc 2 'live runner requires explicit root marker' -- bash "$driver" run "$probe" "$tmp/cli" --not-authorized
assert_rc 1 'unauthorized marker never invokes the CLI' -- test -e "$tmp/cli.called"
for mode in control rewrite; do
    case_dir="$probe/$mode"
    helper="$case_dir/agent-run.sh"
    command=$(jq -r '.transformed' "$case_dir/manifest.json")
    settings=$(cat "$case_dir/settings.json")
    assert_eq 1 "$(jq '.permissions.allow | length' <<< "$settings")" 'only synthetic helper is preapproved'
    assert_not_contains "$settings" 'enabledPlugins' 'probe does not change plugin enablement'
    input=$(jq -nc --arg cwd "$case_dir/repo" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",session_id:"fixture",tool_use_id:"original",
          cwd:$cwd,tool_input:{command:"agent-run.sh --cmd test",timeout:10000,description:"synthetic"}}')
    out=$(bash "$probe/driver.sh" hook "$case_dir" <<< "$input")
    assert_not_contains "$out" '"allow"' 'hook output never auto-grants permission'
    if [[ $mode == control ]]; then
        assert_eq deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")" 'control requires correction'
        command="$helper --cmd test"
        input=$(jq -c --arg command "$command" '.tool_use_id="retry" | .tool_input.command=$command' <<< "$input")
        assert_eq '{}' "$(bash "$probe/driver.sh" hook "$case_dir" <<< "$input")" 'unquoted exact control retry has no hook permission override'
    else
        assert_eq "$command" "$(jq -r '.hookSpecificOutput.updatedInput.command' <<< "$out")" 'rewrite contains qualified helper'
        assert_eq 10000 "$(jq -r '.hookSpecificOutput.updatedInput.timeout' <<< "$out")" 'rewrite preserves timeout'
        input=$(jq -c --arg command "$command" '.tool_input.command=$command' <<< "$input")
    fi
    execution=$(cd -- "$case_dir/repo" && AGENTKIT_REWRITE_PROBE_ENV=synthetic "$helper" --cmd test)
    post=$(jq -c --arg stdout "$execution" \
        '.hook_event_name="PostToolUse" | .tool_response={stdout:($stdout + "\nREWRITE-PROBE-STDERR"),stderr:"",interrupted:false}' <<< "$input")
    assert_eq '{}' "$(bash "$probe/driver.sh" hook "$case_dir" <<< "$post")" 'result recording adds no model context'
    assert_rc 78 'second helper execution is rejected' -- bash "$probe/driver.sh" target "$case_dir" --cmd test
done
report=$(bash "$driver" inspect "$probe")
assert_eq true "$(jq '.correlated' <<< "$report")" 'control and rewrite fixture events correlate'
assert_eq false "$(jq '.runtimeObserved' <<< "$report")" 'synthetic records never establish provider execution'
assert_eq 1 "$(jq '.avoidedCorrectionCalls' <<< "$report")" 'fixture comparison counts exactly one correction call'
# Adding an unmatched result must invalidate correlation rather than invent a receipt.
printf '%s\n' '{"event":"PostToolUse","id":"orphan","session":"fixture"}' >> "$probe/rewrite/events.ndjson"
assert_rc 1 'orphan result invalidates probe evidence' -- bash "$driver" inspect "$probe"
finish
