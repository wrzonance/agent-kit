#!/usr/bin/env bash
# Suite: worktree-commit.sh serializes its stage/check/commit transaction.
set -uo pipefail

TEST_NAME='worktree-commit'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/worktree-commit.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo=$(mktemp -d "$tmp/repo.XXXXXX")
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/.agent"
printf 'AGENT_BASE_BRANCH=main\n' > "$repo/.agent/config.env"
printf 'base\n' > "$repo/base.txt"
git -C "$repo" add -- .agent/config.env base.txt
git -C "$repo" commit -qm init

worktree_a="$tmp/worktree-a"
worktree_b="$tmp/worktree-b"
git -C "$repo" worktree add -q -b issue-9-a "$worktree_a"
git -C "$repo" worktree add -q -b issue-9-b "$worktree_b"
printf 'a\n' > "$worktree_a/a.txt"
printf 'b\n' > "$worktree_b/b.txt"

# Hold the first real git commit after worktree-commit.sh has acquired its
# transaction lock. Without that lock, the second invocation reaches git
# commit while the first is still paused and can commit the wrong staged scope.
real_git=$(command -v git)
fake_bin="$tmp/bin"
gate="$tmp/gate"
mkdir -p "$fake_bin" "$gate"
git_wrapper="$fake_bin/git"
# shellcheck disable=SC2016  # The dollar expressions belong to the generated wrapper.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'if [[ ${CALLER_ID-} == b && ! -e "$GATE_DIR/b-seen" ]]; then' \
    '    : > "$GATE_DIR/b-seen"' \
    '    while [[ ! -e "$GATE_DIR/b-proceed" ]]; do sleep 0.01; done' \
    'fi' \
    'if [[ ${1-} == commit ]]; then' \
    '    if mkdir "$GATE_DIR/first" 2>/dev/null; then' \
    '        : > "$GATE_DIR/first-entered"' \
    '        while [[ ! -e "$GATE_DIR/release" ]]; do sleep 0.01; done' \
    '    else' \
    '        : > "$GATE_DIR/second-entered"' \
    '    fi' \
    'fi' \
    'exec "$REAL_GIT" "$@"' > "$git_wrapper"
chmod +x "$git_wrapper"

wait_for_file() {
    local file=$1
    for _ in {1..200}; do
        [[ -e $file ]] && return 0
        sleep 0.01
    done
    return 1
}

run_a() {
    (cd "$worktree_a" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" CALLER_ID=a GATE_DIR="$gate" \
        "$script" --message 'feat: commit a' -- a.txt)
}

run_b() {
    (cd "$worktree_b" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" CALLER_ID=b GATE_DIR="$gate" \
        "$script" --message 'feat: commit b' -- b.txt)
}

run_a > "$tmp/a.out" 2> "$tmp/a.err" &
pid_a=$!
if wait_for_file "$gate/first-entered"; then
    _pass 'the first invocation reaches commit while holding its transaction'
else
    _fail 'the first invocation reaches commit while holding its transaction' \
        'the controlled commit did not start'
fi

run_b > "$tmp/b.out" 2> "$tmp/b.err" &
pid_b=$!
if ! wait_for_file "$gate/b-seen"; then
    _fail 'the second worktree starts while the first transaction is held' \
        'the competing invocation did not reach the controlled git wrapper'
fi
: > "$gate/b-proceed"
if wait_for_file "$gate/second-entered"; then
    _fail 'the second worktree cannot enter commit during the first transaction' \
        'the competing invocation entered git commit before release'
else
    _pass 'the second worktree cannot enter commit during the first transaction'
fi

: > "$gate/release"
rc_a=0
rc_b=0
wait "$pid_a" || rc_a=$?
wait "$pid_b" || rc_b=$?
assert_eq '0' "$rc_a" 'the first transaction succeeds'
assert_eq '0' "$rc_b" 'the second transaction succeeds after the first releases'

assert_contains "$(cat "$tmp/a.out")" 'feat: commit a' \
    'the first output keeps its own message'
assert_contains "$(cat "$tmp/b.out")" 'feat: commit b' \
    'the second output keeps its own message'
reported_sha=$(sed -n 's/^committed \([^ ]*\) .*/\1/p' "$tmp/a.out")
assert_eq '40' "${#reported_sha}" \
    'the commit report pins a full 40-character SHA'
assert_eq "$(git -C "$worktree_a" rev-parse HEAD)" "$reported_sha" \
    'the commit report pins the actual HEAD SHA'
assert_eq 'feat: commit a' "$(git -C "$worktree_a" log -1 --format=%s)" \
    'the first branch receives its own commit'
assert_eq 'feat: commit b' "$(git -C "$worktree_b" log -1 --format=%s)" \
    'the second branch receives its own commit'
assert_eq 'a.txt' "$(git -C "$worktree_a" diff-tree --no-commit-id --name-only -r HEAD)" \
    'the first commit contains only its requested file'
assert_eq 'b.txt' "$(git -C "$worktree_b" diff-tree --no-commit-id --name-only -r HEAD)" \
    'the second commit contains only its requested file'

common_dir=$(git -C "$worktree_a" rev-parse --git-common-dir)
assert_eq 'yes' "$([[ -e "$common_dir/worktree-commit.lock" ]] && echo yes || echo no)" \
    'the transaction lock lives in the shared Git common directory'

# A lock command failure must be visible and must happen before staging. This
# keeps a broken host dependency from silently producing an unprotected commit.
fail_bin="$tmp/fail-bin"
mkdir -p "$fail_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$fail_bin/flock"
chmod +x "$fail_bin/flock"
printf 'failure\n' > "$worktree_a/failure.txt"
rc=0
out=$(cd "$worktree_a" && PATH="$fail_bin:/usr/bin:/bin" \
    "$script" --message 'feat: must not commit' -- failure.txt 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failed lock acquisition exits with an error'
assert_contains "$out" 'cannot acquire transaction lock' \
    'a failed lock acquisition names the transaction lock'
assert_eq '' "$(git -C "$worktree_a" diff --cached --name-only)" \
    'a failed lock acquisition stages nothing'

trunk_repo="$tmp/trunk-repo"
git init -q -b main "$trunk_repo"
git -C "$trunk_repo" config user.name test
git -C "$trunk_repo" config user.email test@example.invalid
mkdir -- "$trunk_repo/.agent"
printf 'AGENT_BASE_BRANCH=main\n' >"$trunk_repo/.agent/config.env"
printf 'base\n' >"$trunk_repo/base.txt"
git -C "$trunk_repo" add -- .
git -C "$trunk_repo" commit -qm init
printf 'must not stage\n' >"$trunk_repo/blocked.txt"
trunk_err="$tmp/trunk.err"
trunk_rc=0
(cd "$trunk_repo" && "$script" --message 'feat: forbidden' -- blocked.txt \
    > /dev/null 2>"$trunk_err") || trunk_rc=$?
assert_eq '1' "$trunk_rc" 'declared trunk refusal exits before staging'
assert_contains "$(cat "$trunk_err")" 'refusing to commit' \
    'trunk refusal explains the protected branch'
assert_eq '' "$(git -C "$trunk_repo" diff --cached --name-only)" \
    'trunk refusal leaves the index untouched'

# Ordinary protected edits retain the helper's historical behavior. The
# inherited-path handoff applies only while a merge is active.
ordinary_repo="$tmp/ordinary-protected-repo"
git init -q -b main "$ordinary_repo"
git -C "$ordinary_repo" config user.name test
git -C "$ordinary_repo" config user.email test@example.invalid
mkdir -p "$ordinary_repo/.agent" "$ordinary_repo/.github/workflows"
printf 'AGENT_BASE_BRANCH=main\nAGENT_PROTECTED_PATHS=.github/workflows/\n' \
    > "$ordinary_repo/.agent/config.env"
printf 'workflow-v1\n' > "$ordinary_repo/.github/workflows/ci.yml"
git -C "$ordinary_repo" add -- .
git -C "$ordinary_repo" commit -qm init
git -C "$ordinary_repo" checkout -qb feature
printf 'workflow-v2\n' > "$ordinary_repo/.github/workflows/ci.yml"
ordinary_rc=0
(cd "$ordinary_repo" && "$script" --message 'fix: ordinary protected edit' -- \
    .github/workflows/ci.yml > /dev/null 2>&1) || ordinary_rc=$?
assert_eq '0' "$ordinary_rc" 'ordinary protected edits commit outside an active merge'
assert_eq 'workflow-v2' "$(git -C "$ordinary_repo" show HEAD:.github/workflows/ci.yml)" \
    'ordinary protected edit reaches the commit'

# An unwritable metadata preflight points workers back to the designed root
# publication handback, rather than asking the worker to escalate itself.
assert_contains "$(cat "$script")" 'hand the identical command back to the top-level session for publication' \
    'metadata refusal names the top-level publication handback'

printf 'trailing space  \n' >"$worktree_a/whitespace.txt"
check_err="$tmp/check.err"
check_rc=0
(cd "$worktree_a" && "$script" --message 'feat: bad whitespace' -- whitespace.txt \
    > /dev/null 2>"$check_err") || check_rc=$?
assert_eq '1' "$check_rc" 'cached whitespace check rejects the commit'
assert_contains "$(cat "$check_err")" 'diff --cached --check' \
    'whitespace rejection names the failing gate'
assert_eq 'whitespace.txt' "$(git -C "$worktree_a" diff --cached --name-only)" \
    'whitespace rejection occurs after staging and before commit'
assert_eq 'feat: commit a' "$(git -C "$worktree_a" log -1 --format=%s)" \
    'whitespace rejection does not create a commit'

# A merge may carry protected content that belongs to the named base, not the
# worker. Attended mode parks that content without dropping it from the index;
# only explicit --yolo authorization may commit it after byte verification.
merge_repo="$tmp/merge-repo"
git init -q -b main "$merge_repo"
git -C "$merge_repo" config user.name test
git -C "$merge_repo" config user.email test@example.invalid
mkdir -p "$merge_repo/.agent" "$merge_repo/.github/workflows"
printf 'AGENT_BASE_BRANCH=main\nAGENT_PROTECTED_PATHS=.github/workflows/\n' > "$merge_repo/.agent/config.env"
printf 'workflow-base\n' > "$merge_repo/.github/workflows/ci.yml"
printf 'base\n' > "$merge_repo/base.txt"
git -C "$merge_repo" add -- .
git -C "$merge_repo" commit -qm base
git -C "$merge_repo" checkout -qb feature
printf 'feature\n' > "$merge_repo/feature.txt"
git -C "$merge_repo" add -- feature.txt
git -C "$merge_repo" commit -qm feature
git -C "$merge_repo" checkout -q main
printf 'workflow-base-v2\n' > "$merge_repo/.github/workflows/ci.yml"
git -C "$merge_repo" add -- .github/workflows/ci.yml
git -C "$merge_repo" commit -qm 'base workflow update'
merged_base=$(git -C "$merge_repo" rev-parse HEAD)
git -C "$merge_repo" checkout -q feature
git -C "$merge_repo" merge --no-commit --no-ff -q main
printf 'change\n' > "$merge_repo/change.txt"
park_rc=0
park_out=$(cd "$merge_repo" && "$script" --message 'fix: park merge content' \
    --allow-base-inherited "$merged_base" -- change.txt 2>&1) || park_rc=$?
assert_eq '3' "$park_rc" 'attended inherited protected content parks before commit'
assert_contains "$park_out" '.github/workflows/ci.yml' 'park output names the inherited protected path'
assert_eq '.github/workflows/ci.yml' "$(git -C "$merge_repo" diff --cached --name-only | grep '^\.github/workflows/' || true)" \
    'parking preserves inherited protected content in the index'

git -C "$merge_repo" diff --cached --quiet -- change.txt || true
before_yolo=$(git -C "$merge_repo" diff --cached --name-only)
assert_contains "$before_yolo" '.github/workflows/ci.yml' \
    'the parked protected path remains staged before authorization'
yolo_rc=0
yolo_out=$(cd "$merge_repo" && "$script" --yolo --message 'fix: carry base merge' \
    --allow-base-inherited "$merged_base" -- change.txt 2>&1) || yolo_rc=$?
assert_eq '0' "$yolo_rc" 'yolo named-base authorization permits verified inherited content'
assert_contains "$yolo_out" 'committed' 'the authorized helper reports its commit'
assert_eq 'fix: carry base merge' "$(git -C "$merge_repo" log -1 --format=%s)" \
    'the authorized commit is created'
assert_eq 'workflow-base-v2' "$(git -C "$merge_repo" show HEAD:.github/workflows/ci.yml)" \
    'the authorized commit carries the inherited protected bytes'
assert_eq 'change' "$(git -C "$merge_repo" show HEAD:change.txt)" \
    'the authorized commit carries the explicit path'

# A named base may prove a protected deletion too: the base and the merge
# index both lack the blob, so identity comparison must not require cat-file -e.
delete_repo="$tmp/delete-repo"
git init -q -b main "$delete_repo"
git -C "$delete_repo" config user.name test
git -C "$delete_repo" config user.email test@example.invalid
mkdir -p "$delete_repo/.agent" "$delete_repo/.github/workflows"
printf 'AGENT_BASE_BRANCH=main\nAGENT_PROTECTED_PATHS=.github/workflows/\n' \
    > "$delete_repo/.agent/config.env"
printf 'workflow-v1\n' > "$delete_repo/.github/workflows/ci.yml"
printf 'base\n' > "$delete_repo/base.txt"
git -C "$delete_repo" add -- .
git -C "$delete_repo" commit -qm base
git -C "$delete_repo" checkout -qb feature
printf 'feature\n' > "$delete_repo/feature.txt"
git -C "$delete_repo" add -- feature.txt
git -C "$delete_repo" commit -qm feature
git -C "$delete_repo" checkout -q main
git -C "$delete_repo" rm -q .github/workflows/ci.yml
git -C "$delete_repo" commit -qm 'base removes workflow'
delete_base=$(git -C "$delete_repo" rev-parse HEAD)
git -C "$delete_repo" checkout -q feature
git -C "$delete_repo" merge --no-commit --no-ff -q main
printf 'change\n' > "$delete_repo/change.txt"
delete_rc=0
delete_out=$(cd "$delete_repo" && "$script" --yolo --message 'fix: carry base deletion' \
    --allow-base-inherited "$delete_base" -- change.txt 2>&1) || delete_rc=$?
assert_eq '0' "$delete_rc" 'named-base authorization permits an inherited protected deletion'
assert_contains "$delete_out" 'committed' 'the deletion authorization reports its commit'
assert_eq 'absent' "$(git -C "$delete_repo" cat-file -e HEAD:.github/workflows/ci.yml 2>/dev/null && printf present || printf absent)" \
    'the authorized commit carries the protected deletion'

# Config is rooted at the repository toplevel and uses repo-config's quoted
# value convention even when the helper is invoked from a subdirectory.
quoted_repo="$tmp/quoted-protected-repo"
git init -q -b main "$quoted_repo"
git -C "$quoted_repo" config user.name test
git -C "$quoted_repo" config user.email test@example.invalid
mkdir -p "$quoted_repo/.agent" "$quoted_repo/migrations" "$quoted_repo/subdir"
printf 'AGENT_BASE_BRANCH=main\nAGENT_PROTECTED_PATHS="migrations/"\n' \
    > "$quoted_repo/.agent/config.env"
printf 'migration-v1\n' > "$quoted_repo/migrations/001_init.sql"
printf 'base\n' > "$quoted_repo/base.txt"
git -C "$quoted_repo" add -- .
git -C "$quoted_repo" commit -qm base
git -C "$quoted_repo" checkout -qb feature
printf 'feature\n' > "$quoted_repo/feature.txt"
git -C "$quoted_repo" add -- feature.txt
git -C "$quoted_repo" commit -qm feature
git -C "$quoted_repo" checkout -q main
printf 'migration-v2\n' > "$quoted_repo/migrations/001_init.sql"
git -C "$quoted_repo" add -- migrations/001_init.sql
git -C "$quoted_repo" commit -qm 'base migration update'
quoted_base=$(git -C "$quoted_repo" rev-parse HEAD)
git -C "$quoted_repo" checkout -q feature
git -C "$quoted_repo" merge --no-commit --no-ff -q main
printf 'change\n' > "$quoted_repo/change.txt"
quoted_rc=0
quoted_out=$(cd "$quoted_repo/subdir" && "$script" --message 'fix: park quoted protected path' \
    --allow-base-inherited "$quoted_base" -- ../change.txt 2>&1) || quoted_rc=$?
assert_eq '3' "$quoted_rc" 'quoted protected paths park from a subdirectory'
assert_contains "$quoted_out" 'migrations/001_init.sql' \
    'subdirectory config resolution names the quoted protected path'

finish
