#!/usr/bin/env bash
# Suite: bench/accept/run-accept.sh -- the hidden node --test acceptance
# oracle over bench/gold/tally and bench/fixtures/tally (issue #326).
#
# Proves the acceptance contract the issue body states directly: the gold
# tree scores 10/10, the untouched skeleton scores 0/10, every suite runs
# offline with zero installs, and bench/accept/ never gets pulled into the
# Tier-1 ledger (that is a later slice's job -- see
# tests/test-bench-preregistration.sh).
set -uo pipefail

TEST_NAME='bench accept'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_accept="$repo_root/bench/accept/run-accept.sh"
gold="$repo_root/bench/gold/tally"
fixture="$repo_root/bench/fixtures/tally"

RUN_RC=0
RUN_OUT=''
run() {
    RUN_RC=0
    RUN_OUT=$("$@" 2>&1) || RUN_RC=$?
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

finish
exit $?
