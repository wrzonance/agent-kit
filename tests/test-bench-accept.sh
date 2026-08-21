#!/usr/bin/env bash
# Suite: bench/accept/run-accept.sh -- the hidden node --test acceptance
# oracle over bench/gold/tally and bench/fixtures/tally (issue #326).
#
# Proves the acceptance contract the issue body states directly: the gold
# tree scores 10/10, the untouched skeleton scores 0/10, every suite runs
# offline with zero installs, and bench/accept/ never gets pulled into the
# Tier-1 ledger (that is a later slice's job -- see
# tests/test-bench-preregistration.sh).
#
# Also proves the PR #363 review findings stay fixed: a target that
# monkeypatches assert.ok/assert.equal, or that calls process.exit() while
# being imported, or that hangs forever, must never score a false pass
# (finding 1); a hung suite must be killed and scored fail, never left to
# stall the run forever (finding 2).
set -uo pipefail

TEST_NAME='bench accept'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_accept="$repo_root/bench/accept/run-accept.sh"
gold="$repo_root/bench/gold/tally"
fixture="$repo_root/bench/fixtures/tally"
tally_03_suite="$repo_root/bench/accept/tally-03.test.mjs"

RUN_RC=0
RUN_OUT=''
run() {
    RUN_RC=0
    RUN_OUT=$("$@" 2>&1) || RUN_RC=$?
}

# Builds a forged target tree at $1 (a fresh mktemp -d): a copy of the gold
# tree with $2 prepended to src/store.js, the module every tally-03 test
# imports. Real forgery attempts prepend code that runs at import time,
# before any of the module's own real exports are even defined.
build_forged_target() {
    local dir=$1 prelude=$2
    cp -r "$gold/." "$dir/"
    { printf '%s\n' "$prelude"; cat "$gold/src/store.js"; } > "$dir/src/store.js"
}

# --- shipped, executable, zero installs to reach node:test --------------
assert_eq 'yes' "$([[ -x $run_accept ]] && printf yes || printf no)" 'run-accept.sh is executable'

suite_count=$(find "$repo_root/bench/accept" -maxdepth 1 -name 'tally-*.test.mjs' | wc -l | tr -d ' ')
assert_eq '10' "$suite_count" 'exactly ten per-issue oracle suites exist, one per bench/issues/*.md'

node_modules_count=$(find "$repo_root/bench/accept" -maxdepth 3 -name node_modules -o -name package.json | wc -l | tr -d ' ')
assert_eq '0' "$node_modules_count" 'bench/accept/ carries no package.json/node_modules -- zero npm dependencies'

# --- usage / argument validation -----------------------------------------
run "$run_accept"
assert_eq '2' "$RUN_RC" 'no TARGET_DIR argument exits 2'
assert_contains "$RUN_OUT" 'Usage' 'no TARGET_DIR argument prints usage'

run "$run_accept" '/nonexistent/path/for/bench-accept-test'
assert_eq '1' "$RUN_RC" 'a nonexistent target directory fails'

# --- the acceptance contract itself --------------------------------------
run "$run_accept" "$gold"
assert_eq '0' "$RUN_RC" 'run-accept.sh exits 0 against the gold tree'
gold_score=$(jq -r '.score' <<< "$RUN_OUT" 2> /dev/null)
gold_total=$(jq -r '.total' <<< "$RUN_OUT" 2> /dev/null)
assert_eq '10' "$gold_score" 'the gold tree scores 10'
assert_eq '10' "$gold_total" 'run-accept.sh evaluated all ten oracle suites against the gold tree'
gold_fail_count=$(jq -r '[.results[] | select(. != "pass")] | length' <<< "$RUN_OUT" 2> /dev/null)
assert_eq '0' "$gold_fail_count" 'every per-issue suite passes against the gold tree'

run "$run_accept" "$fixture"
assert_eq '0' "$RUN_RC" 'run-accept.sh exits 0 against the untouched fixture skeleton'
fixture_score=$(jq -r '.score' <<< "$RUN_OUT" 2> /dev/null)
assert_eq '0' "$fixture_score" 'the untouched Tally skeleton scores 0'
fixture_pass_count=$(jq -r '[.results[] | select(. == "pass")] | length' <<< "$RUN_OUT" 2> /dev/null)
assert_eq '0' "$fixture_pass_count" 'no per-issue suite passes against the untouched fixture skeleton'

# --- the oracle stays hidden from the trial skeleton ---------------------
assert_eq 'no' "$([[ -e "$fixture/bench" || -e "$fixture/accept" ]] && printf yes || printf no)" \
    'the fixture skeleton itself carries no bench/accept path a trial container could read'

fixture_reference_count=$(grep -rl 'bench/accept' "$fixture" 2> /dev/null | wc -l | tr -d ' ')
assert_eq '0' "$fixture_reference_count" 'no file under the fixture skeleton references bench/accept/'

# --- run-accept.sh only computes the vector; it never writes a ledger ----
ledger_write_count=$(grep -c 'bench/results' "$run_accept" || true)
assert_eq '0' "$ledger_write_count" 'run-accept.sh never touches bench/results/*.jsonl -- scoring is not ledger-writing'

tier1_ledger="$repo_root/bench/results/tier1.jsonl"
assert_eq 'no' "$([[ -e $tier1_ledger ]] && printf yes || printf no)" \
    'no bench/results/tier1.jsonl exists yet -- this slice does not introduce a Tier-1 record'

# --- PR #363 review finding 1: the oracle cannot be forged -----------------
# Each forged target is a real gold-tree copy (so a leaked forgery would
# otherwise show up as a bogus pass) with a prelude injected into
# src/store.js -- the module tally-03's suite imports. run_scenario_suite
# runs bench/accept/tally-03.test.mjs directly against it, bypassing
# run-accept.sh's own timeout wrapper so these assertions pin
# lib/isolated.mjs's own per-scenario timeout, not the outer one.
forge_tmp=$(mktemp -d)
trap 'rm -rf -- "$forge_tmp"' EXIT

run_scenario_suite() {
    local target=$1
    shift
    RUN_RC=0
    RUN_OUT=$(BENCH_ACCEPT_TARGET="$target" "$@" node --test "$tally_03_suite" 2>&1) || RUN_RC=$?
}

# Calls runScenario(scenario_id) directly (bypassing node:test) against
# $target and prints the observation as JSON -- used below to inspect the
# exact value an attempted IPC forgery does or does not produce, rather
# than only whether some assertion downstream happened to notice.
#
# Runs the driver from a real .mjs file rather than `node -e`/
# `--input-type=module`: fork() inherits the running process's own
# execArgv into the child by default, and a driver started with
# --input-type=module poisons scenario-runner.mjs's own fork of itself
# with that same flag, breaking the very isolation this test verifies.
run_scenario_direct_driver="$forge_tmp/run-scenario-direct.mjs"
cat > "$run_scenario_direct_driver" << DRIVEREOF
import { runScenario } from '$repo_root/bench/accept/lib/isolated.mjs';
const obs = await runScenario(process.argv[2]);
console.log(JSON.stringify(obs));
DRIVEREOF
run_scenario_direct() {
    local target=$1 scenario_id=$2
    RUN_RC=0
    RUN_OUT=$(BENCH_ACCEPT_TARGET="$target" node "$run_scenario_direct_driver" "$scenario_id" 2>&1) || RUN_RC=$?
}

assert_monkeypatch_target="$forge_tmp/monkeypatch"
mkdir -p "$assert_monkeypatch_target"
build_forged_target "$assert_monkeypatch_target" \
    "import assert from 'node:assert/strict'; assert.ok = () => {}; assert.equal = () => {}; assert.deepEqual = () => {};"
run_scenario_suite "$assert_monkeypatch_target"
assert_eq '0' "$RUN_RC" 'a target that only monkeypatches assert (but is otherwise correct) still scores pass'

exit_target="$forge_tmp/exit"
mkdir -p "$exit_target"
build_forged_target "$exit_target" 'process.exit(0);'
run_scenario_suite "$exit_target"
assert_eq '1' "$RUN_RC" 'a target that calls process.exit(0) at import time scores fail, never a false pass'
assert_contains "$RUN_OUT" 'exited without sending a result' \
    'process.exit(0) at import is reported as a failed call, not as an ambiguous pass'

hang_target="$forge_tmp/hang"
mkdir -p "$hang_target"
build_forged_target "$hang_target" ''
# A synchronous busy loop inside undoRemove -- not just a background timer
# -- blocks the child's event loop entirely, so only the parent's
# fork()-level watchdog (never the child's own cooperative cleanup) can
# recover. BENCH_ACCEPT_SCENARIO_TIMEOUT_MS keeps this test fast rather
# than waiting out the 10s production default.
python3 - "$hang_target/src/store.js" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as handle:
    content = handle.read()
content = content.replace(
    'export function undoRemove(state) {',
    'export function undoRemove(state) {\n  while (true) { /* busy loop: never yields */ }',
)
with open(path, 'w') as handle:
    handle.write(content)
PYEOF
run_scenario_suite "$hang_target" env BENCH_ACCEPT_SCENARIO_TIMEOUT_MS=500
assert_eq '1' "$RUN_RC" 'a target whose call never returns is killed and scores fail, never left to hang the run'
assert_contains "$RUN_OUT" 'did not respond within' 'the hang is reported as a timeout, not silently swallowed'

# --- PR #363 review finding 1 (round 2): forged IPC results are rejected --
# Forking put target code in a different process than the oracle's own
# assertions, but the fork still had process.send reachable while target
# code was imported, and lib/isolated.mjs accepted the first message with
# an `ok` field unconditionally -- a target could call
# process.send({ok: true, value: {...}}) at import time and forge the
# entire observation. Both halves of the fix are exercised directly
# against runScenario(), not just through a suite's own assertions, so a
# forged value being accepted is caught even if it happened to also
# satisfy that suite's checks.
forge_send_target="$forge_tmp/forge-send"
mkdir -p "$forge_send_target"
build_forged_target "$forge_send_target" \
    "if (typeof process.send === 'function') { process.send({ ok: true, value: { FORGED_BY_TARGET_CODE: true } }); }"
run_scenario_direct "$forge_send_target" tally-03
assert_eq '0' "$RUN_RC" 'a target calling process.send at import does not break the real scenario'
assert_not_contains "$RUN_OUT" 'FORGED_BY_TARGET_CODE' \
    'a target-forged process.send message at import is never accepted as the observation'
assert_contains "$RUN_OUT" 'undoRemoveFnType' 'the real, correlated scenario result is returned instead'

forge_ipc_target="$forge_tmp/forge-ipc"
mkdir -p "$forge_ipc_target"
build_forged_target "$forge_ipc_target" \
    "if (typeof process._send === 'function') { process._send(JSON.stringify({ ok: true, value: { FORGED_BY_TARGET_CODE: true }, token: 'not-the-real-token' })); }"
run_scenario_direct "$forge_ipc_target" tally-03
assert_eq '0' "$RUN_RC" 'a target sending a wrong-token IPC message directly does not break the real scenario'
assert_not_contains "$RUN_OUT" 'FORGED_BY_TARGET_CODE' \
    'an IPC message with the wrong (or absent) correlation token is never accepted as the observation'
assert_contains "$RUN_OUT" 'undoRemoveFnType' 'the real, correlated scenario result is returned instead'

# --- PR #363 review finding 2: HTML-comment markup scores fail -----------
# lib/dom-stub.mjs used to tokenize tags inside HTML comments as real
# elements, so a target could get acceptance credit for markup it never
# actually rendered -- only mentioned it in a comment.
dom_stub_comment_out=$(node --input-type=module -e "
import assert from 'node:assert/strict';
import { parseFragment, query, textContent } from '$repo_root/bench/accept/lib/dom-stub.mjs';
const html = '<!-- <p class=\"tally-empty\">No tallies yet -- add one above.</p> -->';
const root = parseFragment(html);
assert.equal(query(root, 'p.tally-empty'), null, 'markup inside a comment must not parse as an element');
assert.equal(textContent(root), '', 'comment text must not surface as text content');
console.log('OK');
" 2>&1)
dom_stub_comment_rc=$?
assert_eq '0' "$dom_stub_comment_rc" 'dom-stub ignores markup that only appears inside an HTML comment'
assert_contains "$dom_stub_comment_out" 'OK' 'the HTML-comment regression check ran to completion'

# --- PR #363 review finding 3: smoke timeouts kill with SIGKILL ----------
# spawnSync's default killSignal is SIGTERM, which a smoke script can
# trap and keep running past the deadline in a busy loop, then exit 0 on
# its own -- read back by assertBaseSmokeOk as a clean pass despite
# blowing the timeout. BENCH_ACCEPT_SMOKE_TIMEOUT_MS keeps this fast
# rather than waiting out the 10s production default.
sigterm_target="$forge_tmp/sigterm-smoke"
mkdir -p "$sigterm_target"
cp -r "$gold/." "$sigterm_target/"
cat > "$sigterm_target/test/smoke.mjs" << 'SMOKEEOF'
process.on('SIGTERM', () => { /* trap and ignore -- must not be enough to survive */ });
const start = Date.now();
while (Date.now() - start < 5000) { /* busy loop: blocks the event loop, SIGTERM never gets scheduled */ }
console.log('PASS ignored SIGTERM and finished anyway');
SMOKEEOF
RUN_RC=0
RUN_OUT=$(BENCH_ACCEPT_TARGET="$sigterm_target" BENCH_ACCEPT_SMOKE_TIMEOUT_MS=500 \
    node --test "$repo_root/bench/accept/tally-01.test.mjs" 2>&1) || RUN_RC=$?
assert_eq '1' "$RUN_RC" \
    'a smoke script that traps SIGTERM and keeps running is still killed at the deadline and scores fail'

rm -rf -- "$forge_tmp"
trap - EXIT

finish
exit $?
