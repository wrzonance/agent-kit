#!/usr/bin/env bash
# ak wait: the end state of every worker of the open wave, from result files and transcripts, and the open-wave marker.
TEST_NAME=v2-wait
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1
export AK_WAIT_POLL_S=1 AK_WAIT_HANG_S=3 HOME="$WORK/home"
export CLAUDE_CODE_SESSION_ID=sess-1
mkdir -p "$repo/.ak/runs" "$HOME"
marker="$repo/.ak/wave.open"
slug=$(printf '%s' "$repo" | tr -c 'a-zA-Z0-9' '-')
subdir="$HOME/.claude/projects/$slug/sess-1/subagents"

# set_run N...: a current run whose wave 1 holds each N as a spawned issue in its own plain worktree.
set_run() {
    local items='' n
    for n in "$@"; do
        mkdir -p "$WORK/wt/$n/.ak"
        items+="${items:+,}{\"kind\":\"issue\",\"n\":$n,\"worktree\":\"$WORK/wt/$n\",\"spawned_at\":${SPAWNED_AT:-0},\"wave\":1,\"state\":\"spawned\",\"needs\":[]}"
    done
    printf '{"run":"r1","open_wave":1,"items":[%s]}\n' "$items" >"$repo/.ak/runs/r1.json"
    printf 'r1\n' >"$repo/.ak/runs/current"
}
# claude_agent ID N FINISHED: a sub-agent transcript naming issue N's worktree.
claude_agent() {
    mkdir -p "$subdir"
    printf '{"type":"user","message":{"content":"worktree %s"}}\n' "$WORK/wt/$2" >"$subdir/agent-$1.jsonl"
    printf '{"finished":%s}\n' "$3" >"$subdir/agent-$1.meta.json"
}

set_run 5
printf 'pr=none\n' >"$WORK/wt/5/.ak/result"
out=$("$AK" wait 2>&1); rc=$?
assert_eq 0 "$rc" 'a result already there settles at once'
assert_eq $'issue=5 state=reported\nwave=1 settled=1/1' "$out" 'reported is printed with the closing count'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker is gone after ak wait exits'

set_run 5
rm -f "$WORK/wt/5/.ak/result"
claude_agent a5 5 true
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result' 'a finished transcript and no result ends without waiting for the threshold'

claude_agent a5 5 false
touch -d '10 seconds ago' "$subdir/agent-a5.jsonl"
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=hung' 'a transcript quiet past the threshold is hung'

rm -rf "$subdir"
touch -d '10 seconds ago' "$WORK/wt/5/.ak"/* "$WORK/wt/5/.ak" 2>/dev/null
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=unwatched note=no transcript matched; fell back to worktree activity' 'no transcript and an idle worktree is unwatched, naming the fallback'

# --check: 3 while running, 0 once a result appears.
set_run 5
claude_agent a5 5 false
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq 3 "$rc" '--check exits 3 while a worker runs'
assert_eq $'issue=5 state=running\nwave=1 settled=0/1' "$out" '--check prints the running state'
printf 'pr=none\n' >"$WORK/wt/5/.ak/result"
"$AK" wait --check >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" '--check exits 0 once the result is there'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" '--check leaves no marker'

# Codex: children are matched by parent thread and agent_path, and end on task_complete.
rm -f "$WORK/wt/5/.ak/result"
rm -rf "$subdir"
unset CLAUDE_CODE_SESSION_ID
export CODEX_THREAD_ID=root-thread CODEX_HOME="$WORK/codex"
sessions="$CODEX_HOME/sessions/2026/10/24"
mkdir -p "$sessions"
fx="$V2_TESTS/fixtures/transcripts/codex"
codex_child() {
    sed -e 's/01a16bd5-d8ed-7b30-aacc-c6261877bc16/root-thread/g' -e "s#/root/normal#/root/issue_5#g" "$fx/$1" >"$sessions/rollout-$2.jsonl"
}
codex_child child-normal.jsonl a
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result' 'a Codex child that completed without a result ended'
head -n 2 "$sessions/rollout-a.jsonl" >"$sessions/rollout-b.jsonl"
sed -i 's#/root/issue_5#/root/issue_6#g' "$sessions/rollout-a.jsonl"
touch "$sessions/rollout-b.jsonl"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=running' 'a Codex child still working is running'
sed -e 's/01a16bd5-d8ed-7b30-aacc-c6261877bc16/other-root/g' "$fx/child-normal.jsonl" | sed 's#/root/normal#/root/issue_5#' >"$sessions/rollout-c.jsonl"
rm -f "$sessions/rollout-b.jsonl"
out=$("$AK" wait --check 2>&1)
assert_not_contains "$out" 'ended-without-result' 'a child of another root thread is not matched'
unset CODEX_THREAD_ID CODEX_HOME
export CLAUDE_CODE_SESSION_ID=sess-1

export AK_WAIT_HANG_S=60
# The marker: a live pid with the wrong start time is stale and replaced.
set_run 5
claude_agent a5 5 false
printf 'pid=%s\nstart=1\nsession=x\n' "$$" >"$marker"
"$AK" wait >"$WORK/w1.out" 2>&1 &
w1=$!
sleep 1
assert_eq "$w1" "$(sed -n 's/^pid=//p' "$marker")" 'a marker with a live pid and the wrong start time is replaced'
assert_contains "$(cat "$marker")" 'session=sess-1' 'the marker carries the session id'
assert_not_contains "$(cat "$marker")" 'cwd=' 'a known session leaves out the cwd'
# A second ak wait attaches: same marker, no second watcher; both finish when the result lands.
"$AK" wait >"$WORK/w2.out" 2>&1 &
w2=$!
sleep 2
assert_eq "$w1" "$(sed -n 's/^pid=//p' "$marker")" 'a second ak wait does not replace the marker'
printf 'pr=none\n' >"$WORK/wt/5/.ak/result"
wait "$w1"
wait "$w2"
assert_eq $'issue=5 state=reported\nwave=1 settled=1/1' "$(cat "$WORK/w1.out")" 'the watcher prints the summary'
assert_eq "$(cat "$WORK/w1.out")" "$(cat "$WORK/w2.out")" 'the attached ak wait prints the same summary'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker is cleared when the watcher exits'

export AK_WAIT_HANG_S=3
# Without a session id the marker records the cwd.
unset CLAUDE_CODE_SESSION_ID
rm -f "$WORK/wt/5/.ak/result"
touch "$subdir/agent-a5.jsonl"
"$AK" wait >/dev/null 2>&1 &
w1=$!
sleep 1
assert_contains "$(cat "$marker")" "cwd=$repo" 'no session id: the marker names the cwd'
assert_contains "$(cat "$marker")" 'session=' 'and an empty session line'
kill "$w1"
wait "$w1" 2>/dev/null
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker goes when the watcher is terminated'

# A worktree path that is a prefix of another's must not take the other worker's transcript.
set_run 5 50
rm -rf "$subdir"
claude_agent a50 50 true
claude_agent a5 5 false
out=$("$AK" wait --check 2>&1)
assert_eq $'issue=5 state=running\nissue=50 state=ended-without-result\nwave=1 settled=1/2' "$out" 'wt/5 does not match the transcript of wt/50'
rm -rf "$subdir"
claude_agent a50 50 true
touch "$WORK/wt/5/.ak"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=running' 'wt/5 with only the wt/50 transcript has no worker of its own'

# A finished transcript from an earlier spawn of the same worktree is not this worker's.
rm -rf "$subdir"
claude_agent old 5 true
SPAWNED_AT=$(($(date +%s) + 60)) set_run 5
touch "$WORK/wt/5/.ak"
out=$("$AK" wait --check 2>&1)
assert_eq $'issue=5 state=running\nwave=1 settled=0/1' "$out" 'an older finished transcript never reads as ended-without-result'
SPAWNED_AT=0 set_run 5
printf 'x\n' >"$WORK/wt/5/.ak/prompt.md"
touch -d '+60 seconds' "$WORK/wt/5/.ak/prompt.md"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=running' 'a prompt rewritten after the transcript was created also retires it'
rm -f "$WORK/wt/5/.ak/prompt.md"

# An item with no worktree is not watchable.
printf '{"run":"r1","open_wave":1,"items":[{"kind":"issue","n":7,"worktree":"","wave":1,"state":"pending","needs":[]},{"kind":"issue","n":8,"worktree":"","wave":1,"state":"queued","needs":[]}]}\n' >"$repo/.ak/runs/r1.json"
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq $'issue=7 state=running\nwave=1 settled=0/1' "$out" 'a pending item without a worktree reads running, a queued one is not watched'
assert_eq 3 "$rc" 'and keeps --check at 3'
touch -d '10 seconds ago' "$repo/.ak/runs/r1.json"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=7 state=unwatched note=no worktree recorded' 'past the threshold it is unwatched, naming why'
out=$("$AK" wait --issue 8 --check 2>&1)
assert_eq 'wave=1 settled=0/0' "$out" 'naming a queued item without a worktree watches nothing'

# A watcher that dies leaves the wait to the attached ak wait, which becomes the watcher.
set_run 5
rm -rf "$subdir"
claude_agent a5 5 false
export AK_WAIT_HANG_S=60
"$AK" wait >"$WORK/w1.out" 2>&1 &
w1=$!
sleep 1
"$AK" wait >"$WORK/w2.out" 2>&1 &
w2=$!
sleep 1
kill -9 "$w1"
wait "$w1" 2>/dev/null
sleep 3
assert_eq "$w2" "$(sed -n 's/^pid=//p' "$marker")" 'the attached ak wait takes the marker when the watcher dies'
assert_eq 1 "$(grep -c '^pid=' "$marker")" 'and keeps exactly one marker'
kill -0 "$w2" 2>/dev/null && alive=yes || alive=no
assert_eq yes "$alive" 'it keeps waiting while the worker runs'
printf 'pr=none\n' >"$WORK/wt/5/.ak/result"
wait "$w2"; rc=$?
assert_eq 0 "$rc" 'and exits 0 once settled'
assert_eq $'issue=5 state=reported\nwave=1 settled=1/1' "$(cat "$WORK/w2.out")" 'with the summary'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'and clears the marker'
export AK_WAIT_HANG_S=3

# An unreadable run is exit 1 and leaves no marker.
printf 'not json' >"$repo/.ak/runs/r1.json"
"$AK" wait >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" 'an unreadable run exits 1'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'and writes no marker'
finish
