#!/usr/bin/env bash
set -euo pipefail
TEST_NAME=rewrite-production
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
driver="$here/probe/rewrite-production.sh"
[[ -f $driver ]] || { printf 'FAIL: bounded production probe preparer missing\n' >&2; exit 1; }
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
mkdir "$temporary/audit" "$temporary/compatibility"
printf 'fixture\n' > "$temporary/audit/prefix-fixture.snapshot"
printf 'fixture\n' > "$temporary/audit/prefix-fixture.command"
printf '{"snapshotPath":"/private/snapshots/fixture"}\n' > "$temporary/audit/prefix-fixture.json"
for file in provider.jsonl events.ndjson execution.json manifest.json; do
    printf '{}\n' > "$temporary/compatibility/$file"
done
printf '\n' > "$temporary/sources.sha256"
output=$(bash "$driver" prepare "$temporary/prepared" "$temporary/audit" "$temporary/compatibility" /fixture/claude)
assert_contains "$output" production-probe-prepared 'preparation is explicitly separate from provider execution'
for mode in control rewrite; do
    assert_rc 0 'each arm has an explicit private attestation specification' -- test -f "$temporary/prepared/$mode/spec.json"
    assert_rc 1 'preparation creates no operator profile pointer' -- test -e "$temporary/prepared/$mode/profile-path"
    assert_rc 1 'preparation never launches a provider' -- test -e "$temporary/prepared/$mode/provider.jsonl"
    shellcheck "$temporary/prepared/$mode/repo/verify.sh"
done
assert_rc 0 'prepared sources are immutable and checksum-verifiable' -- \
    sha256sum -c --status "$temporary/prepared/sources.sha256"
output=$(bash "$driver" prepare-boundaries "$temporary/boundaries" "$temporary/audit" "$temporary/compatibility" /fixture/claude)
assert_contains "$output" production-probe-prepared 'negative preparation never launches providers'
assert_eq '["Bash(pwd)","Bash(printf:*)"]' "$(jq -c .allow "$temporary/boundaries/denied/spec.json")" \
    'denied arm explicitly withholds helper permission'
assert_contains "$(cat "$temporary/boundaries/timeout/prompt.txt")" 'timeout 1000' 'timeout arm requests a bounded native timeout'
assert_rc 0 'negative prepared sources are checksum-verifiable' -- sha256sum -c --status "$temporary/boundaries/sources.sha256"
finish
