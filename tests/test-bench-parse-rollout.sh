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

# --- acceptance is optional: omitting it still yields a valid record ------
run "$sessions/orchestrator.jsonl" "$sessions/worker-1.jsonl" "$sessions/worker-2.jsonl" --timestamp 2026-08-20T00:00:00Z
assert_eq '0' "$RUN_RC" 'omitting --acceptance still succeeds'
assert_eq 'null' "$(jq -r '.acceptance' <<< "$RUN_OUT" 2> /dev/null)" 'omitting --acceptance leaves acceptance explicitly null, not omitted'

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
