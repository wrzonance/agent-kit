#!/usr/bin/env bash
# Regression coverage for case-insensitive environment-neutrality scanning.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='environment neutrality'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -- "$tmp/tests"
cp -a -- "$root/agentkit" "$tmp/"
cp -- "$root/tests/run-tests.sh" "$tmp/tests/"
cp -- "$root/tests/lint-markdown-blocks.sh" "$tmp/tests/"
cp -- "$root/tests/lint-skill-invocations.sh" "$tmp/tests/"
mkdir -- "$tmp/tests/stub"
cp -- "$root/tests/stub/gh" "$tmp/tests/stub/"
for fixture in {1..5}; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$tmp/tests/test-fixture-$fixture.sh"
    chmod +x -- "$tmp/tests/test-fixture-$fixture.sh"
done
printf '%s\n' '<!-- AUTOMATIC REVIEWS ARE OFF -->' \
    >>"$tmp/agentkit/skills/parallel-issues/SKILL.md"

out="$tmp/run-tests.out"
run_rc=0
bash "$tmp/tests/run-tests.sh" >"$out" 2>&1 || run_rc=$?
assert_eq 1 "$run_rc" \
    'run-tests rejects an uppercase banned provider claim'
assert_contains "$(<"$out")" \
    'FAIL  skill guidance hardcodes runtime or provider configuration' \
    'run-tests reports the environment-neutrality failure'

finish
