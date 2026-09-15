#!/usr/bin/env bash
# Boundary fixtures only: no harness launches or live compatibility claims.
set -uo pipefail
TEST_NAME=tool-input-rewrite
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
module="$here/probe/tool-input-rewrite.sh"
if [[ ! -f $module ]]; then
    _fail 'rewrite capability boundary exists' "missing $module"
    finish
    exit 1
fi
# shellcheck source=probe/tool-input-rewrite.sh
source "$module"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.agent" "$tmp/a path/it's"
git -C "$repo" init -q
helper="$tmp/a path/it's/agent-run.sh"
cat > "$helper" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD" "$#" "$@" "$REWRITE_FIXTURE_ENV"
printf 'fixture stderr\n' >&2
printf 'executed\n' >> "$REWRITE_FIXTURE_CALLS"
exit 37
SH
chmod +x -- "$helper"

event() {
    jq -nc --arg cwd "$repo" --arg command "${1-agent-run.sh --cmd test}" \
        '{hook_event_name:"PreToolUse",tool_name:"Bash",cwd:$cwd,session_id:"fixture",
          tool_input:{command:$command,timeout:731,description:"private fixture description"}}'
}
input=$(event)
candidate=$(tool_rewrite_candidate "$input" "$helper")
assert_eq 731 "$(jq -r '.timeout' <<< "$candidate")" 'candidate preserves timeout'
assert_eq 'private fixture description' "$(jq -r '.description' <<< "$candidate")" \
    'candidate preserves non-command inputs'
assert_eq "$(jq -c '.tool_input | del(.command)' <<< "$input")" \
    "$(jq -c 'del(.command)' <<< "$candidate")" 'only the command may change'
assert_not_contains "$candidate" 'permissionDecision' 'candidate grants no permission'

# Execute only the synthetic helper inside this wrapped suite, once. This checks
# quoting/cwd/argv/exit behavior, not whether an installed harness honors a hook.
export REWRITE_FIXTURE_ENV='fixture environment'
export REWRITE_FIXTURE_CALLS="$tmp/calls"
command=$(jq -r '.command' <<< "$candidate")
rc=0
(cd -- "$repo" && bash -c "$command") > "$tmp/stdout" 2> "$tmp/stderr" || rc=$?
assert_eq 37 "$rc" 'fixture retains failure exit status'
assert_eq "$(printf '%s\n' "$repo" 2 --cmd test 'fixture environment')" \
    "$(cat "$tmp/stdout")" 'fixture retains cwd, arguments, and environment'
assert_eq 'fixture stderr' "$(cat "$tmp/stderr")" 'fixture retains stderr'
assert_eq executed "$(cat "$tmp/calls")" 'fixture helper executes once'

# shellcheck disable=SC2016 # Literal substitutions must remain unexecuted input.
for command in '' 'agent-run.sh --cmd test ' 'agent-run.sh --cmd format' \
    'agent-run.sh --cmd test --only hooks' 'agent-run.sh --cmd test; echo extra' \
    'agent-run.sh --cmd test | cat' 'agent-run.sh --cmd test > result' \
    'agent-run.sh --cmd test $(echo extra)' 'agent-run.sh --cmd test `echo extra`' \
    'KEY=value agent-run.sh --cmd test' 'bash agent-run.sh --cmd test' \
    $'agent-run.sh --cmd test\necho extra' 'agent-run.sh --cmd test # comment'; do
    assert_rc 1 'non-exact shell input is ineligible' -- \
        tool_rewrite_candidate "$(event "$command")" "$helper"
done
while IFS= read -r fixture; do
    nested=$(jq -c --argjson command "$fixture" \
        '.tool_input.command=$command | .session_id="nested-fixture"' <<< "$input")
    before=$nested
    output=$(tool_rewrite_candidate "$nested" "$helper")
    status=$?
    assert_eq 1 "$status" 'nested or non-exact command is ineligible'
    assert_eq '' "$output" 'ineligible command emits no replacement or rewrite event'
    assert_eq "$before" "$nested" 'ineligible tool input remains byte-for-byte unchanged'
    output=$("$root/agentkit/hooks/pre-tool-use.sh" <<< "$nested")
    assert_not_contains "$output" updatedInput 'production hook never rewrites nested or inert text'
done < <(jq -c '.[]' "$here/fixtures/tool-rewrite-ineligible.json")
assert_rc 1 'ineligible calls produce no rewrite telemetry' -- test -e "$repo/.agent/tool-rewrites.ndjson"
for patch in '.tool_name="exec_command"' '.tool_name="Edit"' \
    '.hook_event_name="PostToolUse"' '.tool_input.command=12' \
    '.tool_input.sandbox_permissions="require_escalated"' \
    '.tool_input.run_in_background=true' '.tool_input.timeout=-1' \
    '.tool_input.workdir="/elsewhere"' '.cwd="relative"'; do
    assert_rc 1 'unproven tool or execution controls are ineligible' -- \
        tool_rewrite_candidate "$(jq -c "$patch" <<< "$input")" "$helper"
done
assert_rc 1 'malformed payload is ineligible' -- tool_rewrite_candidate '[' "$helper"
assert_rc 1 'multiple payloads cannot produce multiple candidates' -- \
    tool_rewrite_candidate "$input"$'\n'"$input" "$helper"
assert_rc 1 'unresolved helper is ineligible' -- tool_rewrite_candidate "$input" /missing/agent-run.sh
duplicate_object='"tool_input":{"description":"first"},"tool_input":'
for duplicate in \
    "${input/\"tool_name\":/\"tool_name\":\"Edit\",\"tool_name\":}" \
    "${input/\"tool_input\":/$duplicate_object}" \
    "${input/\"command\":/\"command\":\"false\",\"command\":}" \
    "${input/\"timeout\":/\"timeout\":1,\"timeout\":}"; do
    assert_rc 0 'duplicate-key fixture is valid JSON' -- jq -e . <<< "$duplicate"
    assert_rc 1 'duplicate relevant keys cannot establish a candidate' -- \
        tool_rewrite_candidate "$duplicate" "$helper"
done

for adapter in codex claude unknown; do
    capability=$(tool_rewrite_capability "$adapter" fixture-version Bash)
    assert_eq unavailable "$(jq -r '.status' <<< "$capability")" \
        "$adapter has no accepted live capability"
    assert_eq fixture-version "$(jq -r '.version' <<< "$capability")" \
        "$adapter capability report names the requested version"
done

# A plausible activation/compatibility claim is still not execution evidence.
printf '%s\n' '{"capabilities":{"pre-tool-use":"observed","updatedInput":"observed"}}' \
    > "$repo/.agent/rewrite-capability.json"
export AGENTKIT_REWRITE_ENABLED=1
export AGENTKIT_REWRITE_CAPABILITY="$repo/.agent/rewrite-capability.json"
out=$("$root/agentkit/hooks/pre-tool-use.sh" <<< "$input")
assert_eq deny "$(jq -r '.hookSpecificOutput.permissionDecision' <<< "$out")" \
    'unsupported runtime retains first helper-path denial'
assert_contains "$out" 'Then run it again' 'existing bounded retry guidance remains'
out=$("$root/agentkit/hooks/pre-tool-use.sh" <<< "$input")
assert_not_contains "$out" updatedInput 'retry remains unchanged, with no silent rewrite'
assert_not_contains "$out" 'private fixture description' 'fallback does not log input metadata'

printf 'rewrite-fixture: live_execution=unavailable live_saved_turns=unavailable live_false_transformations=unavailable\n'
finish
