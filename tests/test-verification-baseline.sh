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
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name 'Test'

printf 'unrelated content\n' >"$repo/unrelated.txt"
printf 'pinned content\n' >"$repo/pinned.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm base

git -C "$repo" checkout -qb feature

# `pinned.txt` gets rewritten and committed on the feature branch (this is
# the "in-diff" failing path: unchanged in the worktree, but touched between
# base and HEAD).
printf 'pinned content, rewritten by this PR\n' >"$repo/pinned.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm 'feature: rewrite pinned.txt'

# `unrelated.txt` is never touched by the feature branch at all.
# `original-dirty.txt` exists at HEAD but is edited in the worktree without
# being committed (the "modified" failing path).
printf 'dirty content\n' >"$repo/original-dirty.txt"
git -C "$repo" add original-dirty.txt
git -C "$repo" commit -qm 'feature: add original-dirty.txt'
printf 'dirty content, uncommitted\n' >"$repo/original-dirty.txt"

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
assert_contains "$out" 'path=original-dirty.txt unchanged=no' \
    'per-path detail reports the modified path as unchanged=no'

# --- change-caused-red: in-diff (committed by this PR) path ----------------
out=$(run_helper --base main --log "$log" --paths pinned.txt --check demo-indiff)
rc=$?
assert_eq '1' "$rc" 'a path committed by this PR exits 1 (change-caused-red)'
assert_contains "$out" 'path=pinned.txt unchanged=yes outside-diff=no' \
    'per-path detail reports the in-diff path as outside-diff=no'

# --- persisted decision is written and reused (short-circuit) --------------
decision_file="$repo/.agent/evidence/baseline/demo-persist.json"
run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist --issue 7 >/dev/null
assert_rc 0 'first run for demo-persist creates a persisted decision' -- \
    test -f "$decision_file"
# shellcheck disable=SC2016  # single-quoted bash -c script; $1 expands inside it, not here
assert_rc 0 'persisted decision file is mode-owned and non-symlink' -- \
    bash -c '[[ -f "$1" && ! -L "$1" ]]' _ "$decision_file"

# Dirty unrelated.txt on disk WITHOUT recommitting -- a fresh classification
# would now report change-caused-red (unchanged=no). If the persisted
# decision is reused instead of recomputed, the helper still reports
# baseline-red: this proves the short-circuit skips re-running the diffs
# rather than merely agreeing with them by coincidence.
printf 'unrelated content, now dirtied after the decision was persisted\n' >"$repo/unrelated.txt"
out=$(run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist --issue 7)
rc=$?
assert_eq '0' "$rc" 'a persisted decision for matching paths/base short-circuits to baseline-red'
assert_contains "$out" 'reused=' \
    'reused-decision output names the persisted decision file'

# --force bypasses the persisted decision and recomputes fresh.
out=$(run_helper --base main --log "$log" --paths unrelated.txt --check demo-persist --issue 7 --force)
rc=$?
assert_eq '1' "$rc" '--force ignores the persisted decision and recomputes (now change-caused-red)'
git -C "$repo" checkout -q -- unrelated.txt

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
