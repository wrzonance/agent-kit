#!/usr/bin/env bash
# bench/accept/run-accept.sh -- score a Tally tree against every per-issue
# oracle suite under bench/accept/tally-*.test.mjs (epic #152, issue #326).
#
# Usage: bench/accept/run-accept.sh TARGET_DIR
#
# TARGET_DIR is any tree shaped like bench/fixtures/tally (the untouched
# skeleton, expected 0/10), bench/gold/tally (the reference solution,
# expected 10/10), or a trial agent's tree. Runs each
# bench/accept/tally-NN.test.mjs against TARGET_DIR through
# BENCH_ACCEPT_TARGET and node's built-in test runner (`node --test`) --
# zero npm dependencies, no network, no installs. Per-issue pass requires
# every case in that issue's suite to be green (see bench/accept/README.md's
# "Scoring contract"). Prints one JSON object to stdout: the per-issue
# pass/fail vector plus a score summary. This script only computes the
# vector -- it never writes a ledger record itself; a later Tier-1 ledger
# slice is the consumer (bench/accept/README.md).
set -euo pipefail

program=${0##*/}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

usage() {
    printf 'Usage: %s TARGET_DIR\n' "$program" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
target=$1
[[ -d $target ]] || die "target directory not found: $target"
command -v node > /dev/null 2>&1 || die 'node is required and was not found on PATH'
command -v jq > /dev/null 2>&1 || die 'jq is required and was not found on PATH'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
target_abs=$(cd -- "$target" && pwd -P) || die "could not resolve target directory: $target"

shopt -s nullglob
suites=("$script_dir"/tally-*.test.mjs)
shopt -u nullglob
[[ ${#suites[@]} -gt 0 ]] || die "no oracle suites found under $script_dir"

results='{}'
passed=0
total=0
for suite in "${suites[@]}"; do
    id=$(basename "$suite" .test.mjs)
    total=$((total + 1))
    if BENCH_ACCEPT_TARGET="$target_abs" node --test "$suite" > /dev/null 2>&1; then
        status=pass
        passed=$((passed + 1))
    else
        status=fail
    fi
    results=$(jq -c --arg id "$id" --arg status "$status" '. + {($id): $status}' <<< "$results")
done

jq -n --argjson results "$results" --argjson score "$passed" --argjson total "$total" \
    '{results: $results, score: $score, total: $total}'
