#!/usr/bin/env bash
# bench/run-trial.sh -- one Tier-1 trial: container lifecycle, repo reset,
# the benchmark invocation, oracle scoring, and a ledger append (epic #152,
# issue #327; design doc "Trial definition" / "Environment").
#
# Runs in one of two modes:
#
#   --dry-run (the default, and the only mode CI or tests/test-bench-harness.sh
#   ever exercise)  Never calls `docker build`/`docker run`, never invokes a
#   real Codex process, and never spends a token. Every OTHER piece of trial
#   logic runs for real: the concurrency-cap gate reads real config.toml
#   fixtures, the GraphQL rate-limit gate calls a real (or stubbed) `gh`,
#   the container lifecycle state machine (bench/lib/container-lifecycle.sh)
#   really transitions and really proves destruction, the repo reset really
#   copies a tree, the oracle (bench/accept/run-accept.sh) really scores it,
#   and parse-rollout.py really parses the session files handed to it via
#   --orchestrator-session/--worker-session and really appends a ledger row.
#   "One scripted trial end-to-end" against real Codex spend is explicitly
#   left to the operator (see the completion report) -- this mode is what
#   proves every OTHER piece of that trial actually works.
#
#   --live  Builds the real image, runs a real container, and would invoke a
#   real Codex process inside it. Never invoked by this repo's tests or CI.
#   Requires GH_TOKEN and CODEX_API_KEY in this process's own environment
#   (passed through to the container, never baked into the image or written
#   to a file -- see bench/container/README.md's "Secrets" section).
set -euo pipefail

program=${0##*/}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

usage() {
    cat <<'EOF' >&2
Usage: bench/run-trial.sh [--dry-run|--live]
    --fixture DIR --old-config PATH --new-config PATH --arm old|new
    --run-id ID --plugin-sha SHA --assigned-model STR --assigned-effort STR
    --orchestrator-session FILE --worker-session FILE [--worker-session FILE ...]
    [--fixture-version STR] [--drift-control]
    [--selected-issues JSON] [--chain-plan JSON]
    [--serialization-events JSON] [--retry-events JSON]
    [--exit-condition complete|partial|timeout]
    [--acceptance-target DIR] [--ledger PATH] [--state-dir DIR]
    [--image-tag STR] [--dockerfile-dir DIR]
    [--min-graphql-remaining N] [--gh-bin BIN] [--now EPOCH]
    [--timestamp TS]
EOF
    exit "${1:-2}"
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
repo_root=$(cd -- "$script_dir/.." && pwd -P) || die 'could not resolve repo root'

# shellcheck source=lib/concurrency-cap-gate.sh
source "$script_dir/lib/concurrency-cap-gate.sh"
# shellcheck source=lib/home-empty.sh
source "$script_dir/lib/home-empty.sh"
# shellcheck source=lib/container-lifecycle.sh
source "$script_dir/lib/container-lifecycle.sh"
# shellcheck source=lib/rate-limit-gate.sh
source "$script_dir/lib/rate-limit-gate.sh"
# shellcheck source=lib/ledger-append.sh
source "$script_dir/lib/ledger-append.sh"

mode=--dry-run
fixture='' old_config='' new_config='' arm=''
run_id='' plugin_sha='' assigned_model='' assigned_effort=''
declare -a worker_sessions=()
orchestrator_session=''
fixture_version=tier1-v1
drift_control=false
selected_issues='' chain_plan='[]' serialization_events='[]' retry_events='[]'
exit_condition=complete
acceptance_target=''
ledger="$repo_root/bench/results/tier1.jsonl"
state_dir=''
image_tag='agent-kit-bench-tally:local'
dockerfile_dir="$repo_root/bench/container"
min_graphql_remaining=200
gh_bin=gh
now_override=''
timestamp_override=''

while (($#)); do
    case $1 in
        --dry-run) mode=--dry-run; shift ;;
        --live) mode=--live; shift ;;
        --fixture) fixture=$2; shift 2 ;;
        --old-config) old_config=$2; shift 2 ;;
        --new-config) new_config=$2; shift 2 ;;
        --arm) arm=$2; shift 2 ;;
        --run-id) run_id=$2; shift 2 ;;
        --plugin-sha) plugin_sha=$2; shift 2 ;;
        --assigned-model) assigned_model=$2; shift 2 ;;
        --assigned-effort) assigned_effort=$2; shift 2 ;;
        --orchestrator-session) orchestrator_session=$2; shift 2 ;;
        --worker-session) worker_sessions+=("$2"); shift 2 ;;
        --fixture-version) fixture_version=$2; shift 2 ;;
        --drift-control) drift_control=true; shift ;;
        --selected-issues) selected_issues=$2; shift 2 ;;
        --chain-plan) chain_plan=$2; shift 2 ;;
        --serialization-events) serialization_events=$2; shift 2 ;;
        --retry-events) retry_events=$2; shift 2 ;;
        --exit-condition) exit_condition=$2; shift 2 ;;
        --acceptance-target) acceptance_target=$2; shift 2 ;;
        --ledger) ledger=$2; shift 2 ;;
        --state-dir) state_dir=$2; shift 2 ;;
        --image-tag) image_tag=$2; shift 2 ;;
        --dockerfile-dir) dockerfile_dir=$2; shift 2 ;;
        --min-graphql-remaining) min_graphql_remaining=$2; shift 2 ;;
        --gh-bin) gh_bin=$2; shift 2 ;;
        --now) now_override=$2; shift 2 ;;
        --timestamp) timestamp_override=$2; shift 2 ;;
        -h | --help) usage 0 ;;
        *) printf '%s: unknown argument: %s\n' "$program" "$1" >&2; usage ;;
    esac
done

# --live is rejected here, during argument validation -- before the
# concurrency-cap gate and before any container/home/ledger allocation.
# This used to be checked at step 6 (the benchmark invocation), by which
# point step 4 had already built an image and started a real,
# credential-bearing container (GH_TOKEN/CODEX_API_KEY passed via -e) that
# the "not implemented" die() left running forever -- a real security find
# (F1), not just an early-exit nicety. The secrets check stays here too, so
# a caller missing GH_TOKEN/CODEX_API_KEY sees that diagnosed first, before
# the (currently unconditional) "not implemented" message.
if [[ $mode == --live ]]; then
    [[ -n ${GH_TOKEN:-} ]] || die 'GH_TOKEN must be set in the environment for --live'
    [[ -n ${CODEX_API_KEY:-} ]] || die 'CODEX_API_KEY must be set in the environment for --live'
    die 'run-trial: --live invocation is not implemented -- this dispatch builds the dry-run harness only; wiring the real docker exec + /parallel-issues invocation is left to the operator (see the completion report)'
fi

for required in fixture old_config new_config arm run_id plugin_sha assigned_model assigned_effort orchestrator_session; do
    [[ -n ${!required} ]] || { printf '%s: --%s is required\n' "$program" "${required//_/-}" >&2; usage; }
done
[[ ${#worker_sessions[@]} -ge 1 ]] || { printf '%s: at least one --worker-session is required\n' "$program" >&2; usage; }
[[ $arm == old || $arm == new ]] || die "--arm must be 'old' or 'new': $arm"
[[ $exit_condition == complete || $exit_condition == partial || $exit_condition == timeout ]] ||
    die "--exit-condition must be complete, partial, or timeout: $exit_condition"
[[ -d $fixture ]] || die "--fixture directory not found: $fixture"
[[ -f $old_config ]] || die "--old-config file not found: $old_config"
[[ -f $new_config ]] || die "--new-config file not found: $new_config"
[[ -f $orchestrator_session ]] || die "--orchestrator-session file not found: $orchestrator_session"
for f in "${worker_sessions[@]}"; do
    [[ -f $f ]] || die "--worker-session file not found: $f"
done

if [[ -z $selected_issues ]]; then
    issue_ids=$(grep -h '^id: ' "$repo_root"/bench/issues/*.md | sed 's/^id: *//' | sort)
    selected_issues=$(jq -Rnc '[inputs]' <<< "$issue_ids")
fi

[[ -n $state_dir ]] || state_dir=$(mktemp -d) || die 'could not create a state directory'
mkdir -p -- "$state_dir" || die "could not create state directory: $state_dir"
home_dir="$state_dir/home"
repo_dir="$state_dir/repo"
container_name="bench-trial-${run_id}"

trial_start=$(date -u +%s)

printf 'run-trial: mode=%s arm=%s run_id=%s\n' "$mode" "$arm" "$run_id"

# --- 1. concurrency cap: present and identical, or abort before spend -----
cap_line=$(concurrency_cap_gate "$old_config" "$new_config") || die 'concurrency cap gate failed (see above)'
printf 'run-trial: concurrency cap gate OK -- %s\n' "$cap_line"

# --- 2. GraphQL budget: pause, never fail mid-run --------------------------
rate_gate_args=(--gh-bin "$gh_bin" --min-remaining "$min_graphql_remaining")
[[ -z $now_override ]] || rate_gate_args+=(--now "$now_override")
rate_decision=$(graphql_rate_limit_gate "${rate_gate_args[@]}") ||
    die 'GraphQL rate-limit gate could not query gh (see above)'
printf 'run-trial: rate-limit gate -- %s\n' "$rate_decision"
if [[ $rate_decision == pause* ]]; then
    wait_seconds=$(grep -oE 'wait_seconds=[0-9]+' <<< "$rate_decision" | cut -d= -f2)
    if [[ $mode == --live ]]; then
        printf 'run-trial: pausing %ss for GraphQL quota to reset\n' "$wait_seconds"
        sleep "$wait_seconds"
    else
        printf 'run-trial: dry-run -- would pause %ss for GraphQL quota to reset; not sleeping in dry-run\n' "$wait_seconds"
    fi
fi

# --- 3. home directory baked empty -----------------------------------------
build_empty_home "$home_dir" || die 'could not build an empty home directory'
printf 'run-trial: home directory verified empty -- %s\n' "$home_dir"

# --- 4. container lifecycle: build, run ------------------------------------
container_build "$state_dir" "$image_tag" "$dockerfile_dir" "$mode" || die 'container build failed'
container_run "$state_dir" "$container_name" "$image_tag" "$home_dir" "$mode" || die 'container run failed'
printf 'run-trial: container %s -- %s\n' "$container_name" "$mode"
# Defense in depth: --live is already refused during argument validation
# above, so this branch cannot execute today -- but a real, credential-
# bearing container must never be left running because of a failure
# somewhere between here and step 9's explicit destroy. An EXIT trap set
# the moment a live container actually starts closes that gap regardless
# of how execution later leaves the script (die, an unhandled error, a
# signal).
if [[ $mode == --live ]]; then
    trap 'container_destroy "$state_dir" "$container_name" "$mode" > /dev/null 2>&1 || true' EXIT
fi

# --- 5. repo reset: delete-and-recreate from the fixture template ---------
rm -rf -- "$repo_dir"
cp -r -- "$fixture" "$repo_dir" || die "could not reset the trial repo from fixture: $fixture"
printf 'run-trial: repo reset from %s\n' "$fixture"

# --- 6. the benchmark invocation -------------------------------------------
# mode is always --dry-run by this point: --live is refused during argument
# validation, before any of this ran (see the comment there -- F1).
printf 'run-trial: dry-run -- skipping the real /parallel-issues invocation\n'

# --- 7. oracle: score the resulting tree ------------------------------------
[[ -n $acceptance_target ]] || acceptance_target=$repo_dir
acceptance_json="$state_dir/acceptance.json"
"$repo_root/bench/accept/run-accept.sh" "$acceptance_target" > "$acceptance_json" ||
    die "run-accept.sh failed against $acceptance_target"
printf 'run-trial: oracle scored -- %s\n' "$(cat "$acceptance_json")"

# --- 8. instrumentation: append bench_trial_meta, then parse ----------------
trial_end=$(date -u +%s)
wall_clock_seconds=$((trial_end - trial_start))
worker_count=${#worker_sessions[@]}

orchestrator_scratch="$state_dir/orchestrator-with-meta.jsonl"
cp -- "$orchestrator_session" "$orchestrator_scratch"
meta_line=$(jq -nc \
    --arg run_id "$run_id" \
    --arg plugin_sha "$plugin_sha" \
    --arg fixture_version "$fixture_version" \
    --arg assigned_model "$assigned_model" \
    --arg assigned_effort "$assigned_effort" \
    --argjson is_drift_control "$drift_control" \
    --argjson selected_issues "$selected_issues" \
    --argjson chain_plan "$chain_plan" \
    --argjson serialization_events "$serialization_events" \
    --argjson retry_events "$retry_events" \
    --argjson worker_count "$worker_count" \
    --argjson wall_clock_seconds "$wall_clock_seconds" \
    --arg exit_condition "$exit_condition" \
    '{type: "bench_trial_meta", payload: {
        run_id: $run_id, plugin_sha: $plugin_sha, fixture_version: $fixture_version,
        assigned_model: $assigned_model, assigned_effort: $assigned_effort,
        is_drift_control: $is_drift_control, selected_issues: $selected_issues,
        chain_plan: $chain_plan, serialization_events: $serialization_events,
        retry_events: $retry_events, worker_count: $worker_count,
        wall_clock_seconds: $wall_clock_seconds, exit_condition: $exit_condition
    }}') || die 'could not build the bench_trial_meta record'
printf '%s\n' "$meta_line" >> "$orchestrator_scratch"

parse_args=("$orchestrator_scratch" "${worker_sessions[@]}" --acceptance "$acceptance_json")
[[ -z $timestamp_override ]] || parse_args+=(--timestamp "$timestamp_override")
ledger_line=$(python3 "$repo_root/bench/parse-rollout.py" "${parse_args[@]}") ||
    die 'parse-rollout.py failed (see above)'

ledger_append "$ledger" "$ledger_line" || die 'could not append the ledger record'
printf 'run-trial: ledger record appended -- %s\n' "$ledger"

# --- 9. destroy the container, and PROVE it is gone ------------------------
container_destroy "$state_dir" "$container_name" "$mode" || die 'container destroy failed'
container_is_destroyed "$state_dir" "$container_name" "$mode" ||
    die "container $container_name is still present after destroy -- refusing to report success"
printf 'run-trial: container destroyed and verified gone -- %s\n' "$container_name"
# The explicit destroy above already ran; the step-4 EXIT trap (live mode
# only) is now redundant and cleared rather than left to fire a harmless
# but pointless second `docker rm -f` on normal exit.
[[ $mode != --live ]] || trap - EXIT

void=$(jq -r '.void' <<< "$ledger_line")
score=$(jq -r '.acceptance.score' <<< "$ledger_line")
total=$(jq -r '.acceptance.total' <<< "$ledger_line")
printf 'run-trial: PASS -- run_id=%s void=%s acceptance=%s/%s ledger=%s\n' \
    "$run_id" "$void" "$score" "$total" "$ledger"
