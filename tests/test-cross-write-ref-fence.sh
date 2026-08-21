#!/usr/bin/env bash
# Suite: cross-write-check.sh detects root-checkout ref mutations (issue #352).
#
# The file-based cross-write fence compares working-tree bytes; a `git reset
# --soft`, `git checkout <branch>`, or `git branch -f` moves refs without
# touching a single file, so it is invisible to that comparison. This suite
# exercises the ref-snapshot/ref-collect half of the same checker: HEAD's
# symbolic ref and SHA, every local branch's SHA, and reflog-window
# attribution for a ref that moved and was restored inside the worker window.
set -uo pipefail

TEST_NAME='cross-write-ref-fence'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

cross_write="$root/agentkit/skills/parallel-issues/scripts/cross-write-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir=$1
    git init -q -b main "$dir"
    git -C "$dir" -c user.name=t -c user.email=t@example.invalid \
        commit -q --allow-empty -m base
}

snapshot_repo() {
    local dir=$1 snap=$2
    mkdir -p "$dir/.agent"
    "$cross_write" snapshot --root "$dir" --output "$snap" --write-set 'src/**' >/dev/null
}

# --- regression: unchanged refs still report cross-write=none --------------
regress_root="$tmp/regress-root"
regress_worker="$tmp/regress-worker"
make_repo "$regress_root"
git -C "$regress_root" worktree add -q -b feat/regress "$regress_worker"
regress_snap="$regress_root/.agent/cross-write.snapshot"
snapshot_repo "$regress_root" "$regress_snap"
now=$(date +%s)
regress_out=$(
    "$cross_write" collect --root "$regress_root" --snapshot "$regress_snap" \
        --worker-worktree "$regress_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
regress_rc=$?
assert_eq 0 "$regress_rc" 'an unchanged root still exits clean'
assert_contains "$regress_out" 'cross-write=none' \
    'no ref or file mutation still reports cross-write=none'

# --- git reset --soft moves HEAD's SHA with zero file changes --------------
reset_root="$tmp/reset-root"
reset_worker="$tmp/reset-worker"
make_repo "$reset_root"
git -C "$reset_root" worktree add -q -b feat/reset "$reset_worker"
reset_snap="$reset_root/.agent/cross-write.snapshot"
snapshot_repo "$reset_root" "$reset_snap"
git -C "$reset_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
now=$(date +%s)
git -C "$reset_root" reset --soft HEAD^
reset_out=$(
    "$cross_write" collect --root "$reset_root" --snapshot "$reset_snap" \
        --worker-worktree "$reset_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
reset_rc=$?
assert_eq 10 "$reset_rc" 'a mid-window reset --soft is a named incident, not a clean exit'
assert_contains "$reset_out" 'cross-ref=' \
    'a reset with no file changes still emits a cross-ref incident'
assert_contains "$reset_out" 'type=head-sha-changed' \
    'reset --soft is attributed as a HEAD sha change'
assert_not_contains "$reset_out" 'cross-write=none' \
    'a ref-only mutation is never reported as cross-write=none'

# --- git checkout of a different branch in the root checkout ---------------
checkout_root="$tmp/checkout-root"
checkout_worker="$tmp/checkout-worker"
make_repo "$checkout_root"
git -C "$checkout_root" branch other
git -C "$checkout_root" worktree add -q -b feat/checkout "$checkout_worker"
checkout_snap="$checkout_root/.agent/cross-write.snapshot"
snapshot_repo "$checkout_root" "$checkout_snap"
now=$(date +%s)
git -C "$checkout_root" checkout -q other
checkout_out=$(
    "$cross_write" collect --root "$checkout_root" --snapshot "$checkout_snap" \
        --worker-worktree "$checkout_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
checkout_rc=$?
assert_eq 10 "$checkout_rc" 'a mid-window branch checkout is a named incident'
assert_contains "$checkout_out" 'type=head-branch-changed' \
    'a checkout of a different branch is attributed as a HEAD branch change'
assert_contains "$checkout_out" 'refs/heads/other' \
    'the incident names the branch HEAD now points at'
git -C "$checkout_root" checkout -q main

# --- git branch -f moves a branch HEAD does not currently point at ---------
force_root="$tmp/force-root"
force_worker="$tmp/force-worker"
make_repo "$force_root"
git -C "$force_root" branch other
git -C "$force_root" worktree add -q -b feat/force "$force_worker"
force_snap="$force_root/.agent/cross-write.snapshot"
snapshot_repo "$force_root" "$force_snap"
git -C "$force_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
now=$(date +%s)
git -C "$force_root" branch -f other main
force_out=$(
    "$cross_write" collect --root "$force_root" --snapshot "$force_snap" \
        --worker-worktree "$force_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
force_rc=$?
assert_eq 10 "$force_rc" 'a forced branch move is a named incident'
assert_contains "$force_out" 'type=branch-moved' \
    'branch -f is attributed as a branch-moved incident'
assert_contains "$force_out" 'name=other' \
    'the incident names the branch that moved'

# --- a ref that moved and was restored within the window is still reported -
restore_root="$tmp/restore-root"
restore_worker="$tmp/restore-worker"
make_repo "$restore_root"
git -C "$restore_root" worktree add -q -b feat/restore "$restore_worker"
restore_snap="$restore_root/.agent/cross-write.snapshot"
snapshot_repo "$restore_root" "$restore_snap"
baseline_sha=$(git -C "$restore_root" rev-parse HEAD)
git -C "$restore_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
now=$(date +%s)
git -C "$restore_root" reset --soft "$baseline_sha"
restored_sha=$(git -C "$restore_root" rev-parse HEAD)
assert_eq "$baseline_sha" "$restored_sha" \
    'the restored ref genuinely matches the pre-dispatch baseline byte-for-byte'
restore_out=$(
    "$cross_write" collect --root "$restore_root" --snapshot "$restore_snap" \
        --worker-worktree "$restore_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
restore_rc=$?
assert_eq 10 "$restore_rc" \
    'a ref that moved and was restored inside the window is still an incident'
assert_contains "$restore_out" 'restored=yes' \
    'the incident records that the ref is back at its baseline value'
assert_contains "$restore_out" 'type=head-sha-changed' \
    'the moved-then-restored HEAD is still attributed as a sha-change event'

# --- a ref change outside the declared worker window is still surfaced -----
outside_root="$tmp/outside-root"
outside_worker="$tmp/outside-worker"
make_repo "$outside_root"
git -C "$outside_root" worktree add -q -b feat/outside "$outside_worker"
outside_snap="$outside_root/.agent/cross-write.snapshot"
snapshot_repo "$outside_root" "$outside_snap"
git -C "$outside_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
git -C "$outside_root" reset --soft HEAD^
outside_out=$(
    "$cross_write" collect --root "$outside_root" --snapshot "$outside_snap" \
        --worker-worktree "$outside_worker" --issue 352 \
        --worker-start 1 --worker-end 1 --write-set 'src/**'
)
outside_rc=$?
assert_eq 10 "$outside_rc" 'a ref change outside the declared window is still an incident'
assert_contains "$outside_out" 'window=outside-window' \
    'a ref change outside the worker window is attributed as such, not dropped'

finish
