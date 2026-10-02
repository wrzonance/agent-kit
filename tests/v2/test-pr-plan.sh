#!/usr/bin/env bash
# ak pr-plan: one worktree and worker prompt per open PR, and a run file.
TEST_NAME=v2-pr-plan
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1
for b in feat/a feat/b; do
    git checkout -q -b "$b" main
    printf '%s\n' "$b" >"src/${b#feat/}.txt"
    git add src && git commit -q -m "$b" && git push -q origin "$b" 2>/dev/null
done
git checkout -q main
git branch -q -D feat/b
git worktree add -q "$WORK/existing-a" feat/a

pr_json() { # N HEAD BASE STATE [MERGED_AT] [HEAD_REPO]
    printf '{"number":%s,"title":"Fix & things <%s>","state":"%s","merged_at":%s,"head":{"ref":"%s","sha":"abc","repo":{"full_name":"%s"}},"base":{"ref":"%s"}}' \
        "$1" "$1" "$4" "${5:-null}" "$2" "${6:-acme/widget}" "$3"
}
route 'api repos/acme/widget/pulls/11' "$(pr_json 11 feat/a main open)"
route 'api repos/acme/widget/pulls/12' "$(pr_json 12 feat/b feat/a open)"
route 'api repos/acme/widget/pulls/13' "$(pr_json 13 feat/c main closed)"
route 'api repos/acme/widget/pulls/14' "$(pr_json 14 feat/d main closed '"2026-01-01T00:00:00Z"')"
route 'api repos/acme/widget/pulls/15' "$(pr_json 15 feat/e main open null someone/fork)"

out=$("$AK" pr-plan 2>&1); rc=$?
assert_eq 2 "$rc" 'no --pr is a usage error'
out=$("$AK" pr-plan --pr x 2>&1); rc=$?
assert_eq 2 "$rc" 'a non-numeric PR is a usage error'

printf 'dirty\n' >>src/a.txt
export CODEX_HOME=/x AGENT_WORKER_MODELS='claude-sonnet-5,gpt-5.6-terra' AGENT_WORKER_EFFORT=high
out=$("$AK" pr-plan --pr 11 --pr 12 --pr 13 --pr 14 --pr 15 2>&1); rc=$?
assert_eq 0 "$rc" 'pr-plan exits 0'
run=$(sed -n 's/^run=//p' <<<"$out")
assert_contains "$out" "spawn pr=11 cwd=$WORK/existing-a prompt=$WORK/existing-a/.ak/prompt.md model=gpt-5.6-terra effort=high" 'an existing worktree is reused; model matches the harness'
wt="$repo/.worktrees/feat/b"
assert_contains "$out" "spawn pr=12 cwd=$wt prompt=$wt/.ak/prompt.md" 'a new worktree is created under .worktrees'
assert_contains "$out" 'drop pr=13 reason=closed' 'a closed PR is dropped'
assert_contains "$out" 'drop pr=14 reason=merged' 'a merged PR is dropped'
assert_contains "$out" 'drop pr=15 reason=fork' 'a fork PR is dropped'
assert_eq feat/b "$(git -C "$wt" branch --show-current)" 'the worktree is on the PR branch'
assert_eq origin/feat/b "$(git -C "$wt" rev-parse --abbrev-ref '@{u}')" 'the branch tracks origin'
assert_eq 12 "$(cat "$wt/.ak/pr")" '.ak/pr holds the number'
assert_eq feat/a "$(cat "$wt/.ak/base")" '.ak/base holds the PR base'
prompt=$(cat "$wt/.ak/prompt.md")
assert_contains "$prompt" 'PR #12 Fix & things <12>' 'the title is substituted verbatim'
assert_contains "$prompt" "branch feat/b into feat/a" 'branch and base are substituted'
assert_contains "$prompt" "$REPO/v2/bin/ak review" 'the ak path is absolute'
assert_not_contains "$prompt" '{{' 'no placeholder is left'
file="$repo/.ak/runs/$run.json"
assert_eq "$run" "$(cat "$repo/.ak/runs/current")" 'current names the run'
assert_eq '11 12' "$(jq -r '[.items[] | select(.kind == "pr" and .state == "spawned") | .n] | join(" ")' "$file")" 'the run file lists the spawned PRs'
assert_eq "$wt" "$(jq -r '.items[1].worktree' "$file")" 'the run file records the worktree'
assert_contains "$(jq -r .porcelain "$file")" 'src/a.txt' 'the run file records the root porcelain'
assert_eq '' "$(git status --porcelain --untracked-files=all -- .ak .worktrees)" '.ak and worktrees stay out of git status'

printf 'pr=old\n' >"$wt/.ak/result"
unset CODEX_HOME AGENT_WORKER_MODELS AGENT_WORKER_EFFORT
export CLAUDECODE=1
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" "spawn pr=12 cwd=$wt prompt=$wt/.ak/prompt.md model=sonnet effort=medium" 'a rerun reuses the worktree with claude defaults'
assert_eq no "$([[ -e $wt/.ak/result ]] && echo yes || echo no)" 'a stale result is removed'
run2=$(sed -n 's/^run=//p' <<<"$out")
assert_eq no "$([[ $run2 == "$run" ]] && echo yes || echo no)" 'a second run gets its own id'

# A PR a worker already took to green and reviewed at this head gets no second worker (field run: re-reviewing seven
# such PRs cost 19.6M tokens and turned four of them red). A result for an older head still respawns.
printf 'pr=12\nci=green\nreview=done\nhead=abc\nnote=findings=0\n' >"$wt/.ak/result"
printf 'keep\n' >"$wt/.ak/prompt.md"
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" 'skip pr=12 reason=green-and-reviewed-at-head' 'a PR green and reviewed at its head is skipped'
assert_not_contains "$out" 'spawn pr=12' 'a skipped PR gets no worker'
assert_eq keep "$(cat "$wt/.ak/prompt.md")" 'a skipped PR keeps its worktree state'
run3=$(sed -n 's/^run=//p' <<<"$out")
assert_eq collected "$(jq -r '.items[0].state' "$repo/.ak/runs/$run3.json")" 'a skipped PR is recorded as collected'
printf 'pr=12\nci=green\nreview=done\nhead=old\n' >"$wt/.ak/result"
out=$("$AK" pr-plan --pr 12 2>&1)
assert_contains "$out" 'spawn pr=12' 'a result for an older head respawns the worker'

finish
