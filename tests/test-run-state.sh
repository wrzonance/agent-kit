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
activation_sh="$root/agentkit/skills/.shared/scripts/workflow-activation.sh"
activation_hook="$root/agentkit/hooks/user-prompt-submit.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
state="$tmp/run-state.json"

activate_parallel() {
    local repo=$1 session=$2 record nonce
    jq -nc --arg cwd "$repo" --arg session "$session" \
        '{cwd:$cwd,session_id:$session,hook_event_name:"UserPromptSubmit",prompt:"$agentkit:parallel-issues 907"}' |
        "$activation_hook" >/dev/null
    record="$repo/.agent/activation/$(printf '%s' "$session" | sha256sum | cut -d' ' -f1).json"
    nonce=$(jq -r .nonce "$record")
    "$activation_sh" ack --repo-root "$repo" --session "$session" \
        --skill parallel-issues --nonce "$nonce" >/dev/null
    jq -nc --arg cwd "$repo" --arg session "$session" \
        '{cwd:$cwd,session_id:$session,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"true"}}' |
        "$activation_sh" hook >/dev/null
}

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

# Issue #907: one bind call initializes durable run identity, and the same
# call without --run-id resumes only the run bound to the actual session.
binding_repo="$tmp/binding-repo"
git init -q -b main "$binding_repo"
git -C "$binding_repo" config user.name test
git -C "$binding_repo" config user.email test@example.invalid
printf 'seed\n' >"$binding_repo/seed"
git -C "$binding_repo" add seed
git -C "$binding_repo" commit -qm seed
activate_parallel "$binding_repo" actual-session
assert_rc 0 'legacy run state exists before binding' -- \
    "$script" set --run-id resume-run --repo-root "$binding_repo" --path redrive.17
assert_rc 0 'completed results exist before binding' -- \
    "$script" set --run-id resume-run --repo-root "$binding_repo" --path results --json '{"done":[17]}'
bind_json=$("$script" bind --run-id resume-run --repo-root "$binding_repo" \
    --activation-session actual-session)
assert_eq 'resume-run' "$(jq -r '.run_id' <<<"$bind_json")" \
    'bind returns the workflow run ID distinctly'
assert_eq 'actual-session' "$(jq -r '.activation_session' <<<"$bind_json")" \
    'bind returns the activation session distinctly'
assert_eq "$(realpath -e "$binding_repo")" "$(jq -r '.repository_root' <<<"$bind_json")" \
    'bind records the canonical primary repository identity'
assert_eq "$(realpath -e "$binding_repo")/.agent/session-ledger.ndjson" \
    "$(jq -r '.decision_ledger' <<<"$bind_json")" \
    'bind derives the existing session-ledger recipe path'
assert_eq "$(realpath -e "$binding_repo")/.agent/runs/active-workers.ndjson" \
    "$(jq -r '.worker_ledger' <<<"$bind_json")" \
    'bind derives the existing active-worker ledger path'
assert_eq '[17]' "$(jq -c '.results.done' "$binding_repo/.agent/evidence/run-resume-run/run-state.json")" \
    'binding a legacy record preserves completed results'
assert_eq 'true' "$(jq -c '.redrive["17"]' "$binding_repo/.agent/evidence/run-resume-run/run-state.json")" \
    'binding a legacy record preserves retry state'

decision_ledger=$(jq -r '.decision_ledger' <<<"$bind_json")
mkdir -p "$(dirname -- "$decision_ledger")"
printf '%s\n' '{"decision":"keep"}' >"$decision_ledger"
chmod 600 "$decision_ledger"
decision_before=$(sha256sum "$decision_ledger")
activate_parallel "$binding_repo" other-session
assert_rc 0 'another session can bind a distinct run' -- \
    "$script" bind --run-id other-run --repo-root "$binding_repo" --activation-session other-session
touch -d '2039-09-16 01:00:00' "$binding_repo/.agent/evidence/run-other-run/run-state.json"
touch -d '2029-09-16 01:00:00' "$binding_repo/.agent/evidence/run-resume-run/run-state.json"
resume_json=$("$script" bind --repo-root "$binding_repo" --activation-session actual-session)
assert_eq 'resume-run' "$(jq -r '.run_id' <<<"$resume_json")" \
    'resume selects the exact session binding instead of the newest mtime'
assert_eq "$decision_before" "$(sha256sum "$decision_ledger")" \
    'resume leaves recorded operator decisions byte-for-byte unchanged'
assert_eq 'true' "$(jq -c '.redrive["17"]' "$binding_repo/.agent/evidence/run-resume-run/run-state.json")" \
    'resume leaves bounded retry state unchanged'

activate_parallel "$binding_repo" fresh-session
wrong_session_rc=0
wrong_session_err=$("$script" bind --repo-root "$binding_repo" \
    --activation-session fresh-session 2>&1 >/dev/null) || wrong_session_rc=$?
assert_eq 1 "$wrong_session_rc" 'a different actual session cannot inherit an old binding'
assert_contains "$wrong_session_err" 'no run binding matches repository and activation session' \
    'session mismatch asks for an explicit current-run recovery decision'

assert_rc 0 'ambiguous fixture binds a second run to the same session' -- \
    "$script" bind --run-id duplicate-session-run --repo-root "$binding_repo" \
    --activation-session actual-session
ambiguous_rc=0
ambiguous_err=$("$script" bind --repo-root "$binding_repo" \
    --activation-session actual-session 2>&1 >/dev/null) || ambiguous_rc=$?
assert_eq 1 "$ambiguous_rc" 'resume refuses multiple runs bound to one session'
assert_contains "$ambiguous_err" 'multiple run bindings match repository and activation session' \
    'ambiguous resume names the required explicit selection'

wrong_explicit_rc=0
wrong_explicit_err=$("$script" bind --run-id resume-run --repo-root "$binding_repo" \
    --activation-session fresh-session 2>&1 >/dev/null) || wrong_explicit_rc=$?
assert_eq 1 "$wrong_explicit_rc" 'an acknowledged different session cannot overwrite an existing binding'
assert_contains "$wrong_explicit_err" 'belongs to a different activation session' \
    'wrong-session explicit selection explains the identity mismatch'
assert_contains "$wrong_explicit_err" '--rebind' \
    'wrong-session explicit selection names the explicit recovery flag'
assert_contains "$wrong_explicit_err" 'bind --run-id resume-run' \
    'wrong-session explicit selection prints the exact selected run in its recovery command'
assert_contains "$wrong_explicit_err" '--activation-session fresh-session' \
    'wrong-session explicit selection prints the independently authorized session in its recovery command'
assert_eq 'actual-session' "$(jq -r '.binding.activation_session' \
    "$binding_repo/.agent/evidence/run-resume-run/run-state.json")" \
    'wrong-session explicit selection leaves the saved activation identity unchanged'
assert_eq "$decision_before" "$(sha256sum "$decision_ledger")" \
    'wrong-session explicit selection leaves recorded operator decisions unchanged'
assert_eq 'true' "$(jq -c '.redrive["17"]' "$binding_repo/.agent/evidence/run-resume-run/run-state.json")" \
    'wrong-session explicit selection leaves bounded retry state unchanged'

resume_state="$binding_repo/.agent/evidence/run-resume-run/run-state.json"
old_activation="$binding_repo/.agent/activation/$(printf '%s' actual-session | sha256sum | cut -d' ' -f1).json"
fresh_activation="$binding_repo/.agent/activation/$(printf '%s' fresh-session | sha256sum | cut -d' ' -f1).json"
state_payload_before=$(jq -cS 'del(.binding)' "$resume_state")
old_activation_before=$(sha256sum "$old_activation")
rebind_json=$("$script" bind --run-id resume-run --repo-root "$binding_repo" \
    --activation-session fresh-session --rebind)
assert_eq 'fresh-session' "$(jq -r '.activation_session' <<<"$rebind_json")" \
    'an exact run selection can explicitly adopt an independently authorized new session'
assert_eq "$state_payload_before" "$(jq -cS 'del(.binding)' "$resume_state")" \
    'explicit rebind preserves every non-binding run-state byte value'
assert_eq "$decision_before" "$(sha256sum "$decision_ledger")" \
    'explicit rebind leaves recorded operator decisions byte-for-byte unchanged'
assert_eq "$old_activation_before" "$(sha256sum "$old_activation")" \
    'explicit rebind never rewrites the old activation receipt'
assert_eq 'fresh-session' "$(jq -r '.session' "$fresh_activation")" \
    'explicit rebind relies on the new session own activation receipt'

rebound_state_before=$(sha256sum "$resume_state")
unacknowledged_rebind_rc=0
unacknowledged_rebind_err=$("$script" bind --run-id resume-run --repo-root "$binding_repo" \
    --activation-session never-authorized-rebind --rebind 2>&1 >/dev/null) || unacknowledged_rebind_rc=$?
assert_eq 1 "$unacknowledged_rebind_rc" 'explicit rebind refuses an unacknowledged new session'
assert_contains "$unacknowledged_rebind_err" 'no receipt at activation origin for session' \
    'unacknowledged rebind names the missing independent receipt'
assert_eq "$rebound_state_before" "$(sha256sum "$resume_state")" \
    'unacknowledged rebind leaves the complete saved run state byte-for-byte unchanged'
assert_eq "$decision_before" "$(sha256sum "$decision_ledger")" \
    'unacknowledged rebind leaves recorded operator decisions byte-for-byte unchanged'

rebind_without_run_rc=0
"$script" bind --repo-root "$binding_repo" --activation-session fresh-session --rebind \
    >/dev/null 2>&1 || rebind_without_run_rc=$?
assert_eq 2 "$rebind_without_run_rc" '--rebind requires an exact --run-id selection'

assert_rc 0 'unacknowledged legacy fixture has ordinary state' -- \
    "$script" set --run-id unacknowledged-run --repo-root "$binding_repo" --path redrive.23
unacknowledged_rc=0
unacknowledged_err=$("$script" bind --run-id unacknowledged-run --repo-root "$binding_repo" \
    --activation-session never-acknowledged 2>&1 >/dev/null) || unacknowledged_rc=$?
assert_eq 1 "$unacknowledged_rc" 'legacy binding requires authoritative current-session activation evidence'
assert_contains "$unacknowledged_err" 'no receipt at activation origin for session' \
    'unacknowledged legacy refusal names the missing current-session receipt'
assert_eq false "$(jq 'has("binding")' \
    "$binding_repo/.agent/evidence/run-unacknowledged-run/run-state.json")" \
    'unacknowledged legacy refusal does not invent a binding'

damaged_repo="$tmp/damaged-binding-repo"
git init -q -b main "$damaged_repo"
activate_parallel "$damaged_repo" damaged-session
assert_rc 0 'damaged binding fixture begins as a valid binding' -- \
    "$script" bind --run-id damaged-run --repo-root "$damaged_repo" \
    --activation-session damaged-session
damaged_state="$damaged_repo/.agent/evidence/run-damaged-run/run-state.json"
jq 'del(.binding.worker_ledger)' "$damaged_state" >"$damaged_state.next"
mv "$damaged_state.next" "$damaged_state"
chmod 600 "$damaged_state"
damaged_rc=0
damaged_err=$("$script" bind --repo-root "$damaged_repo" \
    --activation-session damaged-session 2>&1 >/dev/null) || damaged_rc=$?
assert_eq 1 "$damaged_rc" 'resume refuses damaged required binding data'
assert_contains "$damaged_err" 'damaged run binding for run damaged-run' \
    'damaged binding refusal names the affected run'

assert_rc 0 'an older run can record opened PRs' -- \
    "$script" set --run-id older --repo-root "$repo" --path opened_prs --json '[7]'
touch -t 203009160101 "$repo/.agent/evidence/run-older/run-state.json"
assert_rc 0 'a newer run can record opened PRs' -- \
    "$script" set --run-id newer --repo-root "$repo" --path opened_prs --json '[11,13]'
touch -t 203009160102 "$repo/.agent/evidence/run-newer/run-state.json"
latest_json=$("$script" latest --repo-root "$repo" --path opened_prs)
assert_eq 'newer' "$(jq -r '.run_id' <<<"$latest_json")" 'latest identifies the newest run'
assert_eq '[11,13]' "$(jq -c '.value' <<<"$latest_json")" 'latest returns the selected path as JSON'

poison_tmp="$tmp/poisoned-latest-fallback"
mkdir -p "$poison_tmp"
ln -s "$tmp/untrusted-latest-target" "$poison_tmp/agent-kit-review-remote-pr.$(id -u)"
latest_json=$(TMPDIR="$poison_tmp" "$script" latest --repo-root "$repo" --path opened_prs)
assert_eq 'newer' "$(jq -r '.run_id' <<<"$latest_json")" \
    'latest ignores an untrusted optional fallback when primary evidence is valid'

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
assert_rc 0 'an existing fallback run stays on that backend after primary access recovers' -- \
    env TMPDIR="$fallback_tmp" "$script" append-unique --run-id fallback-wave \
    --repo-root "$fallback_repo" --path opened_prs --json 73
fallback_latest=$(TMPDIR="$fallback_tmp" "$script" latest --repo-root "$fallback_repo" --path opened_prs)
assert_eq 'fallback-wave' "$(jq -r '.run_id' <<<"$fallback_latest")" \
    'latest discovers the same fallback backend used by run-scoped mutations'
assert_eq '[71,73]' "$(jq -c '.value' <<<"$fallback_latest")" \
    'latest preserves opened PRs across fallback selection and recovered primary access'

fallback_slug=$(printf '%s' "$fallback_repo" | sha256sum | cut -c1-16)
fallback_root="$fallback_tmp/agent-kit-review-remote-pr.$(id -u)/$fallback_slug"
assert_rc 0 'a distinct primary run can coexist with trusted fallback evidence' -- \
    "$script" set --run-id primary-wave --repo-root "$fallback_repo" --path opened_prs --json '[79]'
touch -d '2032-09-16 01:00:00.100000000' \
    "$fallback_repo/.agent/evidence/run-primary-wave/run-state.json"
touch -d '2032-09-16 01:00:00.900000000' \
    "$fallback_root/run-fallback-wave/run-state.json"
fallback_latest=$(TMPDIR="$fallback_tmp" "$script" latest --repo-root "$fallback_repo" --path opened_prs)
assert_eq 'fallback-wave' "$(jq -r '.run_id' <<<"$fallback_latest")" \
    'latest compares distinct trusted run IDs across primary and fallback roots'

assert_rc 0 'duplicate-run fixture begins with trusted primary state' -- \
    "$script" set --run-id duplicate-wave --repo-root "$fallback_repo" --path opened_prs --json '[83]'
mkdir -m 700 "$fallback_root/run-duplicate-wave"
duplicate_latest_rc=0
duplicate_latest_err=$(TMPDIR="$fallback_tmp" "$script" latest --repo-root "$fallback_repo" \
    --path opened_prs 2>&1 >/dev/null) || duplicate_latest_rc=$?
assert_eq 1 "$duplicate_latest_rc" \
    'latest refuses a duplicate run ID across trusted primary and fallback roots'
assert_contains "$duplicate_latest_err" 'duplicate run ID' \
    'duplicate refusal names the cross-backend run identity collision'

printf '%s\n' '{"opened_prs":[89]}' >"$fallback_root/run-duplicate-wave/run-state.json"
chmod 600 "$fallback_root/run-duplicate-wave/run-state.json"
touch -d '2033-09-16 01:00:00.100000000' \
    "$fallback_repo/.agent/evidence/run-duplicate-wave/run-state.json"
touch -d '2033-09-16 01:00:00.900000000' \
    "$fallback_root/run-duplicate-wave/run-state.json"
duplicate_latest_rc=0
TMPDIR="$fallback_tmp" "$script" latest --repo-root "$fallback_repo" --path opened_prs \
    >"$tmp/duplicate-latest.out" 2>"$tmp/duplicate-latest.err" || duplicate_latest_rc=$?
assert_eq 1 "$duplicate_latest_rc" \
    'latest refuses conflicting populated copies of one run ID instead of choosing by mtime'
assert_eq '' "$(<"$tmp/duplicate-latest.out")" \
    'duplicate populated backends emit no arbitrary latest JSON result'
assert_contains "$(<"$tmp/duplicate-latest.err")" 'duplicate run ID' \
    'populated duplicate refusal retains the collision diagnosis'

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
