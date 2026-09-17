#!/usr/bin/env bash
# Suite: bench/parse-rollout.py -- turns a trial's Codex session logs into
# one Tier-1 ledger record (epic #152, issue #327; design doc
# "Instrumentation"). Runs against the synthetic fixture under
# tests/fixtures/bench/sessions/ -- a real trial container is never
# exercised (that would cost real Codex spend; see bench/run-trial.sh's
# header comment). Every expected number below is computed independently
# from the fixture's raw bytes (jq/grep over the fixture files), the same
# discipline tests/test-bench-tier0.sh uses for its own byte-accounting
# fixture, so this suite is a genuine spot check of parse-rollout.py's
# arithmetic and parsing rather than a restatement of its own code.
set -uo pipefail

TEST_NAME='bench parse-rollout'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

parse_rollout="$repo_root/bench/parse-rollout.py"
sessions="$repo_root/tests/fixtures/bench/sessions"
acceptance_fixture="$repo_root/tests/fixtures/bench/acceptance.json"

command -v python3 > /dev/null 2>&1 || {
    printf 'bench parse-rollout: python3 is required\n' >&2
    exit 1
}
command -v jq > /dev/null 2>&1 || {
    printf 'bench parse-rollout: jq is required\n' >&2
    exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

RUN_RC=0
RUN_OUT=''
run() {
    RUN_RC=0
    RUN_OUT=$(python3 "$parse_rollout" "$@" 2>&1) || RUN_RC=$?
}

# --- shipped, executable ---------------------------------------------------
assert_eq 'yes' "$([[ -x $parse_rollout ]] && printf yes || printf no)" 'bench/parse-rollout.py is executable'

# --- usage / argument validation -------------------------------------------
run
assert_eq '2' "$RUN_RC" 'no SESSION_FILE argument exits 2'
assert_contains "$RUN_OUT" 'usage' 'no SESSION_FILE argument prints usage'

run "$sessions/worker-1.jsonl"
assert_eq '1' "$RUN_RC" 'a set of session files with no bench_trial_meta record fails'
assert_contains "$RUN_OUT" 'bench_trial_meta' 'the missing-meta failure names the missing record type'

# --- independent expectations, computed from the raw fixture bytes --------
sum_token_field() {
    local file=$1 field=$2
    jq -s --arg field "$field" \
        '[.[] | select(.type == "event_msg" and .payload.type == "token_count") | (.payload.info[$field] // 0)] | add // 0' \
        "$file"
}
count_ref() {
    local file=$1 needle=$2
    grep -c "$needle" "$file" || true
}

orch_input=$(sum_token_field "$sessions/orchestrator.jsonl" input_tokens)
orch_cache_read=$(sum_token_field "$sessions/orchestrator.jsonl" cached_input_tokens)
orch_output=$(sum_token_field "$sessions/orchestrator.jsonl" output_tokens)
w1_input=$(sum_token_field "$sessions/worker-1.jsonl" input_tokens)
w1_cache_read=$(sum_token_field "$sessions/worker-1.jsonl" cached_input_tokens)
w1_output=$(sum_token_field "$sessions/worker-1.jsonl" output_tokens)
w2_input=$(sum_token_field "$sessions/worker-2.jsonl" input_tokens)
w2_cache_read=$(sum_token_field "$sessions/worker-2.jsonl" cached_input_tokens)
w2_output=$(sum_token_field "$sessions/worker-2.jsonl" output_tokens)

expect_total_input=$((orch_input + w1_input + w2_input))
expect_total_cache_read=$((orch_cache_read + w1_cache_read + w2_cache_read))
expect_total_output=$((orch_output + w1_output + w2_output))

expect_triage_orch=$(count_ref "$sessions/orchestrator.jsonl" 'triage-and-selection\.md')
expect_spawn_orch=$(count_ref "$sessions/orchestrator.jsonl" 'spawn-contract\.md')
expect_spawn_w1=$(count_ref "$sessions/worker-1.jsonl" 'spawn-contract\.md')
expect_worker_prompts_w1=$(count_ref "$sessions/worker-1.jsonl" 'worker-prompts\.md')
expect_worker_prompts_w2=$(count_ref "$sessions/worker-2.jsonl" 'worker-prompts\.md')

# blended_usd, computed independently with the same PLACEHOLDER rate table
# bench/parse-rollout.py's DEFAULT_PRICING documents for gpt-5.6-luna
# ($/1K tokens: input 0.003, cache_read 0.0006, cache_write 0.00375,
# output 0.015) -- a real spot check of the arithmetic, not a restatement.
expect_blended_usd=$(awk -v ti="$expect_total_input" -v tc="$expect_total_cache_read" -v to="$expect_total_output" \
    'BEGIN { printf "%.6f", (ti/1000*0.003) + (tc/1000*0.0006) + (to/1000*0.015) }')

# --- the clean (non-void) end-to-end record --------------------------------
run "$sessions/orchestrator.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl" \
    --acceptance "$acceptance_fixture" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'the clean fixture set parses successfully'

get() { jq -r "$1" <<< "$RUN_OUT" 2> /dev/null; }

assert_eq '53e7e8c850380444cd4fb0edb25ebfd8adb32b61' "$(get .plugin_sha)" 'plugin_sha passes through from bench_trial_meta'
assert_eq 'tier1-v1' "$(get .fixture_version)" 'fixture_version passes through'
assert_eq 'gpt-5.6-luna' "$(get .model)" 'model is the ASSIGNED model (ledger grouping key), not necessarily realised'
assert_eq 'low' "$(get .effort)" 'effort is the ASSIGNED effort (ledger grouping key)'
assert_eq '2026-08-20T00:00:00Z' "$(get .measured_at)" '--timestamp overrides measured_at'
assert_eq 'trial-fixture-0001' "$(get .run_id)" 'run_id passes through from bench_trial_meta'
assert_eq 'false' "$(get .is_drift_control)" 'is_drift_control passes through'
assert_eq 'gpt-5.6-luna' "$(get .model_realised)" 'model_realised is derived from worker turn_context, not just asserted'
assert_eq 'low' "$(get .effort_realised)" 'effort_realised is derived from worker turn_context'
assert_eq 'false' "$(get .void)" 'a matching assigned/realised tier is not void'
assert_eq '0' "$(get '.void_reasons | length')" 'a non-void record carries no void reasons'

assert_eq "$orch_input" "$(get .tokens.orchestrator.input)" 'orchestrator input tokens sum correctly across turns'
assert_eq "$orch_cache_read" "$(get .tokens.orchestrator.cache_read)" 'orchestrator cache_read tokens sum correctly'
assert_eq '0' "$(get .tokens.orchestrator.cache_write)" 'orchestrator cache_write is 0 (no such class in this fixture)'
assert_eq "$orch_output" "$(get .tokens.orchestrator.output)" 'orchestrator output tokens sum correctly'
assert_eq "$w1_input" "$(get '.tokens.workers["worker:1"].input')" 'worker:1 input tokens are attributed separately from the orchestrator'
assert_eq "$w2_input" "$(get '.tokens.workers["worker:2"].input')" 'worker:2 input tokens are attributed separately from worker:1'
assert_eq "$expect_total_input" "$(get .tokens.total.input)" 'total input = orchestrator + every worker'
assert_eq "$expect_total_cache_read" "$(get .tokens.total.cache_read)" 'total cache_read = orchestrator + every worker'
assert_eq "$expect_total_output" "$(get .tokens.total.output)" 'total output = orchestrator + every worker'

blended_diff=$(awk -v a="$expect_blended_usd" -v b="$(get .blended_usd)" 'BEGIN { d = a - b; if (d < 0) d = -d; print (d < 0.000001) ? "0" : "1" }')
assert_eq '0' "$blended_diff" "blended_usd (want ~$expect_blended_usd) matches the independent placeholder-rate calculation"

assert_eq "$expect_triage_orch" "$(get '.reference_hits["agentkit/skills/parallel-issues/references/triage-and-selection.md"].orchestrator')" \
    'orchestrator reference hit count for triage-and-selection.md matches the raw fixture'
assert_eq '0' "$(get '.reference_hits["agentkit/skills/parallel-issues/references/triage-and-selection.md"].workers["worker:1"]')" \
    'a reference never read by a worker reports an explicit 0, not an omitted key'
assert_eq "$expect_spawn_orch" "$(get '.reference_hits["agentkit/skills/.shared/spawn-contract.md"].orchestrator')" \
    'orchestrator reference hit count for spawn-contract.md matches the raw fixture'
assert_eq "$expect_spawn_w1" "$(get '.reference_hits["agentkit/skills/.shared/spawn-contract.md"].workers["worker:1"]')" \
    'worker:1 reference hit count for spawn-contract.md matches the raw fixture'
assert_eq "$expect_worker_prompts_w1" "$(get '.reference_hits["agentkit/skills/parallel-issues/references/worker-prompts.md"].workers["worker:1"]')" \
    'worker:1 reference hit count for worker-prompts.md matches the raw fixture (dispatched-template callback)'
assert_eq "$expect_worker_prompts_w2" "$(get '.reference_hits["agentkit/skills/parallel-issues/references/worker-prompts.md"].workers["worker:2"]')" \
    'worker:2 reference hit count for worker-prompts.md matches the raw fixture'
assert_eq '0' "$(get '(.reference_hits["agentkit/skills/parallel-issues/references/chains.md"] // {}) | length')" \
    'the no-chain fixture records no chains.md reads'

assert_eq '180.0' "$(get .pre_spawn_seconds)" \
    'pre_spawn_seconds spans the session start through the first spawn_agent call'
assert_eq '28' "$(get .pre_spawn_chars.skill_reference_prose)" \
    'pre-spawn skill and reference output characters are counted together'
assert_eq '28' "$(get .pre_spawn_chars.repository_source_docs)" \
    'repository docs and script-helper output share the source/docs category'
assert_eq '10' "$(get .pre_spawn_chars.issue_forge_data)" \
    'pre-spawn issue and forge data characters have their own category'
assert_eq '11' "$(get .pre_spawn_chars.tool_interface_discovery)" \
    'pre-spawn tool discovery characters have their own category'
assert_eq '10' "$(get .pre_spawn_chars.unknown_other)" \
    'uncategorized pre-spawn text is visible in the explicit unknown bucket'
assert_eq '87' "$(get .pre_spawn_chars.total)" \
    'pre-spawn total is the sum of category character counts'
assert_eq 'complete' "$(get .pre_spawn_evidence.status)" \
    'complete spawn, timestamp, and category evidence is named explicitly'
assert_eq '0' "$(get '.pre_spawn_evidence.missing | length')" \
    'complete pre-spawn evidence carries no missing reasons'

assert_eq '842' "$(get .wall_clock_seconds)" 'wall_clock_seconds passes through from bench_trial_meta'
assert_eq '2' "$(get .worker_count)" 'worker_count passes through from bench_trial_meta'
assert_eq '10' "$(get '.selected_issues | length')" 'selected_issues passes through from bench_trial_meta'
assert_eq '2' "$(get '.chain_plan | length')" 'chain_plan passes through from bench_trial_meta'
assert_eq '3' "$(get '.serialization_events | length')" 'serialization_events passes through from bench_trial_meta'
assert_eq '0' "$(get '.retry_events | length')" 'retry_events passes through from bench_trial_meta'
assert_eq 'complete' "$(get .exit_condition)" 'exit_condition passes through from bench_trial_meta'
assert_eq '8' "$(get .acceptance.score)" 'the run-accept.sh acceptance JSON is embedded verbatim, score included'
assert_eq '10' "$(get .acceptance.total)" 'the acceptance JSON total is embedded verbatim'
assert_eq 'fail' "$(get '.acceptance.results["tally-05"]')" 'per-issue acceptance results are embedded verbatim'

# --- polling cost is reconstructed from rollout events, not model prose ---
poll_fixture="$tmp/root-wait-2026-09-16.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-09-16T00:00:00Z","type":"session_meta","payload":{"originator":"orchestrator","model":"gpt-5.6-luna"}}' \
    '{"timestamp":"2026-09-16T00:00:00Z","type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}' \
    > "$poll_fixture"
for n in $(seq 1 92); do
    start_epoch=$((1789516800 + (n - 1) * 30))
    end_epoch=$((start_epoch + 30))
    start=$(date -u -d "@$start_epoch" '+%Y-%m-%dT%H:%M:%SZ')
    end=$(date -u -d "@$end_epoch" '+%Y-%m-%dT%H:%M:%SZ')
    if ((n <= 43)); then
        tool=collaboration.wait_agent
        args='{"timeout_ms":60000}'
    elif ((n <= 82)); then
        tool='wait'
        args='{"cell_id":"cell","yield_time_ms":30000}'
    else
        tool=write_stdin
        args='{"session_id":7,"chars":"","yield_time_ms":30000}'
    fi
    printf '%s\n' \
        "{\"timestamp\":\"$start\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call\",\"call_id\":\"poll-$n\",\"name\":\"$tool\",\"arguments\":\"${args//\"/\\\"}\"}}" \
        "{\"timestamp\":\"$start\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":121000}}}}" \
        "{\"timestamp\":\"$end\",\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"poll-$n\",\"output\":\"timed out\"}}" \
        >> "$poll_fixture"
done
printf '%s\n' \
    '{"timestamp":"2026-09-16T00:46:01Z","type":"response_item","payload":{"type":"function_call","call_id":"input-1","name":"write_stdin","arguments":"{\"session_id\":7,\"chars\":\"yes\\n\",\"yield_time_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T00:46:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":121000}}}}' \
    '{"timestamp":"2026-09-16T00:46:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"input-1","output":"written"}}' \
    >> "$poll_fixture"
printf '%s\n' '{"type":"bench_trial_meta","payload":{"run_id":"wait-fixture","plugin_sha":"53e7e8c850380444cd4fb0edb25ebfd8adb32b61","fixture_version":"2026-09-16-polls","assigned_model":"gpt-5.6-luna","assigned_effort":"low","is_drift_control":false,"selected_issues":[],"chain_plan":[],"serialization_events":[],"retry_events":[],"worker_count":0,"wall_clock_seconds":2760,"exit_condition":"complete"}}' >> "$poll_fixture"
run "$poll_fixture" --timestamp 2026-09-16T01:00:00Z
assert_eq '0' "$RUN_RC" 'the 2026-09-16 polling fixture parses successfully'
assert_eq '92' "$(jq -r '.poll_turns' <<< "$RUN_OUT")" \
    'poll_turns counts wait_agent, yielded waits, and empty write_stdin resumes'
assert_eq '11132000' "$(jq -r '.poll_input_tokens' <<< "$RUN_OUT")" \
    'poll_input_tokens attributes each polling request input cost post hoc'
assert_eq '2760.0' "$(jq -r '.wait_seconds' <<< "$RUN_OUT")" \
    'wait_seconds is the union of timestamped polling call intervals'
assert_eq '2.0' "$(jq -r '.requests_per_wait_minute' <<< "$RUN_OUT")" \
    'requests_per_wait_minute is derived from measured turns and elapsed waits'

# --- worker verification churn is attributed per rollout session ---------
worker_churn_fixture="$tmp/worker-churn.jsonl"
printf '%s\n' \
    '{"type":"session_meta","payload":{"originator":"worker:776","model":"gpt-5.6-luna"}}' \
    '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"verify-launch","name":"exec_command","arguments":"{\"cmd\":\"/kit/agent-run.sh --cmd test --summary\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"helper-launch","name":"exec_command","arguments":"{\"cmd\":\"other-helper --wait\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"cell-launch","name":"exec_command","arguments":"{\"cmd\":\"agent-run.sh --cmd lint --summary\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"missing-launch","name":"exec_command","arguments":"{\"cmd\":\"agent-run.sh --cmd test --summary\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call_output","call_id":"helper-launch","output":"{\"session_id\":8}"}}' \
    '{"type":"response_item","payload":{"type":"function_call_output","call_id":"verify-launch","output":"{\"session_id\":7,\"output\":\"still running\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call_output","call_id":"missing-launch","output":"{\"output\":\"completed without yielding\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call_output","call_id":"cell-launch","output":"{\"cell_id\":\"verify-cell\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"helper-resume","name":"write_stdin","arguments":"{\"session_id\":8,\"chars\":\"\",\"yield_time_ms\":10}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"helper-read","name":"exec_command","arguments":"{\"cmd\":\"tail -20 /repo/.agent/logs/helper.log\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"resume-1","name":"write_stdin","arguments":"{\"session_id\":7,\"chars\":\"\",\"yield_time_ms\":30000}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"read-1","name":"exec_command","arguments":"{\"cmd\":\"tail -20 /repo/.agent/logs/test.log\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"unknown-resume","name":"write_stdin","arguments":"{\"session_id\":9,\"chars\":\"\",\"yield_time_ms\":1}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"unknown-read","name":"exec_command","arguments":"{\"cmd\":\"tail -20 /repo/.agent/logs/unknown.log\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"resume-2","name":"write_stdin","arguments":"{\"session_id\":7,\"chars\":\"\",\"yield_time_ms\":1000}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"read-2","name":"shell","arguments":"{\"command\":[\"sed\",\"-n\",\"1,20p\",\"/repo/.agent/logs/test.log\"]}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"resume-3","name":"write_stdin","arguments":"{\"session_id\":7,\"chars\":\"\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"cell-resume","name":"write_stdin","arguments":"{\"cell_id\":\"verify-cell\",\"chars\":\"\",\"yield_time_ms\":2000}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"missing-id-resume","name":"write_stdin","arguments":"{\"chars\":\"\",\"yield_time_ms\":1}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"read-after-final","name":"exec_command","arguments":"{\"cmd\":\"tail -1 /repo/.agent/logs/test.log\"}"}}' \
    '{"type":"response_item","payload":{"type":"function_call","call_id":"input","name":"write_stdin","arguments":"{\"session_id\":7,\"chars\":\"yes\\n\",\"yield_time_ms\":10}"}}' \
    '{"type":"bench_trial_meta","payload":{"run_id":"worker-churn","plugin_sha":"53e7e8c850380444cd4fb0edb25ebfd8adb32b61","fixture_version":"2026-09-16-worker-churn","assigned_model":"gpt-5.6-luna","assigned_effort":"low","is_drift_control":false,"selected_issues":[],"chain_plan":[],"serialization_events":[],"retry_events":[],"worker_count":1,"wall_clock_seconds":90,"exit_condition":"complete"}}' \
    > "$worker_churn_fixture"
run "$worker_churn_fixture" --timestamp 2026-09-16T01:00:00Z
assert_eq '0' "$RUN_RC" 'the worker verification-churn fixture parses successfully'
assert_eq '4' "$(jq -r '.worker_resume_calls["worker:776"]' <<< "$RUN_OUT")" \
    'only resumes correlated to verification launch session or cell IDs are counted'
assert_eq '1000' "$(jq -r '.worker_min_yield_ms["worker:776"]' <<< "$RUN_OUT")" \
    'minimum worker yield ignores missing values and non-empty writes'
assert_eq '2' "$(jq -r '.log_reads_between_resumes["worker:776"]' <<< "$RUN_OUT")" \
    'helper and unknown-session log reads do not inflate verification churn'

poll_gap_fixture="$tmp/poll-telemetry-gap.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-09-16T01:00:00Z","type":"session_meta","payload":{"originator":"orchestrator","model":"gpt-5.6-luna"}}' \
    '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}' \
    '{"timestamp":"2026-09-16T01:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"other-1","name":"shell","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T01:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"gap-1","name":"wait_agent","arguments":"{\"timeout_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T01:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":900}}}}' \
    '{"timestamp":"2026-09-16T01:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"gap-1","output":"timed out"}}' \
    '{"timestamp":"2026-09-16T01:00:03Z","type":"response_item","payload":{"type":"function_call","call_id":"gap-2","name":"wait","arguments":"{\"yield_time_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T01:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"gap-2","output":"timed out"}}' \
    '{"timestamp":"2026-09-16T01:00:05Z","type":"response_item","payload":{"type":"function_call","call_id":"gap-3","name":"wait_agent","arguments":"{\"timeout_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T01:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000}}}}' \
    '{"timestamp":"2026-09-16T01:00:06Z","type":"response_item","payload":{"type":"function_call_output","call_id":"gap-3","output":"timed out"}}' \
    '{"type":"bench_trial_meta","payload":{"run_id":"gap-fixture","plugin_sha":"53e7e8c850380444cd4fb0edb25ebfd8adb32b61","fixture_version":"poll-gap-v1","assigned_model":"gpt-5.6-luna","assigned_effort":"low","is_drift_control":false,"selected_issues":[],"chain_plan":[],"serialization_events":[],"retry_events":[],"worker_count":0,"wall_clock_seconds":6,"exit_condition":"complete"}}' \
    > "$poll_gap_fixture"
run "$poll_gap_fixture" --timestamp 2026-09-16T01:01:00Z
assert_eq '0' "$RUN_RC" 'a rollout with missing poll telemetry still parses'
assert_eq '3' "$(jq -r '.poll_turns' <<< "$RUN_OUT")" \
    'poll turns remain countable when their token telemetry is incomplete'
assert_eq 'null' "$(jq -r '.poll_input_tokens' <<< "$RUN_OUT")" \
    'a nonpoll overwrite or consecutive poll reports input telemetry unavailable'

poll_group_fixture="$tmp/poll-response-groups.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-09-16T02:00:00Z","type":"session_meta","payload":{"originator":"orchestrator","model":"gpt-5.6-luna"}}' \
    '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}' \
    '{"timestamp":"2026-09-16T02:00:00Z","type":"response_item","payload":{"type":"function_call","call_id":"group-1","name":"wait_agent","arguments":"{\"timeout_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T02:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"group-2","name":"wait","arguments":"{\"yield_time_ms\":30000}"}}' \
    '{"timestamp":"2026-09-16T02:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1200}}}}' \
    '{"timestamp":"2026-09-16T02:00:02Z","type":"response_item","payload":{"type":"function_call_output","call_id":"group-1","output":"timed out"}}' \
    '{"timestamp":"2026-09-16T02:00:03Z","type":"response_item","payload":{"type":"function_call_output","call_id":"group-2","output":"timed out"}}' \
    '{"type":"bench_trial_meta","payload":{"run_id":"group-fixture","plugin_sha":"53e7e8c850380444cd4fb0edb25ebfd8adb32b61","fixture_version":"poll-group-v1","assigned_model":"gpt-5.6-luna","assigned_effort":"low","is_drift_control":false,"selected_issues":[],"chain_plan":[],"serialization_events":[],"retry_events":[],"worker_count":0,"wall_clock_seconds":3,"exit_condition":"complete"}}' \
    > "$poll_group_fixture"
run "$poll_group_fixture" --timestamp 2026-09-16T02:01:00Z
assert_eq '0' "$RUN_RC" 'a response containing multiple poll calls parses'
assert_eq '2' "$(jq -r '.poll_turns' <<< "$RUN_OUT")" \
    'every poll call in a response remains countable'
assert_eq '1200' "$(jq -r '.poll_input_tokens' <<< "$RUN_OUT")" \
    'one response-level usage value is applied once to an all-poll group'

malformed_id_fixture="$tmp/poll-malformed-ids.jsonl"
printf '%s\n' \
    '{"timestamp":"2026-09-16T03:00:00Z","type":"session_meta","payload":{"originator":"orchestrator","model":"gpt-5.6-luna"}}' \
    '{"type":"turn_context","payload":{"model":"gpt-5.6-luna","effort":"low"}}' \
    '{"timestamp":"2026-09-16T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"wait_agent","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T03:00:01Z","type":"response_item","payload":{"type":"function_call","call_id":"","name":"wait_agent","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T03:00:02Z","type":"response_item","payload":{"type":"function_call","call_id":7,"name":"wait_agent","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T03:00:03Z","type":"response_item","payload":{"type":"function_call","call_id":"duplicate","name":"wait_agent","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T03:00:04Z","type":"response_item","payload":{"type":"function_call","call_id":"duplicate","name":"wait_agent","arguments":"{}"}}' \
    '{"timestamp":"2026-09-16T03:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1500}}}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","output":"timed out"}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"","output":"timed out"}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":7,"output":"timed out"}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":["not","hashable"],"output":"timed out"}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":{"also":"not hashable"},"output":"timed out"}}' \
    '{"timestamp":"2026-09-16T03:00:05Z","type":"response_item","payload":{"type":"function_call_output","call_id":"duplicate","output":"timed out"}}' \
    '{"type":"bench_trial_meta","payload":{"run_id":"malformed-id-fixture","plugin_sha":"53e7e8c850380444cd4fb0edb25ebfd8adb32b61","fixture_version":"poll-id-v1","assigned_model":"gpt-5.6-luna","assigned_effort":"low","is_drift_control":false,"selected_issues":[],"chain_plan":[],"serialization_events":[],"retry_events":[],"worker_count":0,"wall_clock_seconds":5,"exit_condition":"complete"}}' \
    > "$malformed_id_fixture"
run "$malformed_id_fixture" --timestamp 2026-09-16T03:01:00Z
assert_eq '0' "$RUN_RC" 'malformed polling call IDs do not crash rollout parsing'
assert_eq '5' "$(jq -r '.poll_turns' <<< "$RUN_OUT")" \
    'malformed polling IDs do not hide poll turns'
assert_eq 'null' "$(jq -r '.wait_seconds' <<< "$RUN_OUT")" \
    'missing, empty, non-string, or duplicate call IDs make interval telemetry unavailable'

# --- prose context cost is measured per rollout session -------------------
prose_fixture="$tmp/prose-cost.jsonl"
injected_prefix='agentkit invocation boundary: explicit workflow delivery, not native registry evidence.'
injected_body=$'---\nname: parallel-issues\n---\n# Parallel Issues\n'
read_output=$'# Reading discipline\nRead this once.\n'
custom_read_output=$'# Parallel Issues\nInjected bodies are authoritative.\n'
single_quoted_output=$'# Single quoted command\n'
jq -nc --arg prefix "$injected_prefix" --arg body "$injected_body" --arg read "$read_output" \
    --arg custom_read "$custom_read_output" --arg single_read "$single_quoted_output" \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"message",role:"user",content:[{type:"input_text",text:($prefix+"\nInstalled skills root: /skills\n\n"+$body)}]}},
     {type:"response_item",payload:{type:"function_call",call_id:"read-prose",name:"exec_command",arguments:"{\"cmd\":\"sed -n 1,40p agentkit/skills/.shared/reading-discipline.md\"}"}},
     {type:"response_item",payload:{type:"function_call_output",call_id:"read-prose",output:$read}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"custom-read-prose",name:"functions.exec",input:"text(await tools.exec_command({cmd:\"cat agentkit/skills/parallel-issues/SKILL.md\",workdir:\"/repo\"}));"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"custom-read-prose",output:$custom_read}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"single-quoted-prose",name:"functions.exec",input:"text(await tools.exec_command({cmd:\u0027cat notes.md\u0027}));"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"single-quoted-prose",output:$single_read}},
     {type:"response_item",payload:{type:"function_call",call_id:"message-mention",name:"send_message",arguments:"{\"message\":\"please cat agentkit/skills/parallel-issues/SKILL.md\"}"}},
     {type:"response_item",payload:{type:"function_call_output",call_id:"message-mention",output:"message delivered"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-cost",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$prose_fixture"
run "$prose_fixture" --timestamp 2026-09-16T03:02:00Z
assert_eq '0' "$RUN_RC" 'a rollout with injected and tool-read prose parses'
assert_eq "${#injected_body}" \
    "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_injected' <<< "$RUN_OUT")" \
    'injected prose counts the exact delivered SKILL.md body, excluding the hook wrapper'
assert_eq "$((${#read_output} + ${#custom_read_output} + ${#single_quoted_output}))" \
    "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'read prose counts exact output characters from direct and custom nested markdown reads'

ambiguous_prose_fixture="$tmp/prose-cost-ambiguous.jsonl"
jq -nc \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"mixed-output",name:"functions.exec",input:"const a=await tools.exec_command({cmd:\"cat one.md\"}); const b=await tools.exec_command({cmd:\"git status\"}); text(a.output); text(b.output);"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"mixed-output",output:"prose plus unrelated status"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-ambiguous",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$ambiguous_prose_fixture"
run "$ambiguous_prose_fixture" --timestamp 2026-09-16T03:03:00Z
assert_eq '0' "$RUN_RC" 'a mixed custom execution rollout still parses'
assert_eq 'null' "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'mixed custom execution marks prose-read characters unavailable instead of asserting zero'

prose_boundaries_fixture="$tmp/prose-cost-boundaries.jsonl"
jq -nc \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"single-quoted",name:"functions.exec",input:"text(await tools.exec_command({cmd:\u0027cat one.md\u0027}));"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"single-quoted",output:"one markdown"}},
     {type:"response_item",payload:{type:"function_call",call_id:"compound-shell",name:"exec_command",arguments:"{\"cmd\":\"cat two.md; git status\"}"}},
     {type:"response_item",payload:{type:"function_call_output",call_id:"compound-shell",output:"markdown and status"}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"unsupported-js",name:"functions.exec",input:"text(await tools.exec_command({cmd:`cat three.md`}));"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"unsupported-js",output:"three markdown"}},
     {type:"response_item",payload:{type:"function_call",call_id:"missing-output",name:"exec_command",arguments:"{\"cmd\":\"cat four.md\"}"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-boundaries",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$prose_boundaries_fixture"
run "$prose_boundaries_fixture" --timestamp 2026-09-16T03:04:00Z
assert_eq '0' "$RUN_RC" 'single-quoted and conservative prose boundaries parse without crashing'
assert_eq 'null' "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'compound, unsupported, or unmatched markdown reads make prose characters unavailable'

prose_mixed_boundaries_fixture="$tmp/prose-cost-mixed-boundaries.jsonl"
jq -nc \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"unparsed-first",name:"functions.exec",input:"const a=await tools.exec_command({cmd:`cat one.md`}); const b=await tools.exec_command({cmd:\u0027printf noise\u0027}); text(a.output); text(b.output);"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"unparsed-first",output:"markdown plus noise"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-mixed-boundaries",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$prose_mixed_boundaries_fixture"
run "$prose_mixed_boundaries_fixture" --timestamp 2026-09-16T03:05:00Z
assert_eq '0' "$RUN_RC" 'an unsupported custom call before a supported call still parses'
assert_eq 'null' "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'an unparsed Markdown call before a supported custom call makes prose characters unavailable'

background_prose_fixture="$tmp/prose-cost-background.jsonl"
jq -nc \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"function_call",call_id:"background-mixed",name:"exec_command",arguments:"{\"cmd\":\"cat two.md & git status\"}"}},
     {type:"response_item",payload:{type:"function_call_output",call_id:"background-mixed",output:"markdown and status"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-background",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$background_prose_fixture"
run "$background_prose_fixture" --timestamp 2026-09-16T03:06:00Z
assert_eq '0' "$RUN_RC" 'a background shell read still parses'
assert_eq 'null' "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'background mixed output makes prose characters unavailable'

custom_compound_prose_fixture="$tmp/prose-cost-custom-compound.jsonl"
jq -nc \
    '{type:"session_meta",payload:{originator:"orchestrator",model:"gpt-5.6-luna"}},
     {type:"turn_context",payload:{model:"gpt-5.6-luna",effort:"low"}},
     {type:"response_item",payload:{type:"custom_tool_call",call_id:"custom-compound",name:"functions.exec",input:"text(await tools.exec_command({cmd:\u0027cat two.md; git status\u0027}));"}},
     {type:"response_item",payload:{type:"custom_tool_call_output",call_id:"custom-compound",output:"markdown and status"}},
     {type:"bench_trial_meta",payload:{run_id:"prose-custom-compound",plugin_sha:"53e7e8c850380444cd4fb0edb25ebfd8adb32b61",fixture_version:"prose-v1",assigned_model:"gpt-5.6-luna",assigned_effort:"low",is_drift_control:false,selected_issues:[],chain_plan:[],serialization_events:[],retry_events:[],worker_count:0,wall_clock_seconds:1,exit_condition:"complete"}}' \
    > "$custom_compound_prose_fixture"
run "$custom_compound_prose_fixture" --timestamp 2026-09-16T03:07:00Z
assert_eq '0' "$RUN_RC" 'a single custom compound shell read still parses'
assert_eq 'null' "$(jq -r '.dynamic_efficiency.actors[0].prose_chars_read' <<< "$RUN_OUT")" \
    'a single custom command with mixed output makes prose characters unavailable'

# --- acceptance is optional: omitting it still yields a valid record ------
run "$sessions/orchestrator.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'omitting --acceptance still succeeds'
assert_eq 'null' "$(jq -r '.acceptance' <<< "$RUN_OUT" 2> /dev/null)" 'omitting --acceptance leaves acceptance explicitly null, not omitted'

# A missing spawn boundary, timestamps, or countable category evidence is
# unavailable evidence. The parser reports null plus the exact reason instead
# of manufacturing a zero-duration or zero-character pre-spawn phase.
sed 's/multi_agent_v1__spawn_agent/multi_agent_v1__submit_task/' "$sessions/orchestrator.jsonl" > "$tmp/no-spawn.jsonl"
run "$tmp/no-spawn.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq 'null' "$(jq -r '.pre_spawn_seconds' <<< "$RUN_OUT")" 'missing spawn boundary leaves seconds null'
assert_eq 'null' "$(jq -r '.pre_spawn_chars' <<< "$RUN_OUT")" 'missing spawn boundary leaves character counts null'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("spawn_boundary") != null' <<< "$RUN_OUT")" \
    'missing spawn boundary is reported explicitly'

jq -c 'del(.timestamp) | if .type == "session_meta" then .payload |= del(.timestamp) else . end' \
    "$sessions/orchestrator.jsonl" > "$tmp/no-timestamps.jsonl"
run "$tmp/no-timestamps.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq 'null' "$(jq -r '.pre_spawn_seconds' <<< "$RUN_OUT")" 'missing timestamps leave seconds null'
assert_eq '87' "$(jq -r '.pre_spawn_chars.total' <<< "$RUN_OUT")" 'character evidence survives missing timestamps'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("timestamps") != null' <<< "$RUN_OUT")" \
    'missing timestamp evidence is reported explicitly'

jq -c 'select(.type == "session_meta" or .type == "turn_context" or .type == "bench_trial_meta" or
    (.type == "response_item" and .payload.call_id == "c-spawn" and .payload.type == "custom_tool_call"))' \
    "$sessions/orchestrator.jsonl" > "$tmp/no-category-evidence.jsonl"
run "$tmp/no-category-evidence.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '180.0' "$(jq -r '.pre_spawn_seconds' <<< "$RUN_OUT")" 'elapsed evidence survives missing category text'
assert_eq 'null' "$(jq -r '.pre_spawn_chars' <<< "$RUN_OUT")" 'missing category evidence leaves character counts null'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("category_evidence") != null' <<< "$RUN_OUT")" \
    'missing category evidence is reported explicitly'

jq -c 'if .payload.call_id? == "c-repo" then
    .payload.call_id = (if (.payload.type | endswith("output")) then {bad: 1} else ["bad"] end)
    else . end' "$sessions/orchestrator.jsonl" > "$tmp/unhashable-call-ids.jsonl"
run "$tmp/unhashable-call-ids.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '0' "$RUN_RC" 'list and object call ids do not crash pre-spawn parsing'
assert_eq '87' "$(jq -r '.pre_spawn_chars.total' <<< "$RUN_OUT")" 'ambiguous call ids preserve the total character count'
assert_eq '25' "$(jq -r '.pre_spawn_chars.unknown_other' <<< "$RUN_OUT")" 'unattributed output moves to the explicit unknown bucket'
assert_eq 'partial' "$(jq -r '.pre_spawn_evidence.status' <<< "$RUN_OUT")" 'ambiguous output attribution is explicitly partial'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("category_attribution") != null' <<< "$RUN_OUT")" \
    'ambiguous call ids name missing category attribution'

jq -c 'if .payload.call_id? == "c-forge" and .payload.type == "function_call" then
    .payload |= (.type = "custom_tool_call" | .name = "functions.exec" |
      .input = {code: "await tools.exec_command({cmd: \"gh issue view 784; cat agentkit/skills/parallel-issues/SKILL.md\"})"} |
      del(.arguments))
    else . end' "$sessions/orchestrator.jsonl" > "$tmp/mixed-wrapper.jsonl"
run "$tmp/mixed-wrapper.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '0' "$RUN_RC" 'a mixed-category functions wrapper parses without guessing'
assert_eq '0' "$(jq -r '.pre_spawn_chars.issue_forge_data' <<< "$RUN_OUT")" 'mixed wrapper output is not assigned wholesale to forge data'
assert_eq '20' "$(jq -r '.pre_spawn_chars.unknown_other' <<< "$RUN_OUT")" 'mixed wrapper output moves to the unknown bucket'
assert_eq 'partial' "$(jq -r '.pre_spawn_evidence.status' <<< "$RUN_OUT")" 'mixed wrapper attribution is explicitly partial'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("category_attribution") != null' <<< "$RUN_OUT")" \
    'mixed wrapper names missing category attribution'

jq -c 'if .payload.call_id? == "c-repo" then .payload.call_id = "c2" else . end' \
    "$sessions/orchestrator.jsonl" > "$tmp/duplicate-call-id.jsonl"
run "$tmp/duplicate-call-id.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '1' "$RUN_RC" 'duplicate call ids fail the rollout instead of overwriting attribution silently'
assert_contains "$RUN_OUT" 'conflicting event identity' 'the duplicate-id refusal names the ambiguous identity evidence'

jq -c 'if .payload.call_id? == "c-repo" then .payload.call_id = "" else . end' \
    "$sessions/orchestrator.jsonl" > "$tmp/empty-call-id.jsonl"
run "$tmp/empty-call-id.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '0' "$RUN_RC" 'empty call ids do not become a shared attribution key'
assert_eq 'partial' "$(jq -r '.pre_spawn_evidence.status' <<< "$RUN_OUT")" 'empty call ids make category evidence partial'
assert_eq '25' "$(jq -r '.pre_spawn_chars.unknown_other' <<< "$RUN_OUT")" 'empty-id output moves to the unknown bucket'

jq -c 'if .payload.call_id? == "c-spawn" then .timestamp = "2026-08-20T10:03:00" else . end' \
    "$sessions/orchestrator.jsonl" > "$tmp/mixed-timestamps.jsonl"
run "$tmp/mixed-timestamps.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq '0' "$RUN_RC" 'mixed naive and aware timestamps do not crash pre-spawn parsing'
assert_eq 'null' "$(jq -r '.pre_spawn_seconds' <<< "$RUN_OUT")" 'mixed timestamp awareness leaves elapsed time null'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("timestamps") != null' <<< "$RUN_OUT")" \
    'mixed timestamp awareness is reported as unavailable timestamp evidence'

jq -c 'if .payload.call_id? == "c-spawn" then .timestamp = "2026-08-20T09:59:00.000Z" else . end' \
    "$sessions/orchestrator.jsonl" > "$tmp/negative-duration.jsonl"
run "$tmp/negative-duration.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl"
assert_eq 'null' "$(jq -r '.pre_spawn_seconds' <<< "$RUN_OUT")" 'a negative pre-spawn duration is unavailable, not emitted'
assert_eq 'true' "$(jq -r '.pre_spawn_evidence.missing | index("timestamps") != null' <<< "$RUN_OUT")" \
    'negative timestamp ordering is reported explicitly'

# --- void: workers disagree with each other --------------------------------
run "$sessions/orchestrator.jsonl" "$sessions/worker-1-drift.jsonl" "$sessions/worker-2.jsonl" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'a worker-disagreement trial still parses (void, not a hard failure)'
assert_eq 'true' "$(jq -r '.void' <<< "$RUN_OUT")" 'workers realising different (model, effort) pairs is void'
assert_contains "$(jq -r '.void_reasons | join("; ")' <<< "$RUN_OUT")" 'disagree' \
    'the void reason names worker disagreement'

# --- void: realised tier differs uniformly from assigned -------------------
run "$sessions/orchestrator.jsonl" "$sessions/worker-1-drift.jsonl" "$sessions/worker-2-drift.jsonl" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'a uniformly-drifted trial still parses (void, not a hard failure)'
assert_eq 'true' "$(jq -r '.void' <<< "$RUN_OUT")" 'realised effort (high) != assigned effort (low) is void'
assert_eq 'high' "$(jq -r '.effort_realised' <<< "$RUN_OUT")" 'effort_realised reports what was actually observed, not the assigned value'
assert_contains "$(jq -r '.void_reasons | join("; ")' <<< "$RUN_OUT")" '!=' \
    'the void reason names the assigned/realised mismatch'

# --- exactly one bench_trial_meta record is required -----------------------
dup_dir="$tmp/dup"
mkdir -p "$dup_dir"
cp "$sessions/orchestrator.jsonl" "$dup_dir/orch-a.jsonl"
cp "$sessions/orchestrator.jsonl" "$dup_dir/orch-b.jsonl"
run "$dup_dir/orch-a.jsonl" "$dup_dir/orch-b.jsonl" "$sessions/worker-1.jsonl"
assert_eq '1' "$RUN_RC" 'more than one bench_trial_meta record across the session files fails'
assert_contains "$RUN_OUT" 'more than one' 'the duplicate-meta failure names the problem'

# --- an unpriced model fails loudly, not with a silent $0 -------------------
unpriced_dir="$tmp/unpriced"
mkdir -p "$unpriced_dir"
sed 's/gpt-5\.6-luna/some-unpriced-model/g' "$sessions/orchestrator.jsonl" > "$unpriced_dir/orchestrator.jsonl"
sed 's/gpt-5\.6-luna/some-unpriced-model/g' "$sessions/worker-1.jsonl" > "$unpriced_dir/worker-1.jsonl"
run "$unpriced_dir/orchestrator.jsonl" "$unpriced_dir/worker-1.jsonl"
# shellcheck disable=SC2016  # $0 is literal message text (a dollar amount), not shell expansion
assert_eq '1' "$RUN_RC" 'a model absent from the pricing table fails rather than pricing it as $0'
assert_contains "$RUN_OUT" 'some-unpriced-model' 'the pricing failure names the unpriced model'

# --- --pricing overrides the default table ----------------------------------
pricing_file="$tmp/pricing.json"
printf '{"some-unpriced-model": {"input": 0.01, "cache_read": 0.001, "cache_write": 0.02, "output": 0.03}}\n' \
    > "$pricing_file"
run "$unpriced_dir/orchestrator.jsonl" "$unpriced_dir/worker-1.jsonl" --pricing "$pricing_file" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'a --pricing override supplies the missing rate'

blended_positive=$(jq -r '.blended_usd > 0' <<< "$RUN_OUT")
assert_eq 'true' "$blended_positive" '--pricing override produces a positive blended_usd for the previously-unpriced model'

# --- default measured_at is a real UTC timestamp when --timestamp omitted --
run "$sessions/orchestrator.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl" --acceptance "$acceptance_fixture"
assert_eq '0' "$RUN_RC" 'omitting --timestamp still succeeds'
measured_at=$(jq -r '.measured_at' <<< "$RUN_OUT")
assert_eq 'yes' "$([[ $measured_at =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && printf yes || printf no)" \
    'a default measured_at still looks like an ISO-8601 UTC instant'

finish
