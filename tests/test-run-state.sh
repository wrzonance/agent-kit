#!/usr/bin/env bash
# Suite: run-state.sh keeps one validated, owner-private JSON object per run
# (issue #613) so the root records redrive/parked bookkeeping with one call
# instead of an inline Python heredoc, and a resumed session reads it back.
set -uo pipefail

TEST_NAME='run-state'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
state="$tmp/run-state.json"

assert_rc 0 'set creates the state file' -- "$script" set --file "$state" --path redrive.52 --value 1
assert_eq '1' "$("$script" get --file "$state" --path redrive.52)" 'get reads back what set wrote'
assert_eq '600' "$(stat -c %a -- "$state")" 'the state file is owner-private'
assert_rc 0 'set without --value stores true' -- "$script" set --file "$state" --path redrive.16
assert_eq 'true' "$("$script" get --file "$state" --path redrive.16)" 'a bare set reads back as true'
assert_rc 0 'set --json stores a structured value' -- \
    "$script" set --file "$state" --path prLoops.251 --json '{"status":"review-running","attempts":2}'
assert_eq 'review-running' "$("$script" get --file "$state" --path prLoops.251.status)" 'get walks into a nested object'
assert_eq '{"status":"review-running","attempts":2}' "$("$script" get --file "$state" --path prLoops.251)" \
    'get prints a non-scalar value as compact JSON'
absent_rc=0
absent_out=$("$script" get --file "$state" --path prLoops.999 2>/dev/null) || absent_rc=$?
assert_eq '11' "$absent_rc" 'get on an absent path exits 11'
assert_eq '' "$absent_out" 'and prints nothing'
assert_rc 0 'append starts an array' -- "$script" append --file "$state" --path parked --value 253
assert_rc 0 'append extends it' -- "$script" append --file "$state" --path parked --value 254
assert_eq '["253","254"]' "$("$script" get --file "$state" --path parked)" 'append keeps insertion order'
append_scalar_rc=0
"$script" append --file "$state" --path redrive.52 --value x >/dev/null 2>&1 || append_scalar_rc=$?
assert_eq '1' "$append_scalar_rc" 'append onto a non-array refuses'
assert_rc 0 'unset removes a path' -- "$script" unset --file "$state" --path redrive.16
unset_rc=0; "$script" get --file "$state" --path redrive.16 >/dev/null 2>&1 || unset_rc=$?
assert_eq '11' "$unset_rc" 'an unset path reads as absent'
assert_eq 'true' "$(jq -e 'type == "object"' "$state")" 'the file stays a JSON object throughout'

assert_rc 0 'set --json null stores an explicit JSON null' -- "$script" set --file "$state" --path nullable --json null
null_get_rc=0
null_get_out=$("$script" get --file "$state" --path nullable 2>/dev/null) || null_get_rc=$?
assert_eq '0' "$null_get_rc" 'get on an existing null-valued key succeeds (present, not absent)'
assert_eq 'null' "$null_get_out" 'get prints null for an existing null-valued key'
null_append_rc=0
"$script" append --file "$state" --path nullable --value x >/dev/null 2>&1 || null_append_rc=$?
assert_eq '1' "$null_append_rc" 'append refuses an existing null-valued key instead of silently overwriting it'
assert_eq 'null' "$("$script" get --file "$state" --path nullable)" 'the refused append left the null value untouched'

printf 'not json\n' > "$tmp/broken.json"
chmod 600 "$tmp/broken.json"
broken_rc=0
broken_err=$("$script" get --file "$tmp/broken.json" --path a 2>&1 >/dev/null) || broken_rc=$?
assert_eq '1' "$broken_rc" 'an unparseable state file blocks instead of reading as empty'
assert_contains "$broken_err" 'unparseable' 'the block names the cause'

printf '%s\n' '{"a":1}' '{"b":2}' > "$tmp/multi.json"
chmod 600 "$tmp/multi.json"
multi_get_rc=0
multi_get_err=$("$script" get --file "$tmp/multi.json" --path a 2>&1 >/dev/null) || multi_get_rc=$?
assert_eq '1' "$multi_get_rc" 'a state file holding two JSON objects is refused on get, not read value-by-value'
assert_contains "$multi_get_err" 'unparseable' 'the multi-object refusal names the cause'
multi_set_rc=0
"$script" set --file "$tmp/multi.json" --path a --value 1 >/dev/null 2>&1 || multi_set_rc=$?
assert_eq '1' "$multi_set_rc" 'a state file holding two JSON objects is refused on set too'
ln -s "$state" "$tmp/link.json"
link_rc=0; "$script" set --file "$tmp/link.json" --path a --value 1 >/dev/null 2>&1 || link_rc=$?
assert_eq '1' "$link_rc" 'a symlinked state file is refused'
bad_path_rc=0; "$script" set --file "$state" --path 'a..b' --value 1 >/dev/null 2>&1 || bad_path_rc=$?
assert_eq '2' "$bad_path_rc" 'an empty path segment is a usage error'
usage_rc=0; "$script" set --file "$state" >/dev/null 2>&1 || usage_rc=$?
assert_eq '2' "$usage_rc" 'set without --path is a usage error'
marker_rc=0; marker_out=$("$script" -- 2>&1) || marker_rc=$?
assert_eq '2' "$marker_rc" 'a bare -- is a usage error'
assert_not_contains "$marker_out" 'unknown argument' 'the -- marker itself is never rejected'

# issue #689 (CR-689-2): an owned but group/other-readable state file must be
# refused, not silently trusted -- state may hold run bookkeeping other users
# on the box should not be able to read.
insecure_state="$tmp/insecure-run-state.json"
printf '{"a":1}\n' >"$insecure_state"
chmod 644 "$insecure_state"
insecure_get_rc=0
insecure_get_err=$("$script" get --file "$insecure_state" --path a 2>&1 >/dev/null) || insecure_get_rc=$?
assert_eq '1' "$insecure_get_rc" 'get on a group/other-readable state file refuses'
assert_contains "$insecure_get_err" 'owner-private' 'the refusal names the cause'
insecure_set_rc=0
insecure_set_err=$("$script" set --file "$insecure_state" --path b --value 1 2>&1 >/dev/null) || insecure_set_rc=$?
assert_eq '1' "$insecure_set_rc" 'set on a group/other-readable state file refuses too'
assert_contains "$insecure_set_err" 'owner-private' 'the set refusal names the cause too'
chmod 600 "$insecure_state"
assert_eq '1' "$("$script" get --file "$insecure_state" --path a)" 'get succeeds once the file is owner-private'
assert_rc 0 'set succeeds once the file is owner-private' -- "$script" set --file "$insecure_state" --path b --value 1

repo="$tmp/repo"
mkdir -p "$repo/.agent"
assert_rc 0 '--run-id resolves the file through run-dir.sh' -- \
    "$script" set --run-id wave4-run --repo-root "$repo" --path redrive.7 --value 1
assert_eq '1' "$(jq -r '.redrive["7"]' "$repo/.agent/evidence/run-wave4-run/run-state.json")" \
    'the run-scoped state lives at <run dir>/run-state.json'

finish
