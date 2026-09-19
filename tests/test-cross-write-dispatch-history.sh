#!/usr/bin/env bash
# Suite: dispatch audits reject unverifiable or late cross-write baselines.
set -uo pipefail

TEST_NAME='cross-write-dispatch-history'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

cross_write="$root/agentkit/skills/parallel-issues/scripts/cross-write-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_pair() {
    local checkout=$1 worker=$2
    mkdir -p "$checkout/.agent" "$checkout/src"
    git init -q -b main "$checkout"
    printf 'base\n' >"$checkout/src/data.txt"
    git -C "$checkout" add src/data.txt
    git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -qm base
    git -C "$checkout" worktree add -q -b feat/worker "$worker"
}

dispatch_snapshot() {
    local checkout=$1 snapshot=$2 run_id=$3
    "$cross_write" dispatch-fence --root "$checkout" --output "$snapshot" \
        --run-id "$run_id" --write-set 'src/**'
}

dispatch_collect() {
    local checkout=$1 snapshot=$2 worker=$3 run_id=$4 baseline_id=$5 start=$6 end=$7
    "$cross_write" dispatch-fence --root "$checkout" --snapshot "$snapshot" \
        --worker-worktree "$worker" --issue 830 --run-id "$run_id" --baseline-id "$baseline_id" \
        --worker-start "$start" --worker-end "$end" --write-set 'src/**'
}

set_snapshot_capture() {
    local snapshot=$1 captured=$2 temp baseline_id
    temp="$snapshot.rewrite"
    sed -e "s/^captured-at=.*/captured-at=$captured/" -e '/^baseline-id=/d' \
        "$snapshot" >"$temp"
    baseline_id=$(sha256sum -- "$temp" | awk '{print $1}')
    printf 'baseline-id=%s\n' "$baseline_id" >>"$temp"
    mv -- "$temp" "$snapshot"
    printf '%s\n' "$baseline_id"
}

# A valid pre-dispatch baseline binds the run and its content identity, remains
# byte-identical across repeated Collect, and retains the normal clean result.
valid_root="$tmp/valid-root"
valid_worker="$tmp/valid-worker"
make_pair "$valid_root" "$valid_worker"
valid_snapshot="$valid_root/.agent/dispatch.snapshot"
snapshot_out=$(dispatch_snapshot "$valid_root" "$valid_snapshot" run-valid)
valid_baseline_id=${snapshot_out##*baseline-id=}
start=$(date -u +%FT%T.%NZ)
before_hash=$(sha256sum "$valid_snapshot")
valid_out=$(dispatch_collect "$valid_root" "$valid_snapshot" "$valid_worker" \
    run-valid "$valid_baseline_id" "$start" "$start")
valid_rc=$?
dispatch_collect "$valid_root" "$valid_snapshot" "$valid_worker" \
    run-valid "$valid_baseline_id" "$start" "$start" >/dev/null
after_hash=$(sha256sum "$valid_snapshot")
assert_eq 0 "$valid_rc" 'a valid pre-dispatch baseline produces clean dispatch evidence'
assert_contains "$snapshot_out" 'baseline-id=' 'snapshot reports the original baseline identity'
assert_contains "$valid_out" 'cross-write=none' 'valid dispatch evidence preserves the clean marker'
assert_contains "$valid_out" 'run-id=run-valid' 'clean evidence is bound to its run identity'
assert_contains "$valid_out" 'baseline-id=' 'clean evidence is bound to its baseline identity'
assert_eq "$before_hash" "$after_hash" 'repeated Collect leaves the original baseline unchanged'

# An active run cannot replace its baseline in place.
replace_out=''
replace_rc=0
replace_out=$(dispatch_snapshot "$valid_root" "$valid_snapshot" run-valid 2>&1) || replace_rc=$?
assert_eq 11 "$replace_rc" 'snapshot refuses replacement of an active dispatch baseline'
assert_contains "$replace_out" 'invariant=baseline-exists' 'replacement names the failed invariant'
assert_contains "$replace_out" 'next-action=use-new-snapshot-path' \
    'replacement names the supported new-run action'
assert_eq "$before_hash" "$(sha256sum "$valid_snapshot")" \
    'replacement refusal preserves the original baseline bytes'

# A root change hidden by a late snapshot cannot become clean evidence or be
# automatically restored, even when disposal was requested.
late_root="$tmp/late-root"
late_worker="$tmp/late-worker"
make_pair "$late_root" "$late_worker"
printf 'planted before late snapshot\n' >"$late_root/src/data.txt"
printf 'planted before late snapshot\n' >"$late_worker/src/data.txt"
late_snapshot="$late_root/.agent/dispatch.snapshot"
late_snapshot_out=$(dispatch_snapshot "$late_root" "$late_snapshot" run-late)
late_baseline_id=${late_snapshot_out##*baseline-id=}
late_out=''
late_rc=0
late_out=$("$cross_write" dispatch-fence --root "$late_root" --snapshot "$late_snapshot" \
    --worker-worktree "$late_worker" --issue 830 --run-id run-late \
    --baseline-id "$late_baseline_id" \
    --worker-start 1 --worker-end 2147483647 --write-set 'src/**' \
    --dispose-duplicates 2>&1) || late_rc=$?
assert_eq 11 "$late_rc" 'a baseline captured after worker start makes the audit unavailable'
assert_contains "$late_out" 'invariant=capture-before-dispatch' \
    'late baseline diagnostics name the chronology invariant'
assert_not_contains "$late_out" 'cross-write=none' 'a late baseline never reports clean dispatch evidence'
assert_not_contains "$late_out" 'disposition=' 'invalid history never reaches disposal'
assert_eq 'planted before late snapshot' "$(<"$late_root/src/data.txt")" \
    'invalid history leaves planted root bytes untouched'

# Fractional precision is part of the dispatch chronology boundary. A baseline
# captured later in the same wall-clock second must not pass merely because the
# timestamps share the same integer epoch second; an actually earlier precise
# baseline remains valid.
same_second_root="$tmp/same-second-root"
same_second_worker="$tmp/same-second-worker"
make_pair "$same_second_root" "$same_second_worker"
same_second_snapshot="$same_second_root/.agent/dispatch.snapshot"
dispatch_snapshot "$same_second_root" "$same_second_snapshot" run-same-second >/dev/null
same_second_baseline_id=$(set_snapshot_capture "$same_second_snapshot" \
    '2026-09-18T12:00:00.100000000Z')
same_second_out=''
same_second_rc=0
same_second_out=$(dispatch_collect "$same_second_root" "$same_second_snapshot" \
    "$same_second_worker" run-same-second "$same_second_baseline_id" \
    '2026-09-18T12:00:00.050000000Z' '2026-09-18T12:00:01.000000000Z' 2>&1) || \
    same_second_rc=$?
assert_eq 11 "$same_second_rc" \
    'a baseline captured after dispatch within the same second makes the audit unavailable'
assert_contains "$same_second_out" 'invariant=capture-before-dispatch' \
    'same-second late capture names the chronology invariant'
assert_not_contains "$same_second_out" 'cross-write=none' \
    'same-second late capture never reports clean dispatch evidence'

precise_root="$tmp/precise-root"
precise_worker="$tmp/precise-worker"
make_pair "$precise_root" "$precise_worker"
precise_snapshot="$precise_root/.agent/dispatch.snapshot"
dispatch_snapshot "$precise_root" "$precise_snapshot" run-precise >/dev/null
precise_baseline_id=$(set_snapshot_capture "$precise_snapshot" \
    '2026-09-18T12:00:00.050000000Z')
precise_out=$(dispatch_collect "$precise_root" "$precise_snapshot" "$precise_worker" \
    run-precise "$precise_baseline_id" '2026-09-18T12:00:00.100000000Z' \
    '2026-09-18T12:00:01.000000000Z')
precise_rc=$?
assert_eq 0 "$precise_rc" 'a precisely ordered pre-dispatch baseline remains valid'
assert_contains "$precise_out" 'cross-write=none' \
    'precisely ordered dispatch evidence preserves the clean marker'

coarse_root="$tmp/coarse-root"
coarse_worker="$tmp/coarse-worker"
make_pair "$coarse_root" "$coarse_worker"
coarse_snapshot="$coarse_root/.agent/dispatch.snapshot"
dispatch_snapshot "$coarse_root" "$coarse_snapshot" run-coarse >/dev/null
coarse_baseline_id=$(set_snapshot_capture "$coarse_snapshot" 1789732800)
coarse_out=''
coarse_rc=0
coarse_out=$(dispatch_collect "$coarse_root" "$coarse_snapshot" "$coarse_worker" \
    run-coarse "$coarse_baseline_id" 1789732800 1789732801 2>&1) || coarse_rc=$?
assert_eq 11 "$coarse_rc" \
    'equal-second coarse dispatch chronology is rejected as ambiguous'
assert_contains "$coarse_out" 'invariant=capture-before-dispatch' \
    'ambiguous coarse chronology names the capture-before-dispatch invariant'

# Missing start, inverted intervals, invalid time text, mismatched runs, and
# modified or missing baseline history each fail once before comparison.
check_unavailable() {
    local want=$1
    shift
    local out='' rc=0
    out=$("$cross_write" dispatch-fence "$@" 2>&1) || rc=$?
    assert_eq 11 "$rc" "$want returns audit unavailable"
    assert_contains "$out" "invariant=$want" "$want is named in the diagnostic"
    assert_eq 1 "$(grep -c '^audit-unavailable=' <<<"$out")" "$want is reported once"
    assert_not_contains "$out" 'cross-write=none' "$want cannot report clean evidence"
}

common=(--root "$valid_root" --snapshot "$valid_snapshot" --worker-worktree "$valid_worker" \
    --issue 830 --run-id run-valid --baseline-id "$valid_baseline_id" --write-set 'src/**')
check_unavailable worker-start-required "${common[@]}" --worker-end "$start"
check_unavailable ordered-worker-interval "${common[@]}" \
    --worker-start 2147483647 --worker-end 2147483646
check_unavailable worker-start-valid "${common[@]}" --worker-start invalid --worker-end "$start"
check_unavailable run-identity --root "$valid_root" --snapshot "$valid_snapshot" \
    --worker-worktree "$valid_worker" --issue 830 --run-id another-run \
    --baseline-id "$valid_baseline_id" \
    --worker-start "$start" --worker-end "$start" --write-set 'src/**'
check_unavailable baseline-identity --root "$valid_root" --snapshot "$valid_snapshot" \
    --worker-worktree "$valid_worker" --issue 830 --run-id run-valid \
    --worker-start "$start" --worker-end "$start" --write-set 'src/**'

tampered="$valid_root/.agent/tampered.snapshot"
cp "$valid_snapshot" "$tampered"
printf 'tamper\n' >>"$tampered"
check_unavailable baseline-identity --root "$valid_root" --snapshot "$tampered" \
    --worker-worktree "$valid_worker" --issue 830 --run-id run-valid \
    --baseline-id "$valid_baseline_id" \
    --worker-start "$start" --worker-end "$start" --write-set 'src/**'
check_unavailable baseline-readable --root "$valid_root" \
    --snapshot "$valid_root/.agent/missing.snapshot" --worker-worktree "$valid_worker" \
    --issue 830 --run-id run-valid --baseline-id "$valid_baseline_id" \
    --worker-start "$start" --worker-end "$start" \
    --write-set 'src/**'

# The legacy subcommands remain a standalone comparison and cannot be mistaken
# for dispatch evidence when they find no current difference.
current_snapshot="$valid_root/.agent/current.snapshot"
"$cross_write" snapshot --root "$valid_root" --output "$current_snapshot" \
    --write-set 'src/**' >/dev/null
current_out=$("$cross_write" collect --root "$valid_root" --snapshot "$current_snapshot" \
    --worker-worktree "$valid_worker" --issue 830 --write-set 'src/**')
assert_contains "$current_out" 'current-state=none' \
    'standalone comparison uses a marker distinct from dispatch evidence'
assert_not_contains "$current_out" 'cross-write=none' \
    'standalone comparison cannot be mistaken for a clean dispatch audit'

finish
