#!/usr/bin/env bash
# ak dispatcher and common helpers.
TEST_NAME=v2-common
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1

out=$("$AK" 2>&1); rc=$?
assert_eq 0 "$rc" 'bare ak prints usage and exits 0'
assert_contains "$out" 'usage: ak <command>' 'usage names the command form'

out=$("$AK" nope 2>&1); rc=$?
assert_eq 2 "$rc" 'unknown command exits 2'
assert_contains "$out" 'unknown command: nope' 'unknown command is named'

out=$("$AK" ../common 2>&1); rc=$?
assert_eq 2 "$rc" 'a path-shaped command is refused'

# shellcheck source=../../v2/lib/common.sh
source "$REPO/v2/lib/common.sh"
assert_eq 'acme/widget' "$(slug)" 'slug comes from config.env'
assert_eq 'main' "$(base_branch)" 'base falls back to origin/HEAD'
export AGENT_BASE_BRANCH=trunk
assert_eq 'trunk' "$(base_branch)" 'environment overrides config'
unset AGENT_BASE_BRANCH
printf 'AGENT_CMD_TEST="make test"\n' >>.agent/config.env
assert_eq 'make test' "$(cfg AGENT_CMD_TEST)" 'quoted config values are unquoted'
assert_eq 'dflt' "$(cfg AGENT_MISSING dflt)" 'missing keys use the default'

git worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
assert_eq "$repo" "$(main_root)" 'main_root resolves the main checkout from a linked worktree'
assert_eq 'acme/widget' "$(slug)" 'config is read from the main checkout in a worktree'
assert_eq 7 "$(issue_number)" 'issue number comes from the branch'
dir=$(ak_dir)
assert_eq "$WORK/wt/.ak" "$dir" 'ak_dir is inside the worktree'
assert_eq '' "$(git status --porcelain)" '.ak/ is excluded from git'

out=$(run_logged ok 'echo fine'); rc=$?
assert_eq 'PASS ok' "$out" 'run_logged prints one PASS line'
out=$(run_logged bad 'echo boom; exit 3'); rc=$?
assert_eq 3 "$rc" 'run_logged returns the command status'
assert_contains "$out" 'FAIL bad rc=3' 'run_logged names the failure'
assert_contains "$out" 'boom' 'run_logged prints the tail'

export CODEX_HOME=/x
assert_eq 'Codex <noreply@openai.com>' "$(trailer)" 'codex trailer'
unset CODEX_HOME
export CLAUDECODE=1
assert_eq 'claude' "$(harness)" 'claude harness'
export CODEX_THREAD_ID=t1
assert_eq 'codex' "$(harness)" 'a Codex shell launched from a Claude session is codex'
unset CLAUDECODE CODEX_THREAD_ID

finish
