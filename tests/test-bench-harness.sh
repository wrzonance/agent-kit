#!/usr/bin/env bash
# Suite: the Tier-1 trial harness (epic #152, issue #327) -- bench/lib/*.sh's
# gates and container-lifecycle state machine, and bench/run-trial.sh's
# end-to-end dry-run orchestration. Every test here runs in dry-run mode:
# no `docker build`/`docker run`, no real Codex process, no spend. See
# bench/run-trial.sh's header comment for why dry-run is the only mode this
# repo's tests or CI ever exercise, and bench/container/README.md for why a
# real image build is deliberately left to the operator.
set -uo pipefail

TEST_NAME='bench harness'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

lib_dir="$repo_root/bench/lib"
run_trial="$repo_root/bench/run-trial.sh"
fixtures="$repo_root/tests/fixtures/bench"
sessions="$fixtures/sessions"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# A stub `gh` that answers `gh api rate_limit --jq ...` the way the real CLI
# would after applying that filter -- GH_STUB_REMAINING/GH_STUB_RESET
# control the numbers a test wants to see. Any other invocation is a test
# bug (the harness must never call gh for anything else) and fails loudly
# rather than silently returning nothing.
write_gh_stub() {
    local bin_dir=$1
    mkdir -p -- "$bin_dir"
    cat > "$bin_dir/gh" << 'EOF'
#!/usr/bin/env bash
case " $* " in
    *' api rate_limit '*)
        printf '%s %s\n' "${GH_STUB_REMAINING:-5000}" "${GH_STUB_RESET:-9999999999}"
        ;;
    *)
        printf 'gh stub: unexpected invocation: %s\n' "$*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$bin_dir/gh"
}

# ============================================================
# bench/lib/concurrency-cap-gate.sh
# ============================================================
# shellcheck source=../bench/lib/concurrency-cap-gate.sh
source "$lib_dir/concurrency-cap-gate.sh"

cap_out=''
cap_rc=0
run_cap_gate() {
    cap_rc=0
    cap_out=$(concurrency_cap_gate "$@" 2>&1) || cap_rc=$?
}

run_cap_gate "$fixtures/config/cap-old-match.toml" "$fixtures/config/cap-new-match.toml"
assert_eq '0' "$cap_rc" 'matching, present caps on both arms succeed'
assert_contains "$cap_out" 'cap=4' 'the gate reports the agreed cap'

run_cap_gate "$fixtures/config/cap-old-match.toml" "$fixtures/config/cap-new-mismatch.toml"
assert_eq '1' "$cap_rc" 'differing caps between arms fail -- must never silently change parallelism'
assert_contains "$cap_out" 'caps differ' 'the mismatch failure names the reason'

run_cap_gate "$fixtures/config/cap-absent.toml" "$fixtures/config/cap-new-match.toml"
assert_eq '1' "$cap_rc" 'an absent cap on either arm fails -- absence must abort before spend, never deadlock silently'

# ============================================================
# bench/lib/home-empty.sh
# ============================================================
# shellcheck source=../bench/lib/home-empty.sh
source "$lib_dir/home-empty.sh"

home_dir="$tmp/home-empty-1"
build_empty_home "$home_dir"
assert_eq '0' "$?" 'build_empty_home succeeds on a fresh path'
assert_eq 'yes' "$([[ -d $home_dir ]] && printf yes || printf no)" 'build_empty_home creates the directory'
verify_empty_home "$home_dir"
assert_eq '0' "$?" 'a freshly built home passes its own emptiness check'

mkdir -p "$home_dir/.claude"
printf '# stateful\n' > "$home_dir/.claude/CLAUDE.md"
verify_empty_home "$home_dir" 2> /dev/null
contaminated_rc=$?
assert_eq '1' "$contaminated_rc" 'a home carrying .claude/CLAUDE.md fails the emptiness check'

# build_empty_home on an already-contaminated dir wipes and rebuilds clean
build_empty_home "$home_dir"
assert_eq '0' "$?" 'build_empty_home wipes prior contamination and rebuilds clean'
verify_empty_home "$home_dir"
assert_eq '0' "$?" 'the rebuilt home is clean again'

build_empty_home ''
assert_eq '1' "$?" 'build_empty_home refuses an empty path'
build_empty_home /
assert_eq '1' "$?" 'build_empty_home refuses the root path'

# ============================================================
# bench/lib/container-lifecycle.sh (dry-run state machine)
# ============================================================
# shellcheck source=../bench/lib/container-lifecycle.sh
source "$lib_dir/container-lifecycle.sh"

state_dir="$tmp/container-state"
container_build "$state_dir" 'agent-kit-bench-tally:test' "$repo_root/bench/container" --dry-run
assert_eq '0' "$?" 'container_build (dry-run) succeeds without docker'

container_is_destroyed "$state_dir" 'trial-1' --dry-run
assert_eq '0' "$?" 'a container never run reads as already destroyed'

container_run "$state_dir" 'trial-1' 'agent-kit-bench-tally:test' "$tmp/home-empty-1" --dry-run
assert_eq '0' "$?" 'container_run (dry-run) succeeds after a build'

container_is_destroyed "$state_dir" 'trial-1' --dry-run
running_check_rc=$?
assert_eq '1' "$running_check_rc" 'a running container is correctly reported as NOT destroyed'

container_run "$state_dir" 'trial-1' 'agent-kit-bench-tally:test' "$tmp/home-empty-1" --dry-run 2> /dev/null
double_run_rc=$?
assert_eq '1' "$double_run_rc" 'running a second container under the same name fails -- one trial per container'

container_destroy "$state_dir" 'trial-1' --dry-run
assert_eq '0' "$?" 'container_destroy (dry-run) succeeds'
container_is_destroyed "$state_dir" 'trial-1' --dry-run
assert_eq '0' "$?" 'destruction is independently verifiable after container_destroy, not merely assumed'

fresh_state="$tmp/container-state-no-build"
container_run "$fresh_state" 'trial-2' 'agent-kit-bench-tally:test' "$tmp/home-empty-1" --dry-run 2> /dev/null
no_build_rc=$?
assert_eq '1' "$no_build_rc" 'container_run refuses to run against a state dir with no prior container_build'

# ============================================================
# bench/lib/rate-limit-gate.sh
# ============================================================
# shellcheck source=../bench/lib/rate-limit-gate.sh
source "$lib_dir/rate-limit-gate.sh"

gh_bin_dir="$tmp/gh-bin"
write_gh_stub "$gh_bin_dir"

rate_out=''
rate_rc=0
run_rate_gate() {
    rate_rc=0
    # GH_STUB_REMAINING/GH_STUB_RESET are inherited from this function's own
    # temporary environment (set by the caller as a VAR=val prefix) -- the
    # stub gh script (write_gh_stub) reads them directly.
    rate_out=$(graphql_rate_limit_gate --gh-bin "$gh_bin_dir/gh" "$@" 2>&1) || rate_rc=$?
}

GH_STUB_REMAINING=5000 GH_STUB_RESET=9999999999 run_rate_gate --min-remaining 200 --now 1000
assert_eq '0' "$rate_rc" 'ample GraphQL quota succeeds'
assert_contains "$rate_out" 'proceed' 'ample quota decides to proceed'

GH_STUB_REMAINING=10 GH_STUB_RESET=1900 run_rate_gate --min-remaining 200 --now 1000
assert_eq '0' "$rate_rc" 'low GraphQL quota still exits 0 -- low quota is a pause decision, never a hard failure'
assert_contains "$rate_out" 'pause' 'low quota decides to pause rather than fail mid-run'
assert_contains "$rate_out" 'wait_seconds=900' 'the pause wait is computed deterministically from --now and reset'

GH_STUB_REMAINING=10 GH_STUB_RESET=500 run_rate_gate --min-remaining 200 --now 1000
assert_contains "$rate_out" 'wait_seconds=0' 'a reset already in the past clamps wait_seconds to 0, never negative'

broken_gh_dir="$tmp/gh-broken"
mkdir -p "$broken_gh_dir"
cat > "$broken_gh_dir/gh" << 'EOF'
#!/usr/bin/env bash
echo 'gh: authentication failed' >&2
exit 4
EOF
chmod +x "$broken_gh_dir/gh"
rate_rc=0
rate_out=$(graphql_rate_limit_gate --gh-bin "$broken_gh_dir/gh" 2>&1) || rate_rc=$?
assert_eq '1' "$rate_rc" 'a gh call that fails outright (auth/network) fails the gate rather than pretending quota is fine'

# ============================================================
# bench/lib/ledger-append.sh
# ============================================================
# shellcheck source=../bench/lib/ledger-append.sh
source "$lib_dir/ledger-append.sh"

ledger_path="$tmp/ledger/tier1.jsonl"
ledger_append "$ledger_path" '{"a":1}'
assert_eq '0' "$?" 'ledger_append creates the ledger directory and appends the first line'
ledger_append "$ledger_path" '{"a":2}'
assert_eq '0' "$?" 'a second ledger_append call strictly appends'
assert_eq '2' "$(wc -l < "$ledger_path")" 'the ledger has exactly two lines after two appends'
assert_eq '{"a":1}' "$(sed -n '1p' "$ledger_path")" 'the first line is untouched by the second append'

ln -s "$ledger_path" "$tmp/ledger/via-symlink.jsonl"
ledger_append "$tmp/ledger/via-symlink.jsonl" '{"a":3}' 2> /dev/null
symlink_rc=$?
assert_eq '1' "$symlink_rc" 'ledger_append refuses to write through a symlink'

ledger_append "$ledger_path" $'{"a":4}\n{"a":5}' 2> /dev/null
newline_rc=$?
assert_eq '1' "$newline_rc" 'ledger_append refuses a JSON_LINE with an embedded newline (would silently split into two rows)'

# ============================================================
# bench/run-trial.sh -- end-to-end dry-run orchestration
# ============================================================
run_trial_out=''
run_trial_rc=0
run_trial_case() {
    run_trial_rc=0
    run_trial_out=$(PATH="$gh_bin_dir:$PATH" GH_STUB_REMAINING=5000 GH_STUB_RESET=9999999999 \
        bash "$run_trial" "$@" 2>&1) || run_trial_rc=$?
}

base_args=(
    --old-config "$fixtures/config/cap-old-match.toml"
    --new-config "$fixtures/config/cap-new-match.toml"
    --arm new
    --plugin-sha 53e7e8c850380444cd4fb0edb25ebfd8adb32b61
    --assigned-model gpt-5.6-luna
    --assigned-effort low
    --orchestrator-session "$sessions/orchestrator.jsonl"
    --worker-session "$sessions/worker-1.jsonl"
    --worker-session "$sessions/worker-2.jsonl"
    --timestamp 2026-08-20T00:00:00Z
)

assert_eq 'yes' "$([[ -x $run_trial ]] && printf yes || printf no)" 'bench/run-trial.sh is executable'

run_trial_case
assert_eq '2' "$run_trial_rc" 'no arguments at all exits 2 with usage'
assert_contains "$run_trial_out" 'Usage' 'the no-argument case prints usage'

# -- happy path: the gold tree scores 10/10, default mode is dry-run -------
gold_ledger="$tmp/ledger-gold.jsonl"
gold_state="$tmp/state-gold"
run_trial_case --fixture "$repo_root/bench/gold/tally" --run-id trial-gold \
    --ledger "$gold_ledger" --state-dir "$gold_state" \
    "${base_args[@]}"
assert_eq '0' "$run_trial_rc" 'a full dry-run trial against the gold tree succeeds (no explicit --dry-run needed: it is the default)'
assert_eq '1' "$(wc -l < "$gold_ledger")" 'exactly one ledger record is appended per trial'
gold_score=$(jq -r '.acceptance.score' "$gold_ledger")
gold_total=$(jq -r '.acceptance.total' "$gold_ledger")
assert_eq '10' "$gold_score" 'the gold tree scores 10/10 through the full harness, not just through run-accept.sh directly'
assert_eq '10' "$gold_total" 'ten oracle suites were evaluated'
assert_eq 'false' "$(jq -r '.void' "$gold_ledger")" 'a tier-matched trial is not void'

# -- the untouched fixture skeleton scores 0/10 ------------------------------
fixture_ledger="$tmp/ledger-fixture.jsonl"
fixture_state="$tmp/state-fixture"
run_trial_case --fixture "$repo_root/bench/fixtures/tally" --run-id trial-fixture \
    --ledger "$fixture_ledger" --state-dir "$fixture_state" \
    "${base_args[@]}"
assert_eq '0' "$run_trial_rc" 'a dry-run trial against the untouched skeleton still completes successfully'
assert_eq '0' "$(jq -r '.acceptance.score' "$fixture_ledger")" 'the untouched skeleton scores 0/10 -- the oracle is not fooled by an unsolved trial'

# -- container lifecycle really ran and really proved destruction ----------
assert_eq 'no' "$([[ -e "$gold_state/running-bench-trial-trial-gold" ]] && printf yes || printf no)" \
    'the trial container state is gone after a successful run -- destruction actually happened, not just claimed'
assert_contains "$run_trial_out" 'container destroyed and verified gone' \
    'run-trial.sh prints its own destruction proof, not just a destroy call'

# -- concurrency cap gate aborts BEFORE the container or ledger are touched -
abort_ledger="$tmp/ledger-abort.jsonl"
abort_state="$tmp/state-abort"
run_trial_case --fixture "$repo_root/bench/fixtures/tally" --run-id trial-abort \
    --ledger "$abort_ledger" --state-dir "$abort_state" \
    --old-config "$fixtures/config/cap-old-match.toml" \
    --new-config "$fixtures/config/cap-new-mismatch.toml" \
    --arm new --plugin-sha 53e7e8c850380444cd4fb0edb25ebfd8adb32b61 \
    --assigned-model gpt-5.6-luna --assigned-effort low \
    --orchestrator-session "$sessions/orchestrator.jsonl" \
    --worker-session "$sessions/worker-1.jsonl" \
    --timestamp 2026-08-20T00:00:00Z
assert_eq '1' "$run_trial_rc" 'a concurrency-cap mismatch aborts the whole trial'
assert_eq 'no' "$([[ -e $abort_ledger ]] && printf yes || printf no)" \
    'an aborted trial never creates a ledger file, let alone appends a row -- abort means abort before spend'
assert_eq 'no' "$([[ -d $abort_state/home ]] && printf yes || printf no)" \
    'an aborted trial never even builds the (baked-empty) home directory -- the cap gate runs first'

# -- selected_issues defaults to the real bench/issues/*.md set -------------
assert_eq '10' "$(jq -r '.selected_issues | length' "$gold_ledger")" \
    'selected_issues defaults to all ten frozen bench/issues/*.md ids when --selected-issues is omitted'
assert_contains "$(jq -r '.selected_issues | join(",")' "$gold_ledger")" 'tally-01' \
    'the derived selected_issues set includes a real issue id from bench/issues/'

finish
