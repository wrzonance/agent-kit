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

# --- a branch created in the root checkout is a named incident -------------
created_root="$tmp/created-root"
created_worker="$tmp/created-worker"
make_repo "$created_root"
git -C "$created_root" worktree add -q -b feat/created "$created_worker"
created_snap="$created_root/.agent/cross-write.snapshot"
snapshot_repo "$created_root" "$created_snap"
now=$(date +%s)
git -C "$created_root" branch injected
created_out=$(
    "$cross_write" collect --root "$created_root" --snapshot "$created_snap" \
        --worker-worktree "$created_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
created_rc=$?
assert_eq 10 "$created_rc" 'a branch created in the root checkout is a named incident'
assert_contains "$created_out" 'type=branch-created' \
    'the incident is attributed as a branch creation'
assert_contains "$created_out" 'name=injected' \
    'the incident names the created branch'

# --- a branch deleted from the root checkout is a named incident -----------
deleted_root="$tmp/deleted-root"
deleted_worker="$tmp/deleted-worker"
make_repo "$deleted_root"
git -C "$deleted_root" branch doomed
git -C "$deleted_root" worktree add -q -b feat/deleted "$deleted_worker"
deleted_snap="$deleted_root/.agent/cross-write.snapshot"
snapshot_repo "$deleted_root" "$deleted_snap"
now=$(date +%s)
git -C "$deleted_root" branch -D doomed >/dev/null
deleted_out=$(
    "$cross_write" collect --root "$deleted_root" --snapshot "$deleted_snap" \
        --worker-worktree "$deleted_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
deleted_rc=$?
assert_eq 10 "$deleted_rc" 'a branch deleted from the root checkout is a named incident'
assert_contains "$deleted_out" 'type=branch-deleted' \
    'the incident is attributed as a branch deletion'
assert_contains "$deleted_out" 'name=doomed' \
    'the incident names the deleted branch'

# --- a reflogs-disabled repo never certifies a moved-and-restored ref clean -
noreflog_root="$tmp/noreflog-root"
noreflog_worker="$tmp/noreflog-worker"
mkdir -p "$noreflog_root"
git init -q -b main "$noreflog_root"
git -C "$noreflog_root" config core.logAllRefUpdates false
git -C "$noreflog_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m base
git -C "$noreflog_root" worktree add -q -b feat/noreflog "$noreflog_worker"
noreflog_snap="$noreflog_root/.agent/cross-write.snapshot"
snapshot_repo "$noreflog_root" "$noreflog_snap"
baseline_sha=$(git -C "$noreflog_root" rev-parse HEAD)
git -C "$noreflog_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
now=$(date +%s)
git -C "$noreflog_root" reset --soft "$baseline_sha"
restored_sha=$(git -C "$noreflog_root" rev-parse HEAD)
assert_eq "$baseline_sha" "$restored_sha" \
    'the reflogs-disabled ref genuinely matches its pre-dispatch baseline byte-for-byte'
noreflog_out=$(
    "$cross_write" collect --root "$noreflog_root" --snapshot "$noreflog_snap" \
        --worker-worktree "$noreflog_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
noreflog_rc=$?
assert_eq 10 "$noreflog_rc" \
    'a reflogs-disabled repo never certifies a moved-and-restored ref as clean'
assert_contains "$noreflog_out" 'type=head-reflog-unavailable' \
    'the fail-closed incident names the unavailable reflog rather than reporting clean'
assert_not_contains "$noreflog_out" 'cross-write=none' \
    'an unobservable ref is never reported as cross-write=none'

# --- a worker committing on its own branch is NOT a root cross-write --------
# Reproduces the issue #352 false positive: worker branches live in the same
# repository as the root checkout (worktrees share refs/heads/*), so a
# perfectly normal worker commit on its own branch must never surface as a
# root incident.
worker_root="$tmp/worker-root"
worker_worker="$tmp/worker-worker"
make_repo "$worker_root"
git -C "$worker_root" worktree add -q -b feat/w1 "$worker_worker"
worker_snap="$worker_root/.agent/cross-write.snapshot"
snapshot_repo "$worker_root" "$worker_snap"
now=$(date +%s)
git -C "$worker_worker" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m 'worker commit'
worker_out=$(
    "$cross_write" collect --root "$worker_root" --snapshot "$worker_snap" \
        --worker-worktree "$worker_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
worker_rc=$?
assert_eq 0 "$worker_rc" \
    'a worker commit on its own branch is not a root incident (issue #352)'
assert_contains "$worker_out" 'cross-write=none' \
    'a worker committing on its own branch still reports cross-write=none'
assert_not_contains "$worker_out" 'cross-ref=' \
    'the worker branch move produces no cross-ref incident at all'

# --- the root checkout's OWN branch moving is still a named incident -------
# Proves the fix narrows WHICH refs are in scope, not what counts as a
# mutation: the worker-branch exclusion above must not blind the fence to a
# move of the branch the ROOT checkout itself owns.
rootmove_root="$tmp/rootmove-root"
rootmove_worker="$tmp/rootmove-worker"
make_repo "$rootmove_root"
git -C "$rootmove_root" worktree add -q -b feat/rootmove-worker "$rootmove_worker"
rootmove_snap="$rootmove_root/.agent/cross-write.snapshot"
snapshot_repo "$rootmove_root" "$rootmove_snap"
git -C "$rootmove_root" -c user.name=t -c user.email=t@example.invalid \
    commit -q --allow-empty -m second
now=$(date +%s)
git -C "$rootmove_root" reset --soft HEAD^
rootmove_out=$(
    "$cross_write" collect --root "$rootmove_root" --snapshot "$rootmove_snap" \
        --worker-worktree "$rootmove_worker" --issue 352 \
        --worker-start $((now - 5)) --worker-end $((now + 5)) --write-set 'src/**'
)
rootmove_rc=$?
assert_eq 10 "$rootmove_rc" \
    "the root checkout's own branch moving is still a named incident"
assert_contains "$rootmove_out" 'type=head-sha-changed' \
    'the fix narrows scope to worker-owned refs, not what counts as a mutation'

finish
