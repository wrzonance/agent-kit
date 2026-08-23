#!/usr/bin/env bash
# Boundary coverage for the durable PR -> RUN_DIR mapping (issue #405).
set -uo pipefail

TEST_NAME='run-dir'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/run-dir.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

run() {
    # run REPO_ROOT PR [EXTRA_ARGS...] -- captures stdout/stderr/rc separately.
    local repo_root=$1 pr=$2
    shift 2
    RUN_OUT=''
    RUN_ERR=''
    RUN_RC=0
    RUN_OUT=$(/bin/bash "$script" --pr "$pr" --repo-root "$repo_root" "$@" 2>"$tmp/.stderr") || RUN_RC=$?
    RUN_ERR=$(<"$tmp/.stderr")
}

# --- the happy path: primary .agent/evidence location -----------------------
repo1="$tmp/repo1"
mkdir -p "$repo1"
run "$repo1" 42
assert_eq 0 "$RUN_RC" 'a fresh repo root resolves successfully'
assert_eq "$repo1/.agent/evidence/pr-42" "$RUN_OUT" \
    'the primary target is <repo>/.agent/evidence/pr-<N>'
assert_eq yes "$( [[ -d $RUN_OUT ]] && printf yes || printf no )" 'the run directory is created'
assert_eq 700 "$(stat -c %a -- "$RUN_OUT")" 'the run directory is created at mode 0700'
# run-dir.sh sets umask 077, so a .agent/ it creates from scratch lands at
# 0700 too (still owned solely by this user -- not a regression, just tighter
# than the 0755 an already-onboarded repo's .agent/ normally has). Only
# .agent/evidence/ and below are a hard contract; .agent/ itself is not.
assert_eq 700 "$(stat -c %a -- "$repo1/.agent")" \
    '.agent itself is left private when this script is the one that creates it'

# --- idempotence: same PR resolves to the same directory, contents kept -----
marker="$RUN_OUT/marker"
printf 'keep me\n' >"$marker"
run "$repo1" 42
assert_eq 0 "$RUN_RC" 'a second call for the same PR succeeds'
assert_eq "$repo1/.agent/evidence/pr-42" "$RUN_OUT" \
    'a second call for the same PR returns the identical path (acceptance criterion)'
assert_eq 700 "$(stat -c %a -- "$RUN_OUT")" 'the mode is still 0700 after the second call'
assert_eq 'keep me' "$(<"$marker")" 'a second call never clobbers existing contents'

# A different PR number in the same repo gets its own directory.
run "$repo1" 43
assert_eq "$repo1/.agent/evidence/pr-43" "$RUN_OUT" 'a different PR number resolves to its own directory'
assert_eq no "$( [[ -e "$RUN_OUT/marker" ]] && printf yes || printf no )" \
    'a different PR does not inherit another PR run directory contents'

# --- PR number validation happens before the value becomes a path component -
for bad_pr in 0 007 -5 abc '5/../etc' '5;rm -rf /' '5 6'; do
    run "$repo1" "$bad_pr"
    assert_eq 2 "$RUN_RC" "an invalid --pr value ('$bad_pr') is refused as a usage error"
    assert_eq no "$( [[ -e "$repo1/.agent/evidence/$bad_pr" ]] && printf yes || printf no )" \
        "an invalid --pr value ('$bad_pr') never reaches the filesystem as a path component"
done
# Empty is a distinct case (a value-required usage error, not a regex
# mismatch) and has no path-component claim to check -- `evidence/` alone is
# the directory earlier assertions already populated.
run "$repo1" ''
assert_eq 2 "$RUN_RC" "an empty --pr value is refused as a usage error"
missing_pr_rc=0
missing_pr_err=$(/bin/bash "$script" --repo-root "$repo1" 2>&1) || missing_pr_rc=$?
assert_eq 2 "$missing_pr_rc" 'a missing --pr is a usage error'
assert_contains "$missing_pr_err" 'Usage:' 'the missing --pr rejection includes a copyable usage recipe'

# --- hostile pre-existing evidence directory: refuse, never reuse -----------
symlink_repo="$tmp/symlink-repo"
mkdir -p "$symlink_repo/.agent"
elsewhere="$tmp/elsewhere"
mkdir -p "$elsewhere"
ln -s "$elsewhere" "$symlink_repo/.agent/evidence"
run "$symlink_repo" 1
assert_eq 1 "$RUN_RC" 'a symlinked evidence directory is refused'
assert_contains "$RUN_ERR" 'symlink' 'the symlink refusal names the problem'
assert_eq no "$( [[ -e "$elsewhere/pr-1" ]] && printf yes || printf no )" \
    'a symlinked evidence directory is never followed to write elsewhere'

file_repo="$tmp/file-repo"
mkdir -p "$file_repo/.agent"
: >"$file_repo/.agent/evidence"
run "$file_repo" 1
assert_eq 1 "$RUN_RC" 'an evidence path that is a regular file is refused'
assert_eq no "$( [[ -d "$file_repo/.agent/evidence" ]] && printf yes || printf no )" \
    'the regular-file evidence path is never turned into a directory'

wrongmode_repo="$tmp/wrongmode-repo"
mkdir -p "$wrongmode_repo/.agent/evidence"
chmod 755 -- "$wrongmode_repo/.agent/evidence"
run "$wrongmode_repo" 1
assert_eq 1 "$RUN_RC" 'an existing evidence directory with the wrong mode is refused, never widened or narrowed silently'
assert_contains "$RUN_ERR" 'mode 0700' 'the wrong-mode refusal names the required mode'
assert_eq 755 "$(stat -c %a -- "$wrongmode_repo/.agent/evidence")" \
    'the refused directory is left exactly as it was found'

symlink_agent_repo="$tmp/symlink-agent-repo"
mkdir -p "$symlink_agent_repo"
real_agent="$tmp/real-agent-elsewhere"
mkdir -p "$real_agent"
ln -s "$real_agent" "$symlink_agent_repo/.agent"
run "$symlink_agent_repo" 1
assert_eq 1 "$RUN_RC" 'a symlinked .agent directory is refused outright, never treated as unwritable'
assert_contains "$RUN_ERR" 'symlink' 'the symlinked .agent refusal names the problem'

# --- the leaf directory itself is validated the same way (via private_dir_ensure) --
leaf_symlink_repo="$tmp/leaf-symlink-repo"
mkdir -p "$leaf_symlink_repo/.agent/evidence"
chmod 700 -- "$leaf_symlink_repo/.agent/evidence"
leaf_elsewhere="$tmp/leaf-elsewhere"
mkdir -p "$leaf_elsewhere"
ln -s "$leaf_elsewhere" "$leaf_symlink_repo/.agent/evidence/pr-9"
run "$leaf_symlink_repo" 9
assert_eq 1 "$RUN_RC" 'a symlinked per-PR leaf directory is refused'

# --- fallback: only a genuine .agent/ write failure triggers /tmp -----------
fallback_repo="$tmp/fallback-repo"
mkdir -p "$fallback_repo/.agent"
chmod 555 -- "$fallback_repo/.agent"
fake_tmpdir="$tmp/fake-tmpdir"
mkdir -p "$fake_tmpdir"
RUN_OUT=''; RUN_ERR=''; RUN_RC=0
RUN_OUT=$(TMPDIR="$fake_tmpdir" /bin/bash "$script" --pr 7 --repo-root "$fallback_repo" \
    2>"$tmp/.stderr") || RUN_RC=$?
RUN_ERR=$(<"$tmp/.stderr")
chmod 755 -- "$fallback_repo/.agent"
assert_eq 0 "$RUN_RC" 'an unwritable .agent/ falls back rather than failing outright'
assert_not_contains "$RUN_OUT" "$fallback_repo" \
    'the fallback path never lands inside the unwritable repository tree'
assert_contains "$RUN_OUT" "$fake_tmpdir/" 'the fallback path is rooted under the overridden TMPDIR'
assert_contains "$RUN_ERR" 'not writable' 'the fallback is announced on stderr, never silent'
assert_eq 700 "$(stat -c %a -- "$RUN_OUT")" 'the fallback run directory is also created at mode 0700'

# The fallback path is itself deterministic per (repository, PR) pair, so a
# resumed session recovers evidence there too, not just under .agent/.
mkdir -p "$fallback_repo/.agent"
chmod 555 -- "$fallback_repo/.agent"
RUN_OUT2=''
RUN_OUT2=$(TMPDIR="$fake_tmpdir" /bin/bash "$script" --pr 7 --repo-root "$fallback_repo" 2>/dev/null)
chmod 755 -- "$fallback_repo/.agent"
assert_eq "$RUN_OUT" "$RUN_OUT2" 'the fallback path is stable across repeated calls for the same PR'

# A different repository under the same fallback TMPDIR must not collide on
# the same PR number.
other_fallback_repo="$tmp/other-fallback-repo"
mkdir -p "$other_fallback_repo/.agent"
chmod 555 -- "$other_fallback_repo/.agent"
RUN_OUT3=''
RUN_OUT3=$(TMPDIR="$fake_tmpdir" /bin/bash "$script" --pr 7 --repo-root "$other_fallback_repo" 2>/dev/null)
chmod 755 -- "$other_fallback_repo/.agent"
assert_eq differ "$( [[ $RUN_OUT3 != "$RUN_OUT" ]] && printf differ || printf same )" \
    'two different repositories never collide on the same fallback PR path'

# --- usage/help and unknown arguments ---------------------------------------
help_rc=0
help_out=$(/bin/bash "$script" --help 2>&1) || help_rc=$?
assert_eq 0 "$help_rc" '--help exits 0'
assert_contains "$help_out" 'Usage:' '--help prints a usage recipe'

unknown_rc=0
unknown_err=$(/bin/bash "$script" --pr 1 --repo-root "$repo1" --bogus 2>&1) || unknown_rc=$?
assert_eq 2 "$unknown_rc" 'an unknown flag is a usage error'
assert_contains "$unknown_err" 'unknown argument' 'the unknown-flag rejection names the offending flag'

missing_repo_root_rc=0
missing_repo_root_err=$(/bin/bash "$script" --pr 1 --repo-root "$tmp/does-not-exist" 2>&1) || missing_repo_root_rc=$?
assert_eq 2 "$missing_repo_root_rc" 'a --repo-root that does not exist is a usage error'
assert_contains "$missing_repo_root_err" '--repo-root' \
    'the missing-repo-root rejection names the offending option'

# --- default repo-root resolution uses git rev-parse ------------------------
git_repo="$tmp/git-repo"
git init --quiet "$git_repo"
git -C "$git_repo" config user.email test@example.invalid
git -C "$git_repo" config user.name test
git_out_rc=0
git_out=$(cd -- "$git_repo" && /bin/bash "$script" --pr 5 2>&1) || git_out_rc=$?
assert_eq 0 "$git_out_rc" 'omitting --repo-root inside a Git worktree succeeds'
assert_eq "$git_repo/.agent/evidence/pr-5" "$git_out" \
    'omitting --repo-root derives it from git rev-parse --show-toplevel'

non_git_rc=0
non_git_dir="$tmp/non-git"
mkdir -p "$non_git_dir"
non_git_err=$(cd -- "$non_git_dir" && /bin/bash "$script" --pr 5 2>&1) || non_git_rc=$?
assert_eq 1 "$non_git_rc" 'omitting --repo-root outside any Git worktree fails closed'
assert_contains "$non_git_err" '--repo-root' 'the non-Git-worktree failure names the escape hatch'

finish
