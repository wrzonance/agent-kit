#!/usr/bin/env bash
# Suite: the long-verify variant of the live bench fixture (AK_BENCH_VERIFY_SLEEP). Field workers waited minutes on
# `ak verify` and polled it 17 to 92 times each; the tally fixture's verify ends in a second, so how a worker waits on
# a long command was never measured. Offline: only the config writer and the fixture label are exercised.
# shellcheck disable=SC2016 # the trial-tui pins are literal source text
set -uo pipefail

TEST_NAME='bench verify variant'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# The globals trial-lib.sh documents for its config writer.
state="$tmp/sandbox.json"
printf '{"repo":"acme/bench","board":{"number":12}}\n' >"$state"
repo=acme/bench worker_model=m worker_effort=high
log() { :; }
# shellcheck source=../bench/live/trial-lib.sh
source "$repo_root/bench/live/trial-lib.sh"

unset AK_BENCH_VERIFY_SLEEP
write_bench_config "$tmp/plain"
config=$(cat "$tmp/plain/.agent/config.env")
assert_contains "$config" 'AGENT_CMD_VERIFY="node test/smoke.mjs"' 'the default fixture verifies with the quick smoke test'
assert_contains "$config" 'AGENT_CMD_TEST="node test/smoke.mjs"' 'and tests with it'
assert_eq '' "$(fixture_variant)" 'the default fixture has no variant in its label'

export AK_BENCH_VERIFY_SLEEP=90
write_bench_config "$tmp/slow"
config=$(cat "$tmp/slow/.agent/config.env")
assert_contains "$config" 'AGENT_CMD_VERIFY="sleep 90 && node test/smoke.mjs"' 'the variant verify runs 90 s before the smoke test'
assert_contains "$config" 'AGENT_CMD_TEST="sleep 90 && node test/smoke.mjs"' 'so does the full check'
assert_eq '+verify90s' "$(fixture_variant)" 'the variant is named in the fixture label'

export AK_BENCH_VERIFY_SLEEP='90; touch pwned'
out=$(write_bench_config "$tmp/bad" 2>&1); rc=$?
assert_eq 1 "$((rc != 0))" 'a sleep that is not whole seconds is refused'
assert_contains "$out" 'AK_BENCH_VERIFY_SLEEP must be whole seconds' 'the refusal names the variable'
assert_eq no "$([[ -e $tmp/bad/.agent/config.env ]] && echo yes || echo no)" 'and no config is written'
unset AK_BENCH_VERIFY_SLEEP

# The trial row's fixture label carries the variant, so a long-verify batch is never pooled with the plain fixture.
tui=$(cat "$repo_root/bench/live/trial-tui.sh")
assert_contains "$tui" 'variant=$(fixture_variant) || exit 2' 'trial-tui refuses a bad variant before it touches the sandbox'
assert_contains "$tui" 'fixture_label="tally-waves-v1$variant:' \
    'trial-tui labels its rows with the variant'

finish
