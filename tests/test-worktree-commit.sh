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

# Every fixture below that isn't specifically exercising trailer behaviour
# (issue #305) supplies this well-formed trailer explicitly, so its outcome
# does not depend on an environment contract existing in the fixture repo.
TEST_TRAILER='Co-Authored-By: Test Author <test@example.invalid>'

# Writes a minimal, untracked environment contract declaring HARNESS's
# identity, in the shape contract-read.sh's harness.trailer projection reads:
# `harness= name=<name> trailer="<value>"`. Used only by the tests that
# exercise default-trailer derivation.
write_contract() {
    local repo=$1 name=$2 value=$3
    mkdir -p "$repo/.agent"
    printf 'harness= name=%s trailer="%s"\n' "$name" "$value" > "$repo/.agent/env-contract.txt"
}

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
        "$script" --message 'feat: commit a' --trailer "$TEST_TRAILER" -- a.txt)
}

run_b() {
    (cd "$worktree_b" && PATH="$fake_bin:$PATH" REAL_GIT="$real_git" CALLER_ID=b GATE_DIR="$gate" \
        "$script" --message 'feat: commit b' --trailer "$TEST_TRAILER" -- b.txt)
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
    "$script" --message 'feat: must not commit' --trailer "$TEST_TRAILER" -- failure.txt 2>&1) || rc=$?
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
(cd "$trunk_repo" && "$script" --message 'feat: forbidden' --trailer "$TEST_TRAILER" -- blocked.txt \
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
(cd "$ordinary_repo" && "$script" --message 'fix: ordinary protected edit' --trailer "$TEST_TRAILER" -- \
    .github/workflows/ci.yml > /dev/null 2>&1) || ordinary_rc=$?
assert_eq '0' "$ordinary_rc" 'ordinary protected edits commit outside an active merge'
assert_eq 'workflow-v2' "$(git -C "$ordinary_repo" show HEAD:.github/workflows/ci.yml)" \
    'ordinary protected edit reaches the commit'

# A worker may not smuggle a tracked config.env change through include-staged;
# only an explicit config.env operand (the issue write set) can authorize it.
config_guard_repo="$tmp/config-guard-repo"
mkdir -p "$config_guard_repo/.agent"
git -C "$config_guard_repo" init -q -b main
git -C "$config_guard_repo" config user.email test@example.com
git -C "$config_guard_repo" config user.name test
printf 'AGENT_BASE_BRANCH=main\n' > "$config_guard_repo/.agent/config.env"
printf 'base\n' > "$config_guard_repo/base.txt"
git -C "$config_guard_repo" add -- .agent/config.env base.txt
git -C "$config_guard_repo" commit -qm init
git -C "$config_guard_repo" checkout -qb feat/config-guard
printf 'AGENT_BASE_BRANCH=main\nAGENT_ADVERSARIAL_REVIEWER=codex\n' > "$config_guard_repo/.agent/config.env"
printf 'allowed\n' > "$config_guard_repo/allowed.txt"
git -C "$config_guard_repo" add -- .agent/config.env
config_guard_out=''; config_guard_rc=0
config_guard_out=$(cd "$config_guard_repo" && "$script" --include-staged \
    --message 'fix: do not smuggle config' --trailer "$TEST_TRAILER" -- allowed.txt 2>&1) || config_guard_rc=$?
assert_eq '1' "$config_guard_rc" \
    'include-staged refuses an unrequested .agent/config.env change'
assert_contains "$config_guard_out" '.agent/config.env' \
    'config.env refusal names the unrequested protected path'
assert_eq '1' "$(git -C "$config_guard_repo" rev-list --count HEAD)" \
    'config.env refusal creates no commit'

# Canonical root-relative and top pathspec operands authorize config.env when
# explicitly named, including from a subdirectory of the checkout.
mkdir -p "$config_guard_repo/subdir"
canonical_out=''; canonical_rc=0
canonical_out=$(cd "$config_guard_repo/subdir" && "$script" --include-staged \
    --message 'fix: authorize config handoff' --trailer "$TEST_TRAILER" -- \
    ../.agent/config.env 2>&1) || canonical_rc=$?
assert_eq '0' "$canonical_rc" \
    'a root-relative config.env operand is accepted from a subdirectory'
assert_contains "$canonical_out" 'committed' \
    'root-relative config.env authorization reports a commit'

printf 'AGENT_BASE_BRANCH=main\nAGENT_ADVERSARIAL_REVIEWER=claude\n' \
    > "$config_guard_repo/.agent/config.env"
top_out=''; top_rc=0
top_out=$(cd "$config_guard_repo/subdir" && "$script" --include-staged \
    --message 'fix: authorize top config handoff' --trailer "$TEST_TRAILER" -- \
    ':(top).agent/config.env' 2>&1) || top_rc=$?
assert_eq '0' "$top_rc" 'a top pathspec config.env operand is accepted'
assert_contains "$top_out" 'committed' \
    'top pathspec config.env authorization reports a commit'

# An unwritable metadata preflight points workers back to the designed root
# publication handback, rather than asking the worker to escalate itself.
assert_contains "$(cat "$script")" 'hand the identical command back to the top-level session for publication' \
    'metadata refusal names the top-level publication handback'

printf 'trailing space  \n' >"$worktree_a/whitespace.txt"
check_err="$tmp/check.err"
check_rc=0
(cd "$worktree_a" && "$script" --message 'feat: bad whitespace' --trailer "$TEST_TRAILER" -- whitespace.txt \
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
park_out=$(cd "$merge_repo" && "$script" --include-staged --message 'fix: park merge content' --trailer "$TEST_TRAILER" \
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
yolo_out=$(cd "$merge_repo" && "$script" --include-staged --yolo --message 'fix: carry base merge' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$merged_base" -- change.txt 2>&1) || yolo_rc=$?
assert_eq '0' "$yolo_rc" 'yolo named-base authorization permits verified inherited content'
assert_contains "$yolo_out" 'committed' 'the authorized helper reports its commit'
assert_eq 'fix: carry base merge' "$(git -C "$merge_repo" log -1 --format=%s)" \
    'the authorized commit is created'
assert_eq 'workflow-base-v2' "$(git -C "$merge_repo" show HEAD:.github/workflows/ci.yml)" \
    'the authorized commit carries the inherited protected bytes'
assert_eq 'change' "$(git -C "$merge_repo" show HEAD:change.txt)" \
    'the authorized commit carries the explicit path'

# .agent/config.env is also legitimate merge-inherited content when the named
# merge parent and --yolo authorization prove its bytes are unchanged.
merge_config_repo="$tmp/merge-config-repo"
git init -q -b main "$merge_config_repo"
git -C "$merge_config_repo" config user.name test
git -C "$merge_config_repo" config user.email test@example.invalid
mkdir -p "$merge_config_repo/.agent"
printf 'AGENT_BASE_BRANCH=main\n' > "$merge_config_repo/.agent/config.env"
printf 'base\n' > "$merge_config_repo/base.txt"
git -C "$merge_config_repo" add -- .
git -C "$merge_config_repo" commit -qm base
git -C "$merge_config_repo" checkout -qb feature
git -C "$merge_config_repo" checkout -q main
printf 'AGENT_BASE_BRANCH=main\nAGENT_ADVERSARIAL_REVIEWER=claude\n' \
    > "$merge_config_repo/.agent/config.env"
git -C "$merge_config_repo" add -- .agent/config.env
git -C "$merge_config_repo" commit -qm 'base config update'
merge_config_base=$(git -C "$merge_config_repo" rev-parse HEAD)
git -C "$merge_config_repo" checkout -q feature
git -C "$merge_config_repo" merge --no-commit --no-ff -q main
printf 'change\n' > "$merge_config_repo/change.txt"
merge_config_out=''; merge_config_rc=0
merge_config_out=$(cd "$merge_config_repo" && "$script" --include-staged --yolo \
    --message 'fix: carry inherited config' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$merge_config_base" -- change.txt 2>&1) || merge_config_rc=$?
assert_eq '0' "$merge_config_rc" \
    'named-base authorization permits inherited config.env content'
assert_contains "$merge_config_out" 'committed' \
    'inherited config authorization reports a commit'
assert_eq $'AGENT_BASE_BRANCH=main\nAGENT_ADVERSARIAL_REVIEWER=claude' \
    "$(git -C "$merge_config_repo" show HEAD:.agent/config.env)" \
    'inherited config authorization carries the merge-parent bytes'

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
delete_out=$(cd "$delete_repo" && "$script" --include-staged --yolo --message 'fix: carry base deletion' --trailer "$TEST_TRAILER" \
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
quoted_out=$(cd "$quoted_repo/subdir" && "$script" --include-staged --message 'fix: park quoted protected path' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$quoted_base" -- ../change.txt 2>&1) || quoted_rc=$?
assert_eq '3' "$quoted_rc" 'quoted protected paths park from a subdirectory'
assert_contains "$quoted_out" 'migrations/001_init.sql' \
    'subdirectory config resolution names the quoted protected path'

# Issue #289: a chained worker's worktree is created off a non-trunk commit
# (create-issue-worktree.sh's --chain-base), but that fact never reaches this
# helper's decision. Its own ordinary, non-merge commits are indistinguishable
# from a trunk-based worktree's -- no active merge means the protected-path
# guard never engages, so the chain-base SHA is never needed to commit here,
# named in a prompt or otherwise.
chained_repo="$tmp/chained-repo"
git init -q -b main "$chained_repo"
git -C "$chained_repo" config user.name test
git -C "$chained_repo" config user.email test@example.invalid
mkdir -p "$chained_repo/.agent" "$chained_repo/.github/workflows"
printf 'AGENT_BASE_BRANCH=main\nAGENT_PROTECTED_PATHS=.github/workflows/\n' \
    > "$chained_repo/.agent/config.env"
printf 'workflow-v1\n' > "$chained_repo/.github/workflows/ci.yml"
git -C "$chained_repo" add -- .
git -C "$chained_repo" commit -qm main-init
# A predecessor issue's branch, pushed and diverged from main -- this commit
# is the chain_base_sha a successor's worktree would start from.
git -C "$chained_repo" checkout -qb feat/issue-predecessor
printf 'workflow-v2-from-predecessor\n' > "$chained_repo/.github/workflows/ci.yml"
git -C "$chained_repo" add -- .github/workflows/ci.yml
git -C "$chained_repo" commit -qm 'predecessor: bump workflow'
chain_base_sha=$(git -C "$chained_repo" rev-parse HEAD)
# The successor's worktree, as create-issue-worktree.sh builds it: a fresh
# branch starting at chain_base_sha, never at origin/main.
git -C "$chained_repo" checkout -qb feat/issue-successor "$chain_base_sha"
printf 'successor change\n' > "$chained_repo/successor.txt"
chained_rc=0
chained_out=$(cd "$chained_repo" && "$script" --message 'feat: successor change' --trailer "$TEST_TRAILER" \
    -- successor.txt 2>&1) || chained_rc=$?
assert_eq '0' "$chained_rc" \
    'a chained successor commits with no active merge and no named base'
assert_contains "$chained_out" 'committed' \
    'the chained successor commit succeeds unconditionally'

# When a chained worker DOES need --allow-base-inherited -- the merge-down
# cascade in references/chains.md, after a predecessor advances -- the exact
# BASE it must name is not something a prompt has to carry either: git itself
# requires the named commit to be the active MERGE_HEAD (verify_base_inherited
# in worktree-commit.sh), and MERGE_HEAD is local worktree state the worker
# can always read back with `git rev-parse MERGE_HEAD` the moment it needs the
# value -- immediately after the same `git merge --no-commit --no-ff` that put
# it there. Nothing here is captured ahead of time from an external source.
git -C "$chained_repo" checkout -q feat/issue-predecessor
printf 'workflow-v3-from-predecessor\n' > "$chained_repo/.github/workflows/ci.yml"
git -C "$chained_repo" add -- .github/workflows/ci.yml
git -C "$chained_repo" commit -qm 'predecessor: advance again'
git -C "$chained_repo" checkout -q feat/issue-successor
git -C "$chained_repo" merge --no-commit --no-ff -q feat/issue-predecessor
derived_base=$(git -C "$chained_repo" rev-parse MERGE_HEAD)
assert_eq "$(git -C "$chained_repo" rev-parse feat/issue-predecessor)" "$derived_base" \
    'MERGE_HEAD alone names the exact predecessor commit, with no prior knowledge'
printf 'more successor change\n' > "$chained_repo/successor2.txt"
derive_rc=0
derive_out=$(cd "$chained_repo" && "$script" --include-staged --yolo --message 'fix: merge-down predecessor' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$derived_base" -- successor2.txt 2>&1) || derive_rc=$?
assert_eq '0' "$derive_rc" \
    'a base derived from MERGE_HEAD alone authorizes the inherited protected content'
assert_contains "$derive_out" 'committed' 'the derived-base authorization reports its commit'

# Merge-downs may also carry non-protected predecessor files. They are safe
# only when the staged bytes remain identical to MERGE_HEAD's commit.
merge_plain_repo="$tmp/merge-plain-repo"
git init -q -b main "$merge_plain_repo"
git -C "$merge_plain_repo" config user.name test
git -C "$merge_plain_repo" config user.email test@example.invalid
mkdir -p "$merge_plain_repo/.agent"
printf 'AGENT_BASE_BRANCH=main\n' > "$merge_plain_repo/.agent/config.env"
printf 'feature-base\n' > "$merge_plain_repo/base.txt"
git -C "$merge_plain_repo" add -- base.txt
git -C "$merge_plain_repo" commit -qm base
git -C "$merge_plain_repo" checkout -qb feature/plain
git -C "$merge_plain_repo" checkout -q main
printf 'inherited\n' > "$merge_plain_repo/inherited.txt"
git -C "$merge_plain_repo" add -- inherited.txt
git -C "$merge_plain_repo" commit -qm 'base adds plain file'
merge_plain_base=$(git -C "$merge_plain_repo" rev-parse HEAD)
git -C "$merge_plain_repo" checkout -q feature/plain
git -C "$merge_plain_repo" merge --no-commit --no-ff -q main
printf 'successor\n' > "$merge_plain_repo/successor.txt"
plain_rc=0
plain_out=$(cd "$merge_plain_repo" && "$script" --include-staged --yolo \
    --message 'fix: carry plain merge content' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$merge_plain_base" -- successor.txt 2>&1) || plain_rc=$?
assert_eq '0' "$plain_rc" \
    'merge-down permits byte-identical inherited non-protected content'
assert_contains "$plain_out" 'committed' \
    'plain merge-down authorization reports a commit'
assert_eq 'inherited' "$(git -C "$merge_plain_repo" show HEAD:inherited.txt)" \
    'plain merge-down carries the inherited non-protected bytes'

merge_plain_mismatch="$tmp/merge-plain-mismatch"
git init -q -b main "$merge_plain_mismatch"
git -C "$merge_plain_mismatch" config user.name test
git -C "$merge_plain_mismatch" config user.email test@example.invalid
mkdir -p "$merge_plain_mismatch/.agent"
printf 'AGENT_BASE_BRANCH=main\n' > "$merge_plain_mismatch/.agent/config.env"
printf 'base\n' > "$merge_plain_mismatch/base.txt"
git -C "$merge_plain_mismatch" add -- base.txt
git -C "$merge_plain_mismatch" commit -qm base
git -C "$merge_plain_mismatch" checkout -qb feature/plain
git -C "$merge_plain_mismatch" checkout -q main
printf 'from-main\n' > "$merge_plain_mismatch/inherited.txt"
git -C "$merge_plain_mismatch" add -- inherited.txt
git -C "$merge_plain_mismatch" commit -qm 'base adds plain file'
merge_plain_mismatch_base=$(git -C "$merge_plain_mismatch" rev-parse HEAD)
git -C "$merge_plain_mismatch" checkout -q feature/plain
git -C "$merge_plain_mismatch" merge --no-commit --no-ff -q main
printf 'tampered\n' > "$merge_plain_mismatch/inherited.txt"
git -C "$merge_plain_mismatch" add -- inherited.txt
printf 'successor\n' > "$merge_plain_mismatch/successor.txt"
mismatch_rc=0
mismatch_out=$(cd "$merge_plain_mismatch" && "$script" --include-staged --yolo \
    --message 'fix: reject tampered merge content' --trailer "$TEST_TRAILER" \
    --allow-base-inherited "$merge_plain_mismatch_base" -- successor.txt 2>&1) || mismatch_rc=$?
assert_eq '1' "$mismatch_rc" \
    'merge-down refuses non-protected content whose bytes differ from MERGE_HEAD'
assert_contains "$mismatch_out" 'inherited.txt' \
    'tampered merge-down refusal names the mismatched path'

# --- Issue #305: the helper owns the trailer instead of trusting its caller ---
#
# A five-issue parallel run gave three workers byte-identical trailer
# instructions and got three differently broken attributions: no trailer line
# at all, a bare identity with no key, and a key with an empty value. All
# three parsed as zero (or nobody-naming) trailers. The fix makes this helper
# derive a correct default from the contract, refuse a malformed --trailer
# outright, and verify its own commit's parsed trailers before reporting
# success.

new_repo() {
    local repo=$1
    git init -q -b main "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    mkdir -p "$repo/.agent"
    printf 'AGENT_BASE_BRANCH=main\n' > "$repo/.agent/config.env"
    printf 'base\n' > "$repo/base.txt"
    git -C "$repo" add -- .agent/config.env base.txt
    git -C "$repo" commit -qm init
    git -C "$repo" checkout -qb feature
}

# Omitting --trailer entirely derives "Co-Authored-By: <contract identity>"
# from this repository's own environment contract and commits with it.
derive_repo="$tmp/trailer-derive-repo"
new_repo "$derive_repo"
write_contract "$derive_repo" claude 'Claude <noreply@anthropic.com>'
printf 'change\n' > "$derive_repo/change.txt"
derive_default_rc=0
derive_default_out=$(cd "$derive_repo" && "$script" --message 'feat: derive default trailer' \
    -- change.txt 2>&1) || derive_default_rc=$?
assert_eq '0' "$derive_default_rc" 'omitting --trailer still produces a commit'
assert_contains "$derive_default_out" 'committed' 'the derived-default commit reports success'
assert_eq 'Co-Authored-By: Claude <noreply@anthropic.com>' \
    "$(git -C "$derive_repo" log -1 --format='%(trailers:only=true,unfold=true)')" \
    'the default trailer is derived from the contract, prefixed with Co-Authored-By'

# A repository whose contract declares a different harness gets THAT harness's
# identity, not a hardcoded "Claude" -- the bridge reads the contract, it does
# not assume who is calling it.
codex_repo="$tmp/trailer-codex-repo"
new_repo "$codex_repo"
write_contract "$codex_repo" codex 'Codex <noreply@openai.com>'
printf 'change\n' > "$codex_repo/change.txt"
codex_rc=0
codex_out=$(cd "$codex_repo" && "$script" --message 'feat: codex harness trailer' \
    -- change.txt 2>&1) || codex_rc=$?
assert_eq '0' "$codex_rc" 'a codex-harness repository also derives a default trailer'
assert_contains "$codex_out" 'committed' 'the codex-harness derived-default commit reports success'
assert_eq 'Co-Authored-By: Codex <noreply@openai.com>' \
    "$(git -C "$codex_repo" log -1 --format='%(trailers:only=true,unfold=true)')" \
    "the derived trailer matches the codex repository's own contract, not claude's"

# A --trailer value with no ':' at all -- e.g. a bare contract identity string
# passed through verbatim -- has no key and is refused before anything stages.
nokey_repo="$tmp/trailer-nokey-repo"
new_repo "$nokey_repo"
printf 'change\n' > "$nokey_repo/change.txt"
nokey_rc=0
nokey_out=$(cd "$nokey_repo" && "$script" --message 'feat: no key' \
    --trailer 'Claude claude-sonnet-5 <noreply@anthropic.com>' -- change.txt 2>&1) || nokey_rc=$?
assert_eq '1' "$nokey_rc" 'a keyless --trailer value is refused'
assert_contains "$nokey_out" "no ':' found" 'the refusal names the missing key'
assert_eq '1' "$(git -C "$nokey_repo" log --oneline | wc -l)" \
    'a keyless --trailer refusal creates no new commit'
assert_eq '' "$(git -C "$nokey_repo" diff --cached --name-only)" \
    'a keyless --trailer refusal stages nothing'

# A --trailer key with an empty value -- the exact shape a variable that
# expanded empty across a tool-call boundary produced in the field -- is
# refused rather than folded into an empty paragraph git silently drops.
emptyval_repo="$tmp/trailer-emptyval-repo"
new_repo "$emptyval_repo"
printf 'change\n' > "$emptyval_repo/change.txt"
emptyval_rc=0
emptyval_out=$(cd "$emptyval_repo" && "$script" --message 'feat: empty value' \
    --trailer 'Co-Authored-By: ' -- change.txt 2>&1) || emptyval_rc=$?
assert_eq '1' "$emptyval_rc" 'a --trailer with an empty value is refused'
assert_contains "$emptyval_out" 'empty value' 'the refusal names the empty value'
assert_eq '1' "$(git -C "$emptyval_repo" log --oneline | wc -l)" \
    'an empty-value --trailer refusal creates no new commit'

# git's own trailer grammar accepts keys starting with a digit or a hyphen --
# this helper's key validation must match that grammar, not a stricter guess
# at it (CodeRabbit finding on PR #313).
digitkey_repo="$tmp/trailer-digitkey-repo"
new_repo "$digitkey_repo"
printf 'change\n' > "$digitkey_repo/change.txt"
digitkey_rc=0
digitkey_out=$(cd "$digitkey_repo" && "$script" --message 'feat: digit-led trailer key' \
    --trailer '1Key: 42' -- change.txt 2>&1) || digitkey_rc=$?
assert_eq '0' "$digitkey_rc" 'a --trailer key starting with a digit is accepted, matching git'
assert_contains "$digitkey_out" 'committed' 'the digit-led key commit reports success'
assert_eq '1Key: 42' "$(git -C "$digitkey_repo" log -1 --format='%(trailers:only=true,unfold=true)')" \
    'the digit-led key parses via git''s own trailer format'

hyphenkey_repo="$tmp/trailer-hyphenkey-repo"
new_repo "$hyphenkey_repo"
printf 'change\n' > "$hyphenkey_repo/change.txt"
hyphenkey_rc=0
hyphenkey_out=$(cd "$hyphenkey_repo" && "$script" --message 'feat: hyphen-led trailer key' \
    --trailer '-Key: 42' -- change.txt 2>&1) || hyphenkey_rc=$?
assert_eq '0' "$hyphenkey_rc" 'a --trailer key starting with a hyphen is accepted, matching git'
assert_contains "$hyphenkey_out" 'committed' 'the hyphen-led key commit reports success'

# git rejects an underscore in a trailer key -- this helper must refuse it
# too, not silently commit a trailer git itself will not parse back out.
underscorekey_repo="$tmp/trailer-underscorekey-repo"
new_repo "$underscorekey_repo"
printf 'change\n' > "$underscorekey_repo/change.txt"
underscorekey_rc=0
underscorekey_out=$(cd "$underscorekey_repo" && "$script" --message 'feat: underscore trailer key' \
    --trailer 'Issue_ID: 42' -- change.txt 2>&1) || underscorekey_rc=$?
assert_eq '1' "$underscorekey_rc" 'a --trailer key containing an underscore is refused'
assert_contains "$underscorekey_out" 'git-trailer token' \
    'the refusal names the git-trailer token rule'
assert_eq '1' "$(git -C "$underscorekey_repo" log --oneline | wc -l)" \
    'an underscore-key --trailer refusal creates no new commit'

# A well-formed --trailer commits and parses as the caller intended via git's
# own trailers pretty-format.
wellformed_repo="$tmp/trailer-wellformed-repo"
new_repo "$wellformed_repo"
printf 'change\n' > "$wellformed_repo/change.txt"
wellformed_rc=0
wellformed_out=$(cd "$wellformed_repo" && "$script" --message 'feat: well-formed trailer' \
    --trailer 'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' -- change.txt 2>&1) || wellformed_rc=$?
assert_eq '0' "$wellformed_rc" 'a well-formed --trailer commits successfully'
assert_contains "$wellformed_out" 'committed' 'the well-formed trailer commit reports success'
assert_contains "$(git -C "$wellformed_repo" log -1 --format='%(trailers)')" \
    'Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>' \
    'the well-formed trailer parses via %(trailers) on the resulting commit'

# The post-commit verification step is a real backstop, not decoration: when
# git's own parsed trailers do not carry what this helper intended to commit,
# it fails loudly instead of printing the one-line success record. A fake git
# that answers the verification read with nothing (as if git's parser had
# disagreed) proves the check actually runs and actually gates the report.
verify_repo="$tmp/trailer-verify-repo"
new_repo "$verify_repo"
printf 'change\n' > "$verify_repo/change.txt"
verify_fake_bin="$tmp/verify-fake-bin"
mkdir -p "$verify_fake_bin"
verify_git_wrapper="$verify_fake_bin/git"
# shellcheck disable=SC2016  # The dollar expressions belong to the generated wrapper.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    '# Match on argv content, not $1 -- the verification read is pinned with' \
    '# a leading "-c trailer.separators=:", so "log" is not always $1.' \
    'for arg in "$@"; do' \
    '    if [[ $arg == *"%(trailers"* ]]; then' \
    '        exit 0' \
    '    fi' \
    'done' \
    'exec "$REAL_GIT" "$@"' > "$verify_git_wrapper"
chmod +x "$verify_git_wrapper"
verify_rc=0
verify_out=$(cd "$verify_repo" && PATH="$verify_fake_bin:$PATH" REAL_GIT="$real_git" \
    "$script" --message 'feat: verification backstop' --trailer "$TEST_TRAILER" \
    -- change.txt 2>&1) || verify_rc=$?
assert_eq '1' "$verify_rc" 'a trailer that fails post-commit verification is reported as an error'
assert_contains "$verify_out" 'post-commit verification failed' \
    'the failure names the post-commit verification step'
assert_contains "$verify_out" "$TEST_TRAILER" \
    'the failure names the specific trailer that did not verify'
assert_not_contains "$verify_out" 'committed ' \
    'a failed verification never prints the one-line success record'
assert_eq 'feat: verification backstop' "$(git -C "$verify_repo" log -1 --format=%s)" \
    'the underlying commit still exists -- verification cannot undo it, only surface it loudly'

# A repository-local `trailer.separators` config that drops ':' (e.g. "=")
# changes how git's OWN pretty-format parses trailers -- but this helper's
# documented, validated syntax is always "Key: value". Without pinning the
# separator on its own verification read, a real commit with a real,
# well-formed trailer gets misreported as a verification failure purely
# because of the repository's config, not anything wrong with the commit.
separators_repo="$tmp/trailer-separators-repo"
new_repo "$separators_repo"
git -C "$separators_repo" config trailer.separators '='
printf 'change\n' > "$separators_repo/change.txt"
separators_rc=0
separators_out=$(cd "$separators_repo" && "$script" --message 'feat: nonstandard trailer.separators' \
    --trailer 'Co-Authored-By: X <x@example.com>' -- change.txt 2>&1) || separators_rc=$?
assert_eq '0' "$separators_rc" \
    'a repository-local trailer.separators config that drops the colon does not fail verification'
assert_contains "$separators_out" 'committed' \
    'verification still reports success under a nonstandard trailer.separators config'

# --- Issue #345: the documented worker path (contract-read.sh's harness.trailer
# feeding worktree-commit.sh's --trailer directly, per worker-prompts.md) must
# produce a commit whose trailers actually parse and name the worker model --
# this is the end-to-end shape of the original defect, not just a unit check
# of either script in isolation.
contract_read="$root/agentkit/skills/.shared/scripts/contract-read.sh"
e2e_repo="$tmp/trailer-e2e-repo"
new_repo "$e2e_repo"
write_contract "$e2e_repo" claude 'Claude <noreply@anthropic.com>'
printf 'change\n' > "$e2e_repo/change.txt"
e2e_rc=0
worker_attribution=$(cd "$e2e_repo" && "$contract_read" --repo-root "$e2e_repo" \
    --get harness.trailer --worker-model claude-sonnet-5 2>&1) || e2e_rc=$?
assert_eq '0' "$e2e_rc" 'contract-read.sh resolves harness.trailer for the worker-model-bearing path'
e2e_commit_rc=0
e2e_commit_out=$(cd "$e2e_repo" && "$script" --message 'feat: worker attribution path' \
    --trailer "$worker_attribution" -- change.txt 2>&1) || e2e_commit_rc=$?
assert_eq '0' "$e2e_commit_rc" \
    'feeding harness.trailer straight into --trailer (the documented worker path) commits cleanly'
assert_contains "$e2e_commit_out" 'committed' \
    'the documented worker path reports the one-line success record'
e2e_trailers=$(git -C "$e2e_repo" log -1 --format='%(trailers:only=true,unfold=true)')
assert_eq 'Co-Authored-By: Claude claude-sonnet-5 <noreply@anthropic.com>' "$e2e_trailers" \
    'the documented worker path produces a non-empty, git-parseable trailer naming the worker model'

# Exact mode must refuse a commit when an unrelated path was already staged.
# This is the regression for root corrections accidentally sweeping a lead's
# staged work into the correction commit.
exact_repo="$tmp/exact-scope-repo"
new_repo "$exact_repo"
printf 'foreign\n' > "$exact_repo/foreign.txt"
printf 'requested\n' > "$exact_repo/requested.txt"
git -C "$exact_repo" add -- foreign.txt
exact_rc=0
exact_out=$(cd "$exact_repo" && "$script" --exact --message 'fix: exact scope' \
    --trailer "$TEST_TRAILER" -- requested.txt 2>&1) || exact_rc=$?
assert_eq '1' "$exact_rc" 'exact mode refuses a foreign staged path'
assert_contains "$exact_out" 'foreign.txt' \
    'exact-mode refusal names the foreign staged path'
assert_eq '' "$(git -C "$exact_repo" log -1 --format=%s | grep -F 'exact scope' || true)" \
    'exact-mode refusal does not create a commit'

# Git pathspecs can expand one directory operand to several staged paths. Exact
# scope follows that expansion instead of treating the directory as one file.
directory_repo="$tmp/exact-directory-repo"
new_repo "$directory_repo"
mkdir -p "$directory_repo/src"
printf 'one\n' > "$directory_repo/src/one.txt"
printf 'two\n' > "$directory_repo/src/two.txt"
directory_rc=0
directory_out=$(cd "$directory_repo" && "$script" --exact --message 'feat: commit directory scope' \
    --trailer "$TEST_TRAILER" -- src 2>&1) || directory_rc=$?
assert_eq '0' "$directory_rc" 'exact mode accepts a directory pathspec'
assert_contains "$directory_out" 'committed' 'directory pathspec commit reports success'
assert_eq $'src/one.txt\nsrc/two.txt' \
    "$(git -C "$directory_repo" diff-tree --no-commit-id --name-only -r HEAD | sort)" \
    'directory pathspec commits every matched file and nothing else'

# Unchanged operands produce no staged path, and repeated operands collapse to
# one path in Git's staged-name set. Neither should trip an argument-arity gate.
operand_repo="$tmp/exact-operands-repo"
new_repo "$operand_repo"
printf 'changed\n' > "$operand_repo/changed.txt"
operand_rc=0
operand_out=$(cd "$operand_repo" && "$script" --exact --message 'feat: deduplicate operands' \
    --trailer "$TEST_TRAILER" -- base.txt changed.txt changed.txt 2>&1) || operand_rc=$?
assert_eq '0' "$operand_rc" 'exact mode accepts unchanged and repeated operands'
assert_contains "$operand_out" 'committed' 'unchanged and repeated operands report success'
assert_eq 'changed.txt' \
    "$(git -C "$operand_repo" diff-tree --no-commit-id --name-only -r HEAD)" \
    'unchanged and repeated operands commit only the changed path'

# Rename detection is deliberately disabled for scope accounting: selecting a
# staged rename's live destination still keeps both old and new paths in scope.
rename_repo="$tmp/exact-rename-repo"
new_repo "$rename_repo"
git -C "$rename_repo" mv base.txt renamed.txt
rename_rc=0
rename_out=$(cd "$rename_repo" && "$script" --exact --message 'refactor: rename scoped file' \
    --trailer "$TEST_TRAILER" -- renamed.txt 2>&1) || rename_rc=$?
assert_eq '0' "$rename_rc" 'exact mode accepts a staged rename by destination operand'
assert_contains "$rename_out" 'committed' 'rename commit reports success'
assert_eq $'base.txt\nrenamed.txt' \
    "$(git -C "$rename_repo" diff-tree --no-commit-id --name-only --no-renames -r HEAD | sort)" \
    'rename scope compares old and new paths consistently without rename detection'

# --allow-empty must not turn an unrelated pre-staged path into an implicit
# operand. Exact mode keeps the path staged for the caller to handle.
allow_empty_staged_repo="$tmp/exact-allow-empty-staged-repo"
new_repo "$allow_empty_staged_repo"
printf 'foreign\n' > "$allow_empty_staged_repo/foreign.txt"
git -C "$allow_empty_staged_repo" add -- foreign.txt
allow_empty_staged_rc=0
allow_empty_staged_out=$(cd "$allow_empty_staged_repo" && "$script" --exact --allow-empty \
    --message 'fix: reject staged allow-empty scope' --trailer "$TEST_TRAILER" -- 2>&1) || allow_empty_staged_rc=$?
assert_eq '1' "$allow_empty_staged_rc" \
    'exact allow-empty refuses unrelated staged content'
assert_contains "$allow_empty_staged_out" 'foreign.txt' \
    'exact allow-empty refusal names the unrelated staged path'
assert_eq '' "$(git -C "$allow_empty_staged_repo" log -1 --format=%s | \
    grep -F 'reject staged allow-empty scope' || true)" \
    'exact allow-empty refusal does not create a commit'
assert_eq 'foreign.txt' "$(git -C "$allow_empty_staged_repo" diff --cached --name-only)" \
    'exact allow-empty refusal leaves the staged path untouched'

allow_empty_empty_repo="$tmp/exact-allow-empty-empty-repo"
new_repo "$allow_empty_empty_repo"
allow_empty_empty_rc=0
allow_empty_empty_out=$(cd "$allow_empty_empty_repo" && "$script" --exact --allow-empty \
    --message 'chore: record empty scope' --trailer "$TEST_TRAILER" -- 2>&1) || allow_empty_empty_rc=$?
assert_eq '0' "$allow_empty_empty_rc" \
    'exact allow-empty still permits a truly empty index'
assert_contains "$allow_empty_empty_out" 'committed' \
    'truly empty allow-empty commit reports success'
assert_eq 'chore: record empty scope' \
    "$(git -C "$allow_empty_empty_repo" log -1 --format=%s)" \
    'truly empty allow-empty commit keeps its message'
assert_eq '' "$(git -C "$allow_empty_empty_repo" diff-tree --no-commit-id --name-only -r HEAD)" \
    'truly empty allow-empty commit contains no paths'

# A tracked file outside the issue operands is refused even in include-staged
# mode, unless the caller names that exact path with --allow-outside.
outside_repo="$tmp/allow-outside-repo"
new_repo "$outside_repo"
printf 'manifest-v2\n' > "$outside_repo/manifest.txt"
printf 'requested\n' > "$outside_repo/requested.txt"
git -C "$outside_repo" add -- manifest.txt
outside_rc=0
outside_out=$(cd "$outside_repo" && "$script" --include-staged --message 'fix: reject outside path' \
    --trailer "$TEST_TRAILER" -- requested.txt 2>&1) || outside_rc=$?
assert_eq '1' "$outside_rc" 'include-staged refuses a tracked path outside the issue operands'
assert_contains "$outside_out" 'manifest.txt' 'outside-path refusal names the tracked path'
assert_contains "$outside_out" '--allow-outside' 'outside-path refusal names the explicit escape hatch'
allow_outside_rc=0
allow_outside_out=$(cd "$outside_repo" && "$script" --include-staged --message 'fix: allow outside path' \
    --trailer "$TEST_TRAILER" --allow-outside manifest.txt -- requested.txt 2>&1) || allow_outside_rc=$?
assert_eq '0' "$allow_outside_rc" 'allow-outside permits a deliberately named tracked path'
assert_contains "$allow_outside_out" 'committed' 'allow-outside reports the committed change'
assert_eq $'manifest.txt\nrequested.txt' \
    "$(git -C "$outside_repo" diff-tree --no-commit-id --name-only -r HEAD | sort)" \
    'allow-outside commits only the requested and explicitly allowed paths'

finish
