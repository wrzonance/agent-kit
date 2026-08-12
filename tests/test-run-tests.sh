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
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-markdown-blocks.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/tests/lint-skill-invocations.sh"
    mkdir -p "$dir/tests/stub"
    cp -- "$root/tests/stub/gh" "$dir/tests/stub/gh"
    chmod +x "$dir/tests/run-tests.sh" "$dir/tests/lint-markdown-blocks.sh" \
        "$dir/tests/lint-skill-invocations.sh" "$dir/tests/stub/gh"
    for suite in alpha beta; do
        cat >"$dir/tests/test-$suite.sh" <<EOF
#!/usr/bin/env bash
trace=\${TRACE:?}
printf '%s-start\\n' '$suite' >> "\$trace"
sleep 1
printf '%s-end\\n' '$suite' >> "\$trace"
printf '$suite summary\\n'
EOF
        chmod +x "$dir/tests/test-$suite.sh"
    done
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

rc=$(run_fixture 2 alpha,beta)
assert_eq '0' "$rc" 'parallel focused run succeeds'
parallel_trace=$(<"$trace")
assert_contains "$parallel_trace" 'alpha-start' 'parallel run starts alpha'
assert_contains "$parallel_trace" 'beta-start' 'parallel run starts beta'
assert_line_order 'combined output remains deterministic despite parallel workers' \
    "$(grep -n 'alpha summary' "$tmp/out" | head -1 | cut -d: -f1)" \
    "$(grep -n 'beta summary' "$tmp/out" | head -1 | cut -d: -f1)"

finish
