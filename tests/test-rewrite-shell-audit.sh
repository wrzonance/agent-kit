#!/usr/bin/env bash
set -uo pipefail
TEST_NAME=rewrite-shell-audit
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
driver="$here/probe/rewrite-shell-audit.sh"
if [[ ! -f $driver ]]; then
    _fail 'standalone native-shell audit preparer exists' "$driver missing"
    finish
    exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
probe="$tmp/probe"
bash "$driver" prepare "$probe"
assert_eq 700 "$(stat -c %a "$probe")" 'audit directory is owner-private'
assert_rc 2 'audit cannot launch without root marker' -- bash "$driver" run "$probe" /missing/claude
printf '# private-fixture-value\nexport PATH=/usr/bin:/bin\n' > "$tmp/snapshot"
native="source $tmp/snapshot 2>/dev/null || true && printf agentkit-shell-audit"
out=$(bash "$probe/driver.sh" prefix "$probe" "$native")
assert_eq agentkit-shell-audit "$out" 'prefix forwards native execution without audit stdout'
assert_not_contains "$out" private-fixture-value 'snapshot bytes are not provider output'
metadata=$(cat "$probe"/prefix-*.json)
assert_not_contains "$metadata" private-fixture-value 'metadata omits snapshot contents'
assert_contains "$metadata" '"observationOnly":true' 'audit never establishes production capability'
assert_eq 600 "$(stat -c %a "$probe"/prefix-*.snapshot)" 'captured snapshot stays owner-private'
assert_eq "$(sha256sum "$tmp/snapshot" | cut -d' ' -f1)" \
    "$(jq -r '.snapshotSha256' <<< "$metadata")" 'audit records exact observed snapshot bytes'
assert_eq "$native" "$(cat "$probe"/prefix-*.command)" 'native command is preserved in private evidence'
finish
