#!/usr/bin/env bash
# Fresh plans recover unfinished board work without overwriting live or dirty worktrees.
set -uo pipefail
TEST_NAME=v2-plan-recovery
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=plan-fixture.sh
source "$V2_TESTS/plan-fixture.sh"
export HOME="$WORK/home" CODEX_HOME="$WORK/codex" CODEX_THREAD_ID=owner
mkdir -p "$HOME" "$CODEX_HOME/sessions"

fresh() {
    cd "$WORK" || exit 1
    rm -rf -- "$WORK/repo" "$WORK/origin.git" "$CODEX_HOME/sessions"
    mkdir -p "$CODEX_HOME/sessions"
    : >"$FAKE_GH_ROUTES"
    : >"$FAKE_GH_LOG"
    repo=$(board_repo)
    cd "$repo" || exit 1
    wt="$repo/.worktrees/feat/issue-5"
}

start() {
    issue_route 5 'Finish src/a.txt'
    default_routes
    "$AK" plan --issue 5 >/dev/null 2>&1
    runfile="$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json"
    mkdir -p "$wt/.ak/logs"
    printf 'setup done\n' >"$wt/.ak/logs/setup.log"
}

age_work() {
    local gitdir
    gitdir=$(git -C "$wt" rev-parse --absolute-git-dir)
    find "$wt" "$gitdir" -type f -exec touch -d '-2 hours' {} +
    find "$wt/.ak" -type d -exec touch -d '-2 hours' {} +
    jq '.items[].spawned_at = (now - 7200 | floor)' "$runfile" >"$WORK/aged.json"
    mv "$WORK/aged.json" "$runfile"
    touch -d '-2 days' "$runfile"
}

child() {
    jq -nc --arg root "$1" '{type:"session_meta",payload:{parent_thread_id:$root,agent_path:"/root/issue_5"}}' >"$CODEX_HOME/sessions/rollout-worker.jsonl"
    printf '{"type":"event_msg","payload":{"type":"%s"}}\n' "$2" >>"$CODEX_HOME/sessions/rollout-worker.jsonl"
}

fresh
board_route 5 "{\"items\":[$(board_item 5 'In progress'),$(board_item 6 'In review'),$(board_item 7 Backlog)]}"
issue_route 5 'Finish src/a.txt'
issue_route 6 'Finish src/b.txt'
issue_route 7 'Backlog'
default_routes
out=$("$AK" plan 2>&1)
assert_contains "$out" 'spawn issue=5 ' 'automatic planning considers In progress'
assert_contains "$out" 'spawn issue=6 ' 'automatic planning considers In review without an open PR'
assert_not_contains "$out" 'issue=7' 'Backlog still requires yolo'
assert_not_contains "$out" 'next=nothing workable' 'unfinished work prevents a false empty queue'

fresh
board_route 5 "{\"items\":[$(board_item 5 'In progress'),$(board_item 6 Ready)]}"
issue_route 5 'Finish src/a.txt'
issue_route 6 'Finish src/b.txt'
default_routes
out=$("$AK" plan --limit 1 2>&1)
assert_contains "$out" 'spawn issue=6 ' 'Ready retains priority'
assert_not_contains "$out" 'spawn issue=5 ' 'recovery respects the spawn limit'

# An old setup marker and old dirty work are resumable, and every local byte survives.
fresh
start
printf 'staged\n' >"$wt/src/a.txt"
git -C "$wt" add src/a.txt
printf 'unstaged\n' >>"$wt/src/a.txt"
mkdir -p "$wt/new directory"
printf 'unfinished\n' >"$wt/new directory/new file.txt"
before=$(export GIT_OPTIONAL_LOCKS=0; git -C "$wt" diff; git -C "$wt" diff --cached)
age_work
out=$("$AK" plan --new --issue 5 2>&1)
assert_contains "$out" "spawn issue=5 cwd=$wt" 'stale dirty work resumes in its original worktree'
assert_eq "$before" "$(git -C "$wt" diff; git -C "$wt" diff --cached)" 'staged and unstaged changes survive recovery'
assert_eq unfinished "$(cat "$wt/new directory/new file.txt")" 'untracked work survives recovery'
assert_contains "$(cat "$wt/.ak/prompt.md")" 'uncommitted changes' 'the worker is told to inspect unfinished local changes'

# Recent untracked writes must count even when status.showUntrackedFiles hides them.
fresh
start
age_work
git -C "$wt" config status.showUntrackedFiles no
printf 'working now\n' >"$wt/new file.txt"
out=$("$AK" plan --new --issue 5 2>&1)
assert_contains "$out" 'skip issue=5 reason=running' 'recent untracked work protects an old run from duplicate dispatch'
assert_eq 'working now' "$(cat "$wt/new file.txt")" 'the active untracked file is untouched'

fresh
start
age_work
printf 'staged now\n' >"$wt/staged.txt"
git -C "$wt" add staged.txt
out=$("$AK" plan --new --issue 5 2>&1)
assert_contains "$out" 'skip issue=5 reason=running' 'recent staged work protects a quiet worker'

# Transcript evidence belongs to the original session, even when a new root replans days later.
fresh
start
age_work
child owner task_started
out=$(CODEX_THREAD_ID=another-root "$AK" plan --new --issue 5 2>&1)
assert_contains "$out" 'skip issue=5 reason=running' 'a live worker from another root is not duplicated'
child owner task_complete
printf 'left for the next worker\n' >"$wt/unfinished.txt"
out=$(CODEX_THREAD_ID=another-root "$AK" plan --new --issue 5 2>&1)
assert_contains "$out" 'spawn issue=5 ' 'an ended worker hands over even recent unfinished files'
assert_eq 'left for the next worker' "$(cat "$wt/unfinished.txt")" 'ended-worker handoff preserves new files'

fresh
start
age_work
child owner task_started
jq '.items[].ended = "hung"' "$runfile" >"$WORK/hung.json"
mv "$WORK/hung.json" "$runfile"
out=$("$AK" plan --new --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'a hung classification is not evidence the worker was stopped'

fresh
start
rm -rf -- "$wt/.ak/logs"
child owner task_started
out=$("$AK" plan --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'a worker already thinking is live before any setup or verify command'

fresh
start
age_work
child owner task_started
touch -d '-8 days' "$CODEX_HOME/sessions/rollout-worker.jsonl"
out=$("$AK" plan --new --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'a quiet live transcript is not discarded by a seven-day search cutoff'

fresh
start
age_work
jq '.items[].ended = "ended-without-result"' "$runfile" >"$WORK/ended.json"
mv "$WORK/ended.json" "$runfile"
jq '.session = "new-owner" | del(.items[].ended)' "$runfile" >"${runfile%.json}-2.json"
child new-owner task_started
out=$("$AK" plan --new --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'the newer run from the same second owns the worker'

fresh
CODEX_THREAD_ID='' CLAUDECODE=1 CLAUDE_CODE_SESSION_ID=claude-owner start
age_work
subdir="$HOME/.claude/projects/fixture/claude-owner/subagents"
mkdir -p "$subdir"
jq -nc --arg wt "$wt" '{type:"user",message:{content: ("worktree " + $wt)}}' >"$subdir/agent-worker.jsonl"
printf '{"finished":false}\n' >"$subdir/agent-worker.meta.json"
out=$("$AK" plan --new --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'a Codex replan respects a live worker owned by a Claude session'
printf '{"finished":true}\n' >"$subdir/agent-worker.meta.json"
out=$("$AK" plan --new --issue 5 2>&1)
assert_contains "$out" 'spawn issue=5 ' 'a finished Claude worker is resumable from another harness'

fresh
start
child owner turn_aborted
out=$("$AK" plan --issue 5 2>&1)
assert_contains "$out" 'spawn issue=5 ' 'an interrupted worker resumes without needing a separate wait settlement'

# A receipt describes a PR, not completion of the still-open issue.
for state in merged closed open unreadable; do
    fresh
    route 'api repos/acme/widget/pulls/77' "$(case $state in
        merged) printf '{"state":"closed","merged":true}' ;;
        closed) printf '{"state":"closed","merged":false}' ;;
        open) printf '{"state":"open","merged":false}' ;;
        unreadable) printf '{}' ;;
    esac)" "$([[ $state == unreadable ]] && echo 1 || echo 0)"
    start
    printf 'pr=https://github.com/acme/widget/pull/77\nci=green\nreview=done\nhead=abc\nnote=remaining: implement the second half\n' >"$wt/.ak/result"
    printf 'Remaining: implement the second half\n' >"$wt/.ak/receipt.md"
    printf 'old review\n' >"$wt/.ak/review.md"
    printf 'old findings\n' >"$wt/.ak/findings"
    mkdir -p "$WORK/archive-target"
    printf 'keep\n' >"$WORK/archive-target/result"
    ln -s "$WORK/archive-target" "$wt/.ak/previous-result"
    out=$("$AK" plan --new --issue 5 2>&1)
    if [[ $state == merged || $state == closed ]]; then
        assert_contains "$out" 'spawn issue=5 ' "$state PR allows assessment of the open issue's remainder"
        prompt=$(cat "$wt/.ak/prompt.md")
        assert_contains "$prompt" 'implement the second half' 'the earlier completion evidence reaches the worker'
        assert_contains "$prompt" 'https://github.com/acme/widget/pull/77' 'the worker can inspect the previous PR'
        assert_eq no "$([[ -f $wt/.ak/review.md ]] && echo yes || echo no)" 'a follow-up PR cannot reuse the previous PR review'
        assert_eq no "$([[ -f $wt/.ak/findings ]] && echo yes || echo no)" 'old review dispositions are retired with that PR'
        assert_eq keep "$(cat "$WORK/archive-target/result")" 'archiving evidence never follows a worker-created directory link'
        # Another interrupted attempt must still receive the original remaining work.
        child owner turn_aborted
        out=$("$AK" plan --new --issue 5 2>&1)
        assert_contains "$out" 'spawn issue=5 ' 'the follow-up attempt can itself be resumed'
        assert_contains "$(cat "$wt/.ak/prompt.md")" 'implement the second half' 'previous completion evidence survives another restart'
    else
        assert_not_contains "$out" 'spawn issue=5 ' "$state PR is not treated as permission to restart"
        assert_contains "$(cat "$wt/.ak/result")" 'pull/77' 'a held result is preserved'
    fi
done

fresh
start
printf 'pr=none\nnote=parked: needs a manual credential\n' >"$wt/.ak/result"
git -C "$wt" checkout -q -b fix/someone-else
printf 'somebody else\n' >"$wt/src/a.txt"
out=$("$AK" plan --new --issue 5 2>&1)
assert_not_contains "$out" 'spawn issue=5 ' 'a mismatched branch at the expected path is never reused'
assert_eq 'somebody else' "$(cat "$wt/src/a.txt")" 'a mismatched worktree is left intact'

finish
