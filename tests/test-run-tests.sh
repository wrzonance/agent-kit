#!/usr/bin/env bash
# Suite: run-tests.sh scheduling, deterministic replay, and focus selection.
set -uo pipefail

TEST_NAME='run-tests'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

assert_line_order() {
    local msg=$1 first=$2 second=$3
    if [[ $first =~ ^[0-9]+$ && $second =~ ^[0-9]+$ && $first -lt $second ]]; then
        _pass "$msg"
    else
        _fail "$msg" "first line: $first" "second line: $second"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_fixture() {
    local dir=$tmp/fixture
    mkdir -p "$dir/tests" "$dir/agentkit/skills" "$dir/agentkit/hooks" \
        "$dir/agentkit/.claude-plugin" "$dir/agentkit/.codex-plugin"
    printf '{}' >"$dir/agentkit/.claude-plugin/plugin.json"
    printf '{}' >"$dir/agentkit/.codex-plugin/plugin.json"
    printf '{}' >"$dir/agentkit/hooks/hooks.json"
    cp -- "$root/tests/run-tests.sh" "$dir/tests/run-tests.sh"
    printf 'alpha\t100\nbeta\t80\n' >"$dir/tests/suite-weights.tsv"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-markdown-blocks.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-skill-invocations.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-skill-size.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-helper-size.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-collation.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-helper-refs.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-reference-manifest.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-versioned-plugin-paths.sh"
    mkdir -p "$dir/tests/stub"
    cp -- "$root/tests/stub/gh" "$dir/tests/stub/gh"
    chmod +x "$dir/tests/run-tests.sh" "$dir/tests/lint-markdown-blocks.sh" \
        "$dir/tests/lint-skill-invocations.sh" "$dir/tests/lint-skill-size.sh" \
        "$dir/tests/lint-helper-size.sh" \
        "$dir/tests/lint-collation.sh" \
        "$dir/tests/lint-helper-refs.sh" "$dir/tests/lint-reference-manifest.sh" \
        "$dir/tests/lint-versioned-plugin-paths.sh" \
        "$dir/tests/stub/gh"
    for suite in alpha beta; do
        cat >"$dir/tests/test-$suite.sh" <<EOF
#!/usr/bin/env bash
trace=\${TRACE:?}
printf '%s-start\\n' '$suite' >> "\$trace"
if [[ -n \${START_FIFO:-} ]]; then
    printf '%s-start\\n' '$suite' >"\$START_FIFO"
    read -r command <"\$CONTROL_DIR/$suite"
    [[ \$command == release ]] || exit 8
fi
printf '%s-end\\n' '$suite' >> "\$trace"
printf '$suite summary\\n'
EOF
        chmod +x "$dir/tests/test-$suite.sh"
    done
    cat >"$dir/tests/test-gamma.sh" <<'EOF'
#!/usr/bin/env bash
trace=${TRACE:?}
printf 'gamma-start\n' >> "$trace"
if [[ -n ${START_FIFO:-} ]]; then
    printf 'gamma-start\n' >"$START_FIFO"
    read -r command <"$CONTROL_DIR/gamma"
    [[ $command == release ]] || exit 8
fi
printf 'gamma-end\n' >> "$trace"
printf 'gamma summary\n'
EOF
    chmod +x "$dir/tests/test-gamma.sh"
cat >"$dir/tests/test-fail.sh" <<'EOF'
#!/usr/bin/env bash
trace=${TRACE:?}
printf 'fail-start\n' >> "$trace"
printf 'fail summary\n'
exit 7
EOF
    chmod +x "$dir/tests/test-fail.sh"
    printf '%s' "$dir"
}

fixture=$(make_fixture)
trace=$tmp/trace

run_fixture() {
    local jobs=$1 focus=$2
    : >"$trace"
    local rc=0
    if [[ -n $focus ]]; then
        AGENT_TEST_JOBS=$jobs TRACE="$trace" \
            "$fixture/tests/run-tests.sh" --only "$focus" >"$tmp/out" 2>&1 || rc=$?
    else
        AGENT_TEST_JOBS=$jobs TRACE="$trace" \
            "$fixture/tests/run-tests.sh" >"$tmp/out" 2>&1 || rc=$?
    fi
    printf '%s' "$rc"
}

run_shard_fixture() {
    local shard=$1 locale=${2:-C}
    : >"$trace"
    local rc=0
    LC_ALL=$locale AGENT_TEST_JOBS=1 TRACE="$trace" \
        "$fixture/tests/run-tests.sh" --shard "$shard" >"$tmp/out" 2>&1 || rc=$?
    printf '%s' "$rc"
}

run_parallel_fixture() {
    : >"$trace"
    rm -f -- "$tmp/start.fifo" "$tmp/alpha" "$tmp/beta" "$tmp/gamma"
    mkfifo "$tmp/start.fifo" "$tmp/alpha" "$tmp/beta" "$tmp/gamma"
    AGENT_TEST_JOBS=2 TRACE="$trace" START_FIFO="$tmp/start.fifo" \
        CONTROL_DIR="$tmp" "$fixture/tests/run-tests.sh" --only alpha,beta,gamma \
        >"$tmp/out" 2>&1 &
    parallel_pid=$!
    # Read-write open: the test itself keeps one writer on the fifo, so the
    # writer count never drops to zero between the two suites' one-shot writes.
    # Without this, a suite that writes and closes before its sibling opens
    # hands the reader EOF and the second read returns empty (observed on a
    # 2-core CI runner; unobservable on wide local machines).
    exec 9<>"$tmp/start.fifo"
}

wait_for_trace() {
    local marker=$1 attempt
    for ((attempt = 0; attempt < 100000; attempt++)); do
        grep -Fxq "$marker" "$trace" && return 0
    done
    _fail "trace marker appears: $marker" 'marker did not appear before bounded wait expired'
    return 1
}

rc=$(run_fixture 1 alpha,beta)
assert_eq '0' "$rc" 'known --only names run successfully'
out=$(<"$tmp/out")
assert_contains "$out" 'alpha summary' 'focused output includes the selected alpha suite'
assert_contains "$out" 'beta summary' 'focused output includes the selected beta suite'
assert_not_contains "$out" 'fail summary' 'focused output excludes unselected suites'
assert_line_order 'focused suites replay in name order' \
    "$(grep -n 'alpha summary' <<<"$out" | head -1 | cut -d: -f1)" \
    "$(grep -n 'beta summary' <<<"$out" | head -1 | cut -d: -f1)"

rc=$(run_fixture 1 nope)
assert_eq '2' "$rc" 'unknown --only is a usage error'
out=$(<"$tmp/out")
assert_contains "$out" 'unknown suite name' 'unknown focus names are reported'
assert_contains "$out" 'alpha' 'usage errors list valid suite names'
assert_contains "$out" 'beta' 'usage errors list every valid suite name'

for invalid_focus in ',alpha' 'alpha,' 'alpha,,beta'; do
    rc=$(run_fixture 1 "$invalid_focus")
    assert_eq '2' "$rc" "empty suite name is rejected: $invalid_focus"
    out=$(<"$tmp/out")
    assert_contains "$out" 'empty suite name' \
        "empty suite error is explained: $invalid_focus"
    assert_contains "$out" 'Usage:' "empty suite usage is shown: $invalid_focus"
done

rc=$(run_fixture 1 fail)
assert_eq '1' "$rc" 'a suite failure propagates a nonzero exit status'
out=$(<"$tmp/out")
assert_contains "$out" 'FAILURES ABOVE' 'a failing suite keeps the failure footer'
assert_contains "$out" 'fail summary' 'a failing suite output is retained'

rc=$(run_fixture 1 alpha,beta)
assert_eq '0' "$rc" 'serial focused run succeeds'
serial_trace=$(<"$trace")
assert_eq $'alpha-start\nalpha-end\nbeta-start\nbeta-end' "$serial_trace" \
    'AGENT_TEST_JOBS=1 preserves serial suite execution'

run_parallel_fixture
first_event=$(read -t 30 -r event <&9; printf '%s' "$event")
second_event=$(read -t 30 -r event <&9; printf '%s' "$event")
assert_contains "$first_event" '-start' 'first synchronized event is a suite start'
assert_contains "$second_event" '-start' 'second synchronized event is a suite start'
parallel_trace=$(<"$trace")
assert_not_contains "$parallel_trace" 'alpha-end' \
    'parallel mode has no alpha completion while both are synchronized'
assert_not_contains "$parallel_trace" 'beta-end' \
    'parallel mode has no beta completion while both are synchronized'
printf 'release\n' >"$tmp/alpha"
wait_for_trace 'alpha-end'
parallel_trace=$(<"$trace")
assert_contains "$parallel_trace" 'alpha-end' \
    'the first released suite reports completion before the next suite starts'
wait_for_trace 'gamma-start'
gamma_start_line=$(grep -n '^gamma-start$' "$trace" | cut -d: -f1)
alpha_end_line=$(grep -n '^alpha-end$' "$trace" | cut -d: -f1)
assert_line_order 'the third suite starts only after one of the first two finishes' \
    "$alpha_end_line" "$gamma_start_line"
printf 'release\n' >"$tmp/beta"
wait_for_trace 'beta-end'
assert_contains "$(<"$trace")" 'beta-end' 'the second initial suite completes after release'
printf 'release\n' >"$tmp/gamma"
wait_for_trace 'gamma-end'
assert_contains "$(<"$trace")" 'gamma-end' 'the admitted third suite completes after release'
exec 9<&-
rc=0
wait "$parallel_pid" || rc=$?
assert_eq '0' "$rc" 'parallel synchronized run succeeds'
parallel_trace=$(<"$trace")
gamma_start_line=$(grep -n '^gamma-start$' "$trace" | cut -d: -f1)
beta_end_line=$(grep -n '^beta-end$' "$trace" | cut -d: -f1)
assert_line_order 'parallel trace admits gamma before the still-blocked beta finishes' \
    "$gamma_start_line" "$beta_end_line"
assert_line_order 'combined output remains deterministic despite parallel workers' \
    "$(grep -n 'alpha summary' "$tmp/out" | head -1 | cut -d: -f1)" \
    "$(grep -n 'beta summary' "$tmp/out" | head -1 | cut -d: -f1)"

all_shards=$tmp/all-shards
: >"$all_shards"
for shard in 1/2 2/2; do
    run_shard_fixture "$shard" > /dev/null
    cat -- "$trace" >>"$all_shards"
done
for suite in alpha beta gamma fail; do
    assert_eq '1' "$(grep -c "^$suite-start$" "$all_shards")" \
        "shards partition $suite exactly once"
done

run_shard_fixture 1/2 C > /dev/null
assert_contains "$(<"$trace")" 'alpha-start' \
    'longest-first balancing puts the heaviest recorded suite in shard one'
assert_not_contains "$(<"$trace")" 'beta-start' \
    'longest-first balancing puts the next recorded suite in shard two'
c_selection=$(grep -- '-start$' "$trace" | sort)
if locale -a 2>/dev/null | grep -Fxiq 'C.utf8'; then
    run_shard_fixture 1/2 C.utf8 > /dev/null
    utf8_selection=$(grep -- '-start$' "$trace" | sort)
    assert_eq "$c_selection" "$utf8_selection" \
        'shard selection is deterministic across available locales'
fi

for invalid_shard in 0/2 3/2 1/0 one/two 1/2/3; do
    rc=$(run_shard_fixture "$invalid_shard")
    assert_eq '2' "$rc" "invalid shard is rejected: $invalid_shard"
    assert_contains "$(<"$tmp/out")" 'invalid --shard value' \
        "invalid shard error is explained: $invalid_shard"
done

rc=0
AGENT_TEST_JOBS=1 TRACE="$trace" \
    "$fixture/tests/run-tests.sh" --only alpha --shard 1/2 >"$tmp/out" 2>&1 || rc=$?
assert_eq '2' "$rc" '--only and --shard cannot select competing suite sets'

: >"$trace"
rc=0
AGENT_TEST_JOBS=1 TRACE="$trace" \
    "$fixture/tests/run-tests.sh" --gates-only >"$tmp/out" 2>&1 || rc=$?
assert_eq '0' "$rc" '--gates-only runs the static gates successfully'
assert_eq '' "$(<"$trace")" '--gates-only does not run unit suites'

ci_text=$(<"$root/.github/workflows/ci.yml")
assert_contains "$ci_text" 'matrix:' 'CI defines a suite matrix'
assert_contains "$ci_text" 'shard: [1, 2, 3, 4]' 'CI starts with four suite shards'
assert_contains "$ci_text" 'tests/run-tests.sh --gates-only' \
    'CI runs static gates independently from suites'
# shellcheck disable=SC2016  # GitHub expression is literal workflow syntax.
assert_contains "$ci_text" 'tests/run-tests.sh --shard ${{ matrix.shard }}/4' \
    'each matrix job runs its selected suite shard'
assert_contains "$ci_text" 'name: gates and suites' \
    'CI preserves the stable aggregate check name'
assert_contains "$ci_text" 'needs: [gates, suites]' \
    'the aggregate waits for static gates and every matrix shard'
# shellcheck disable=SC2016  # GitHub expression is literal workflow syntax.
assert_contains "$ci_text" 'if: ${{ always() }}' \
    'the aggregate runs after failed, cancelled, or skipped prerequisites'
assert_contains "$ci_text" 'needs.gates.result' \
    'the aggregate checks the static-gate result explicitly'
assert_contains "$ci_text" 'needs.suites.result' \
    'the aggregate checks the matrix result explicitly'

finish
