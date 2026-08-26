#!/usr/bin/env bash
# Suite: verification-baseline.sh classifies a declared-verification failure
# as baseline-red (evidence-backed, publication may proceed) or
# change-caused-red (fix as today), and persists/reuses baseline-red
# decisions per --check.
set -uo pipefail

TEST_NAME='verification-baseline'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/verification-baseline.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p -- "$repo"
# -b main: the fixture pins --base main throughout, regardless of this host's
# git init.defaultBranch (a `master`-default git otherwise dies resolving
# --base main as an unresolvable commit).
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name 'Test'

printf 'unrelated content\n' >"$repo/unrelated.txt"
printf 'stable content\n' >"$repo/stable.txt"
printf 'pinned content\n' >"$repo/pinned.txt"
printf 'removed content\n' >"$repo/removed.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base

git -C "$repo" checkout -qb feature

# `pinned.txt` gets rewritten and committed on the feature branch (this is
# the "in-diff" failing path: unchanged in the worktree, but touched between
# base and HEAD).
printf 'pinned content, rewritten by this PR\n' >"$repo/pinned.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feature: rewrite pinned.txt'

# `removed.txt` is deleted (and the deletion committed) by the feature
# branch -- absent from HEAD entirely, so it can never be "unchanged from
# HEAD"; it must classify change-caused via the tracked-at-HEAD gate, the
# same gate that catches an untracked new file below.
git -C "$repo" rm -q removed.txt
git -C "$repo" commit -qm 'feature: remove removed.txt'

# `unrelated.txt` is never touched by the feature branch at all.
# `original-dirty.txt` exists at HEAD but is edited in the worktree without
# being committed (the "modified" failing path).
printf 'dirty content\n' >"$repo/original-dirty.txt"
git -C "$repo" add original-dirty.txt
git -C "$repo" commit -qm 'feature: add original-dirty.txt'
printf 'dirty content, uncommitted\n' >"$repo/original-dirty.txt"

# `untracked-new.txt` is a brand-new file this change introduces, never
# `git add`ed -- git diff (with no --no-index) has no representation for it
# at all against either range, so both diff checks alone would read it as
# vacuously unchanged/outside-diff. This is the regression case: without the
# tracked-at-HEAD gate, a failing path the change itself created reads as
# baseline-red.
printf 'brand new untracked content\n' >"$repo/untracked-new.txt"

log="$tmp/verify.log"
printf 'declared verification failed\n' >"$log"

run_helper() {
    (cd -- "$repo" && bash "$script" "$@")
}

# --- baseline-red: unrelated, unchanged, outside-diff path -----------------
out=$(run_helper --base main --log "$log" --paths unrelated.txt --check demo-baseline --issue 99)
rc=$?
assert_eq '0' "$rc" 'an unrelated unchanged path exits 0 (baseline-red)'
assert_contains "$out" 'baseline-red check=demo-baseline paths=1 unchanged=yes outside-diff=yes issue=99' \
    'baseline-red marker line names the check, path count, and issue'
assert_contains "$out" '## Baseline verification evidence — demo-baseline' \
    'evidence block heading names the check'
assert_contains "$out" 'git diff --exit-code HEAD -- unrelated.txt' \
    'evidence cites the unchanged-in-worktree proof'
assert_contains "$out" 'git diff --exit-code main...HEAD -- unrelated.txt' \
    'evidence cites the outside-diff proof'
assert_contains "$out" 'The baseline is tracked in #99.' \
    'evidence names the tracking issue'

# --- change-caused-red: modified-in-worktree path ---------------------------
out=$(run_helper --base main --log "$log" --paths original-dirty.txt --check demo-modified)
rc=$?
assert_eq '1' "$rc" 'a path with uncommitted worktree changes exits 1 (change-caused-red)'
assert_contains "$out" 'change-caused-red check=demo-modified paths=1' \
    'change-caused-red marker line names the check'
assert_contains "$out" 'path=original-dirty.txt tracked=yes unchanged=no' \
    'per-path detail reports the modified path as unchanged=no'

# --- change-caused-red: in-diff (committed by this PR) path ----------------
out=$(run_helper --base main --log "$log" --paths pinned.txt --check demo-indiff)
rc=$?
assert_eq '1' "$rc" 'a path committed by this PR exits 1 (change-caused-red)'
assert_contains "$out" 'path=pinned.txt tracked=yes unchanged=yes outside-diff=no' \
    'per-path detail reports the in-diff path as outside-diff=no'

# --- change-caused-red: untracked path introduced by this change (regression) ---
# Without the tracked-at-HEAD gate, `git diff --exit-code HEAD -- P` and
# `git diff --exit-code main...HEAD -- P` both exit 0 for a path git diff has
# no representation for at all -- misclassifying it baseline-red.
out=$(run_helper --base main --log "$log" --paths untracked-new.txt --check demo-untracked)
rc=$?
assert_eq '1' "$rc" 'an untracked new path exits 1 (change-caused-red), not baseline-red'
assert_contains "$out" 'change-caused-red check=demo-untracked paths=1' \
    'change-caused-red marker line names the untracked-path check'
assert_contains "$out" 'path=untracked-new.txt tracked=no unchanged=no outside-diff=no' \
    'per-path detail reports the untracked path as tracked=no'

# --- change-caused-red: path deleted by this branch (regression) -----------
out=$(run_helper --base main --log "$log" --paths removed.txt --check demo-removed)
rc=$?
assert_eq '1' "$rc" 'a path deleted by this branch exits 1 (change-caused-red)'
assert_contains "$out" 'path=removed.txt tracked=no' \
    'per-path detail reports the branch-deleted path as tracked=no'

# --- persisted decision: provenance carries forward; the verdict never does ---
decision_file="$repo/.agent/evidence/baseline/demo-persist.json"
run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist --issue 7 >/dev/null
assert_rc 0 'first run for demo-persist creates a persisted decision' -- \
    test -f "$decision_file"
# shellcheck disable=SC2016  # single-quoted bash -c script; $1 expands inside it, not here
assert_rc 0 'persisted decision file is mode-owned and non-symlink' -- \
    bash -c '[[ -f "$1" && ! -L "$1" ]]' _ "$decision_file"

# Re-running with the same clean path/base and no --issue adopts the
# persisted issue (provenance), but rc=0 here is EARNED by fresh
# re-verification -- unrelated.txt is genuinely still clean, not because the
# stored verdict was trusted.
out=$(run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist)
rc=$?
assert_eq '0' "$rc" 'a persisted decision is confirmed by fresh re-verification (still baseline-red)'
assert_contains "$out" 'issue=7' \
    'the persisted issue is adopted when --issue is omitted'
assert_contains "$out" 'reused=' \
    'output names the matched persisted decision file'

# Root review regression: a persisted decision must never mask a later,
# genuine change to one of its paths -- every path is re-verified on every
# invocation; the stored verdict is evidence of provenance, never proof of a
# fresh tree's state.
printf 'unrelated content, now genuinely changed by a real commit\n' >"$repo/unrelated.txt"
git -C "$repo" add unrelated.txt
git -C "$repo" commit -qm 'feature: accidentally touch unrelated.txt'
out=$(run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist --issue 7)
rc=$?
assert_eq '1' "$rc" 'a committed change to a previously-clean path is change-caused-red, not a stale baseline-red'
assert_contains "$out" 'change-caused-red check=demo-persist paths=1' \
    'change-caused-red marker line names the check after the path was touched'
assert_contains "$out" 'not honored' \
    'output flags the stale persisted decision as not honored'

# --force ignores even the provenance carry-forward (issue defaults to none,
# not the persisted 55) -- on a genuinely clean, unrelated path this still
# freshly verifies to baseline-red.
run_helper --base main --log "$log" --paths stable.txt --check demo-force --issue 55 >/dev/null
out=$(run_helper --base main --log "$log" --paths stable.txt --check demo-force --force)
rc=$?
assert_eq '0' "$rc" '--force still verifies a genuinely clean path as baseline-red'
assert_contains "$out" 'issue=none' \
    '--force does not adopt the persisted issue'
assert_not_contains "$out" 'reused=' \
    '--force does not report a matched persisted decision'

# --- usage errors ------------------------------------------------------------
assert_rc 2 'missing --base is a usage error' -- \
    bash "$script" --log "$log" --paths unrelated.txt
assert_rc 1 'a nonexistent --log is refused' -- \
    bash -c "cd '$repo' && bash '$script' --base main --log '$tmp/missing.log' --paths unrelated.txt"
assert_rc 2 'missing --paths is a usage error' -- \
    bash "$script" --base main --log "$log"
assert_rc 2 'an uppercase --check name is refused' -- \
    bash -c "cd '$repo' && bash '$script' --base main --log '$log' --paths unrelated.txt --check BAD"
assert_rc 1 'a --paths value escaping the repository is refused' -- \
    bash -c "cd '$repo' && bash '$script' --base main --log '$log' --paths ../outside.txt"
assert_rc 1 'an unresolvable --base is refused' -- \
    bash -c "cd '$repo' && bash '$script' --base does-not-exist --log '$log' --paths unrelated.txt"

finish
