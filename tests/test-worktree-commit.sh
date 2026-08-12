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

finish
