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
assert_rc 0 'append-unique starts a numeric array' -- \
    "$script" append-unique --file "$state" --path opened_prs --json 41
assert_rc 0 'append-unique ignores an equal value' -- \
    "$script" append-unique --file "$state" --path opened_prs --json 41
touch -d '2030-09-16 01:00:00.123456789' "$state"
duplicate_mtime=$(stat -c %y "$state")
assert_rc 0 'append-unique accepts an already-recorded value idempotently' -- \
    "$script" append-unique --file "$state" --path opened_prs --json 41
assert_eq "$duplicate_mtime" "$(stat -c %y "$state")" \
    'append-unique does not rewrite state when the value already exists'
assert_rc 0 'append-unique preserves first-seen order' -- \
    "$script" append-unique --file "$state" --path opened_prs --json 43
assert_eq '[41,43]' "$("$script" get --file "$state" --path opened_prs)" \
    'append-unique stores numeric values once in first-seen order'
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

assert_rc 0 'an older run can record opened PRs' -- \
    "$script" set --run-id older --repo-root "$repo" --path opened_prs --json '[7]'
touch -t 203009160101 "$repo/.agent/evidence/run-older/run-state.json"
assert_rc 0 'a newer run can record opened PRs' -- \
    "$script" set --run-id newer --repo-root "$repo" --path opened_prs --json '[11,13]'
touch -t 203009160102 "$repo/.agent/evidence/run-newer/run-state.json"
latest_json=$("$script" latest --repo-root "$repo" --path opened_prs)
assert_eq 'newer' "$(jq -r '.run_id' <<<"$latest_json")" 'latest identifies the newest run'
assert_eq '[11,13]' "$(jq -c '.value' <<<"$latest_json")" 'latest returns the selected path as JSON'

assert_rc 0 'a same-second older run can record opened PRs' -- \
    "$script" set --run-id z-nano-old --repo-root "$repo" --path opened_prs --json '[17]'
touch -d '2031-09-16 01:00:00.100000000' "$repo/.agent/evidence/run-z-nano-old/run-state.json"
assert_rc 0 'a same-second newer run can record opened PRs' -- \
    "$script" set --run-id a-nano-new --repo-root "$repo" --path opened_prs --json '[19]'
touch -d '2031-09-16 01:00:00.900000000' "$repo/.agent/evidence/run-a-nano-new/run-state.json"
latest_json=$("$script" latest --repo-root "$repo" --path opened_prs)
assert_eq 'a-nano-new' "$(jq -r '.run_id' <<<"$latest_json")" \
    'latest uses sub-second state mtime before its deterministic run-ID tiebreak'

no_runs_repo="$tmp/no-runs"
mkdir -p "$no_runs_repo"
latest_absent_rc=0
latest_absent_out=$("$script" latest --repo-root "$no_runs_repo" --path opened_prs 2>/dev/null) || latest_absent_rc=$?
assert_eq 11 "$latest_absent_rc" 'latest exits 11 when no run evidence exists'
assert_eq '' "$latest_absent_out" 'latest prints nothing when no run evidence exists'
assert_rc 0 'a latest run may omit opened_prs' -- \
    "$script" set --run-id empty --repo-root "$no_runs_repo" --path other --json '[]'
latest_absent_rc=0
latest_absent_out=$("$script" latest --repo-root "$no_runs_repo" --path opened_prs 2>/dev/null) || latest_absent_rc=$?
assert_eq 11 "$latest_absent_rc" 'latest exits 11 when the newest run omits the requested path'
assert_eq '' "$latest_absent_out" 'latest missing-path output stays empty'

unsafe_repo="$tmp/unsafe-latest"
mkdir -p "$unsafe_repo/.agent/evidence"
chmod 700 "$unsafe_repo/.agent/evidence"
ln -s "$repo/.agent/evidence/run-newer" "$unsafe_repo/.agent/evidence/run-linked"
assert_rc 1 'latest refuses a symlinked candidate run directory' -- \
    "$script" latest --repo-root "$unsafe_repo" --path opened_prs

linked_agent_repo="$tmp/linked-agent"
mkdir -p "$linked_agent_repo"
ln -s "$repo/.agent" "$linked_agent_repo/.agent"
assert_rc 1 'latest refuses an evidence root reached through a symlinked .agent directory' -- \
    "$script" latest --repo-root "$linked_agent_repo" --path opened_prs

malformed_repo="$tmp/malformed-latest"
mkdir -p "$malformed_repo"
assert_rc 0 'latest malformed fixture begins as trusted state' -- \
    "$script" set --run-id bad --repo-root "$malformed_repo" --path opened_prs --json '[19]'
printf 'not json\n' >"$malformed_repo/.agent/evidence/run-bad/run-state.json"
chmod 600 "$malformed_repo/.agent/evidence/run-bad/run-state.json"
assert_rc 1 'latest refuses malformed candidate evidence' -- \
    "$script" latest --repo-root "$malformed_repo" --path opened_prs

fallback_repo="$tmp/fallback-repo"
fallback_tmp="$tmp/fallback-tmp"
mkdir -p "$fallback_repo/.agent" "$fallback_tmp"
chmod 555 "$fallback_repo/.agent"
assert_rc 0 'run-scoped state records through the deterministic private fallback' -- \
    env TMPDIR="$fallback_tmp" "$script" append-unique --run-id fallback-wave \
    --repo-root "$fallback_repo" --path opened_prs --json 71
chmod 755 "$fallback_repo/.agent"
fallback_latest=$(TMPDIR="$fallback_tmp" "$script" latest --repo-root "$fallback_repo" --path opened_prs)
assert_eq 'fallback-wave' "$(jq -r '.run_id' <<<"$fallback_latest")" \
    'latest discovers the same fallback backend used by run-scoped mutations'
assert_eq '[71]' "$(jq -c '.value' <<<"$fallback_latest")" \
    'latest returns opened PRs recorded in the fallback backend'

# Independent successful workers must not overwrite each other's bookkeeping.
pids=()
for n in {1..12}; do
    "$script" set --file "$state" --path "workers.$n" --value "worker-$n" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
assert_eq 12 "$(jq '.workers | length' "$state")" 'concurrent updates retain every successful worker ID'
pids=()
for n in {101..112}; do
    "$script" append-unique --file "$state" --path concurrent_prs --json "$n" &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
assert_eq 12 "$(jq '.concurrent_prs | unique | length' "$state")" \
    'concurrent append-unique mutations retain every distinct PR number'
assert_rc 11 'get keeps absent semantics when the parent directory is missing' -- \
    "$script" get --file "$tmp/missing/run-state.json" --path absent
finish
