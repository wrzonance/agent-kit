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
        rm -f "$WORK/wt/$n/.ak/result"
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

# green_result: a worker's receipt for a green PR.
green_result() { printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=n\n'; }
reported5='issue=5 pr=https://github.com/acme/widget/pull/9 ci=green review=done note=n'
sum1="$repo/.ak/runs/r1.wave1.summary"

set_run 5
green_result >"$WORK/wt/5/.ak/result"
out=$("$AK" wait 2>&1); rc=$?
assert_eq 0 "$rc" 'a result already there settles at once'
assert_eq "$reported5"$'\n'"wave=1 settled=1/1 summary=$sum1" "$out" 'a reported worker prints its collect line and the closing count'
assert_eq "$out" "$(cat "$sum1")" 'the summary file holds exactly what was printed'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker is gone after ak wait exits'

set_run 5
rm -f "$WORK/wt/5/.ak/result"
claude_agent a5 5 true
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result next=ak plan --issue 5' 'a finished transcript and no result ends without waiting for the threshold, naming the recovery'

claude_agent a5 5 false
touch -d '10 seconds ago' "$subdir/agent-a5.jsonl"
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=hung next=stop its worker (Claude TaskStop, Codex interrupt_agent), then ak plan --issue 5' 'a hung worker is stopped, then planned again'

rm -rf "$subdir"
touch -d '10 seconds ago' "$WORK/wt/5/.ak"/* "$WORK/wt/5/.ak" 2>/dev/null
out=$("$AK" wait 2>&1)
assert_contains "$out" 'issue=5 state=unwatched note=no transcript matched; fell back to worktree activity next=ak plan --issue 5' 'no transcript and an idle worktree is unwatched, naming the fallback'

# --check: 3 while running, 0 once a result appears.
set_run 5
claude_agent a5 5 false
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq 3 "$rc" '--check exits 3 while a worker runs'
assert_eq $'issue=5 state=running\nwave=1 settled=0/1' "$out" '--check prints the running state'
green_result >"$WORK/wt/5/.ak/result"
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
green_result >"$WORK/wt/5/.ak/result"
wait "$w1"
wait "$w2"
assert_eq "$reported5"$'\n'"wave=1 settled=1/1 summary=$sum1" "$(cat "$WORK/w1.out")" 'the watcher prints the summary'
assert_eq "$(cat "$WORK/w1.out")" "$(cat "$WORK/w2.out")" 'the attached ak wait prints the same summary'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker is cleared when the watcher exits'

export AK_WAIT_HANG_S=3
# Without a session id the marker records the cwd.
unset CLAUDE_CODE_SESSION_ID
set_run 5
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
green_result >"$WORK/wt/5/.ak/result"
wait "$w2"; rc=$?
assert_eq 0 "$rc" 'and exits 0 once settled'
assert_eq "$reported5"$'\n'"wave=1 settled=1/1 summary=$sum1" "$(cat "$WORK/w2.out")" 'with the summary'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'and clears the marker'
export AK_WAIT_HANG_S=3

# An unreadable run is exit 1 and leaves no marker.
printf 'not json' >"$repo/.ak/runs/r1.json"
"$AK" wait >/dev/null 2>&1; rc=$?
assert_eq 1 "$rc" 'an unreadable run exits 1'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'and writes no marker'

# The wait covers CI: a reported item whose checks are pending then green settles green with no root call, and the
# summary mixes collected and unrecovered workers.
printf '{"number":9,"head":{"sha":"abc"}}' >"$WORK/pr9.json"
printf '{"check_runs":[{"name":"lint","status":"in_progress","conclusion":null}]}' >"$WORK/runs-pending.json"
printf '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' >"$WORK/runs-green.json"
ci_routes() {
    printf 'api repos/acme/widget/pulls/9\t%s\t0\napi repos/acme/widget/commits/abc/check-runs*\t%s\t0\n' "$WORK/pr9.json" "$1" >"$FAKE_GH_ROUTES"
}
set_run 5 6
rm -rf "$subdir"
claude_agent a6 6 false
printf 'pr=https://github.com/acme/widget/pull/9\nci=pending\nreview=done\nhead=abc\nnote=n\n' >"$WORK/wt/5/.ak/result"
ci_routes "$WORK/runs-pending.json"
(sleep 3; ci_routes "$WORK/runs-green.json"; printf 'x\n' >/dev/null) &
swap=$!
touch -d '10 seconds ago' "$subdir/agent-a6.jsonl"
out=$(AK_WAIT_HANG_S=5 "$AK" wait 2>&1)
wait "$swap"
assert_contains "$out" 'issue=5 pr=https://github.com/acme/widget/pull/9 ci=green' 'the wait covered the pending CI and reports it green'
assert_contains "$out" 'issue=6 state=hung next=stop its worker' 'the same summary names the hung worker'
assert_eq "wave=1 settled=2/2 summary=$sum1" "$(tail -n 1 "$sum1")" 'the summary file ends with the closing count'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the marker is gone once the summary is written'

# Correction round: --issue 12 keeps waiting past an old result until a newer one is written.
set_run 12
rm -rf "$subdir"
claude_agent a12 12 true
green_result >"$WORK/wt/12/.ak/result"
touch -d '1 minute ago' "$WORK/wt/12/.ak/result" "$subdir/agent-a12.jsonl" "$subdir/agent-a12.meta.json"
jq '.items[0].state = "collected"' "$repo/.ak/runs/r1.json" >"$WORK/r.tmp" && mv "$WORK/r.tmp" "$repo/.ak/runs/r1.json"
ci_routes "$WORK/runs-green.json"
export AK_WAIT_HANG_S=60
"$AK" wait --issue 12 >"$WORK/c1.out" 2>&1 &
c1=$!
sleep 3
kill -0 "$c1" 2>/dev/null && alive=yes || alive=no
assert_eq yes "$alive" 'an old result and an old end record do not settle a correction round'
assert_eq spawned "$(jq -r '.items[0].state' "$repo/.ak/runs/r1.json")" 'the correction item is back in the open wave'
printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=fixed\n' >"$WORK/wt/12/.ak/result"
wait "$c1"; rc=$?
assert_eq 0 "$rc" 'a newer result settles the round'
assert_contains "$(cat "$WORK/c1.out")" 'issue=12 pr=https://github.com/acme/widget/pull/9 ci=green review=done note=fixed' 'with the new collect line'
assert_contains "$(tail -n 1 "$WORK/c1.out")" 'wave=1 settled=1/1 summary=' 'and the closing count'
assert_eq no "$([[ -e $repo/.ak/round.issue-12 ]] && echo yes || echo no)" 'the round stamp is gone once the item settles'

# --check in a correction round shares the stamp: the old result and end record never settle it.
set_run 13
rm -rf "$subdir"
claude_agent a13 13 true
green_result >"$WORK/wt/13/.ak/result"
touch -d '1 minute ago' "$WORK/wt/13/.ak/result" "$subdir/agent-a13.jsonl" "$subdir/agent-a13.meta.json"
jq '.items[0].state = "collected"' "$repo/.ak/runs/r1.json" >"$WORK/r.tmp" && mv "$WORK/r.tmp" "$repo/.ak/runs/r1.json"
out=$("$AK" wait --check --issue 13 2>&1); rc=$?
assert_eq 3 "$rc" '--check --issue N keeps running past an old result and end record'
assert_eq $'issue=13 state=running\nwave=1 settled=0/1' "$out" 'and prints the item running'
"$AK" wait --check --issue 13 >/dev/null 2>&1; rc=$?
assert_eq 3 "$rc" 'a second --check reuses the stamp and still runs'
assert_eq yes "$([[ -e $repo/.ak/round.issue-13 ]] && echo yes || echo no)" 'the round stamp persists between calls'
printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=fixed\n' >"$WORK/wt/13/.ak/result"
out=$("$AK" wait --check --issue 13 2>&1); rc=$?
assert_eq 0 "$rc" 'a newer result settles --check'
assert_eq $'issue=13 state=reported\nwave=1 settled=1/1' "$out" 'with the item reported'
"$AK" wait --issue 13 >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" 'the blocking wait shares the stamp and settles on the same result'
assert_eq no "$([[ -e $repo/.ak/round.issue-13 ]] && echo yes || echo no)" 'the stamp is gone after the settle, so the next round starts fresh'
finish
