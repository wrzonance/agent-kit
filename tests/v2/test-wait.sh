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
assert_eq "$reported5"$'\n'"wave=1 settled=1/1" "$out" 'a reported worker prints its collect line and the closing count'
# The closing count names no file: roots read the summary path it used to print, a turn for lines they already had
# (bench 2026-10-28). The file is still written for ak collect --wave.
assert_not_contains "$out" 'summary=' 'the closing count names no summary file to read'
assert_eq yes "$([[ -f $sum1 ]] && echo yes || echo no)" 'the summary file is still written'
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
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq 0 "$rc" '--check exits 0 once the result is there'
assert_eq 'next=ak wait' "$(tail -n 1 <<<"$out")" '--check at exit 0 ends with the command that settles the wave'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" '--check leaves no marker'
# A worker in its final ak receipt reported 130 ms after the root's --check said running, ended 1.5 s later, and the
# root's wait_agent then started after the last wake and slept its full hour (bench 2026-10-29). --check gives a worker
# whose receipt has started a short grace to report before it answers running.
rm -f "$WORK/wt/5/.ak/result"
: >"$WORK/wt/5/.ak/receipt-started"
(sleep 1; green_result >"$WORK/wt/5/.ak/result") &
out=$(AK_WAIT_FINAL_S=10 "$AK" wait --check 2>&1); rc=$?
wait
assert_eq 0 "$rc" '--check waits for a worker whose receipt has started and reports within the grace'
rm -f "$WORK/wt/5/.ak/result"
: >"$WORK/wt/5/.ak/receipt-started"
touch "$subdir/agent-a5.jsonl"
start=$SECONDS
out=$(AK_WAIT_FINAL_S=2 "$AK" wait --check 2>&1); rc=$?
assert_eq 3 "$rc" 'a receipt that outlasts the grace (waiting on CI) is still running'
assert_eq yes "$( ((SECONDS - start < 6)) && echo yes || echo no)" 'and the grace is bounded'
rm -f "$WORK/wt/5/.ak/receipt-started"
touch "$subdir/agent-a5.jsonl"
start=$SECONDS
out=$(AK_WAIT_FINAL_S=10 "$AK" wait --check 2>&1); rc=$?
assert_eq 3 "$rc" 'a worker that has not started its receipt is running'
assert_eq yes "$( ((SECONDS - start < 5)) && echo yes || echo no)" 'and gets no grace'
green_result >"$WORK/wt/5/.ak/result"

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
# Native names are shared by issue and PR workers; older run paths still remain watchable.
sed -i 's#/root/issue_5#/root/pr_5#g' "$sessions/rollout-a.jsonl"
jq '(.items[].kind) = "pr"' "$repo/.ak/runs/r1.json" >"$WORK/pr-run.json"
mv "$WORK/pr-run.json" "$repo/.ak/runs/r1.json"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'pr=5 state=ended-without-result' 'a PR worker is matched by its native name'
jq '(.items[].kind) = "issue"' "$repo/.ak/runs/r1.json" >"$WORK/issue-run.json"
mv "$WORK/issue-run.json" "$repo/.ak/runs/r1.json"
sed -i 's#/root/pr_5#/root/issue-5#g' "$sessions/rollout-a.jsonl"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result' 'a historical hyphenated path still matches'
sed -i 's#/root/issue-5#/root/issue_5_2#g' "$sessions/rollout-a.jsonl"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result' 'a re-spawned worker carries a numbered name and still matches'
sed -i 's#/root/issue_5_2#/root/issue_55#g' "$sessions/rollout-a.jsonl"
out=$("$AK" wait --check 2>&1)
assert_not_contains "$out" 'ended-without-result' 'a longer issue number is not a prefix match'
sed -i 's#/root/issue_55#/root/issue_5#g' "$sessions/rollout-a.jsonl"
# A spawn with no transcript of its own while an older worker holds the name: Codex refuses the second spawn and the
# root's message reaches the finished worker, which answers from its old context and ends. After four polls that
# worker's end is reported, so the root replans at once instead of waiting an hour on a worker nobody started.
# An unchanged transcript from an earlier turn cannot prove that this spawn ran.
sleep 5
SPAWNED_AT=$(date -d '4 seconds ago' +%s) set_run 5
touch "$WORK/wt/5/.ak"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=running' 'an unchanged older transcript never counts as a response to this spawn'
# A genuine resumed response updates that same transcript after the spawn and can explain a failed re-spawn.
touch "$sessions/rollout-a.jsonl"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result note=the earlier worker issue_5 answered this spawn and ended' \
    'a later response from the earlier worker reads as ended, busy worktree or not'

# Same-second mtimes must still respect the prompt's actual ordering.
SPAWNED_AT=$(date +%s) set_run 5
touch "$sessions/rollout-a.jsonl"
touch "$WORK/wt/5/.ak/prompt.md"
out=$(AK_WAIT_POLL_S=0 "$AK" wait --check 2>&1); rc=$?
assert_contains "$out" 'issue=5 state=running' 'an earlier transcript in the prompt second is not a response'
touch "$sessions/rollout-a.jsonl"
out=$(AK_WAIT_POLL_S=0 "$AK" wait --check 2>&1); rc=$?
assert_contains "$out" 'note=the earlier worker issue_5 answered this spawn and ended' 'a transcript updated after the prompt counts even in the same second'
rm -f "$WORK/wt/5/.ak/prompt.md"
SPAWNED_AT=0 set_run 5
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
assert_eq "$reported5"$'\n'"wave=1 settled=1/1" "$(cat "$WORK/w1.out")" 'the watcher prints the summary'
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

# A Claude session may start from a linked worktree or subdirectory whose project slug is not the main checkout slug.
rm -rf "$subdir"
other_subdir="$HOME/.claude/projects/other-session-cwd/sess-1/subagents"
mkdir -p "$other_subdir"
printf '{"type":"user","message":{"content":"worktree %s"}}\n' "$WORK/wt/5" >"$other_subdir/agent-other.jsonl"
printf '{"finished":true}\n' >"$other_subdir/agent-other.meta.json"
SPAWNED_AT=0 set_run 5
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=5 state=ended-without-result' 'a session outside the main checkout project slug still finds its worker transcript'
rm -rf "$other_subdir"

# An item with no worktree is not watchable.
printf '{"run":"r1","open_wave":1,"items":[{"kind":"issue","n":7,"worktree":"","wave":1,"state":"pending","needs":[]},{"kind":"issue","n":8,"worktree":"","wave":1,"state":"queued","needs":[]}]}\n' >"$repo/.ak/runs/r1.json"
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq $'issue=7 state=running\nwave=1 settled=0/1' "$out" 'a pending item without a worktree reads running, a queued one is not watched'
assert_eq 3 "$rc" 'and keeps --check at 3'
touch -d '10 seconds ago' "$repo/.ak/runs/r1.json"
out=$("$AK" wait --check 2>&1)
assert_contains "$out" 'issue=7 state=unwatched note=no worktree recorded' 'past the threshold it is unwatched, naming why'
out=$("$AK" wait --issue 8 --check 2>&1)
assert_contains "$out" 'issue=8 state=queued' 'naming a queued item without a worktree discloses it'

# Named waits resolve IDs to their owning run, including mixed owners, and never omit a queued item.
mkdir -p "$WORK/wt/older/.ak"
green_result >"$WORK/wt/older/.ak/result"
jq -n --arg wt "$WORK/wt/older" '{run:"r0",open_wave:1,items:[{kind:"issue",n:21,worktree:$wt,wave:1,state:"spawned",needs:[]}]}' >"$repo/.ak/runs/r0.json"
set_run 22
green_result >"$WORK/wt/22/.ak/result"
out=$("$AK" wait --issue 21 --issue 21 --issue 22 --check 2>&1)
assert_contains "$out" 'issue=21 state=reported' 'a named issue in an older run is accounted for'
assert_contains "$out" 'issue=22 state=reported' 'a named issue in the current run is accounted for too'
assert_eq 1 "$(grep -c '^issue=21 ' <<<"$out")" 'a duplicate named ID is reported once'
assert_eq 1 "$(grep -o -- '--issue 21' <<<"$out" | wc -l)" 'the next-wait command also deduplicates named IDs'
route 'api repos/acme/widget/pulls/9' '{"number":9,"head":{"sha":"abc"}}'
route 'api repos/acme/widget/commits/abc/check-runs*' '{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}'
real_ln=$(command -v ln)
mkdir -p "$WORK/marker-bin"
cat >"$WORK/marker-bin/ln" <<'SH'
#!/usr/bin/env bash
dest=${*: -1}
if [[ $dest == */wave.open ]]; then
    owner=$(sed -n 's/^run=//p' "$2")
    "$REAL_LN" "$@"
    rc=$?
    printf '%s %s\n' "$owner" "$rc" >>"$MARKER_TRACE"
    if [[ $owner == r1 && $rc == 0 && ! -e $CONCURRENT_STARTED ]]; then
        : >"$CONCURRENT_STARTED"
        (
            "$AK" wait --issue 22 --check --settle >"$CONCURRENT_OUT" 2>&1
            printf '%s\n' "$?" >"$CONCURRENT_RC"
            : >"$CONCURRENT_DONE"
        ) &
    fi
    exit "$rc"
fi
exec "$REAL_LN" "$@"
SH
chmod +x "$WORK/marker-bin/ln"
export REAL_LN="$real_ln" MARKER_TRACE="$WORK/marker-trace"
export CONCURRENT_STARTED="$WORK/concurrent-started" CONCURRENT_OUT="$WORK/concurrent.out"
export CONCURRENT_RC="$WORK/concurrent.rc" CONCURRENT_DONE="$WORK/concurrent.done"
out=$(PATH="$WORK/marker-bin:$PATH" FAKE_GH_DELAY=1 "$AK" wait --issue 21 --issue 22 --check --settle 2>&1); rc=$?
assert_contains "$(cat "$MARKER_TRACE")" $'r0 0\nr1 0' 'each owner acquires the marker after the prior owner releases it'
# shellcheck disable=SC2016 # $1 is the path passed to bash -c below.
timeout 10 bash -c 'while [[ ! -e $1 ]]; do sleep 0.02; done' _ "$CONCURRENT_DONE"
assert_contains "$(cat "$MARKER_TRACE")" 'r1 1' 'a concurrent waiter sees the second owner marker and attaches'
assert_eq yes "$([[ -s $CONCURRENT_OUT && -s $CONCURRENT_RC ]] && echo yes || echo no)" 'the concurrent waiter finishes after the owner releases its marker'
assert_eq 0 "$rc" 'mixed-owner named settlement succeeds'
assert_not_contains "$out" 'next=ak wait' 'a successful settling check does not suggest another wait'
assert_eq yes "$([[ -f $repo/.ak/runs/r0.wave1.summary && -f $repo/.ak/runs/r1.wave1.summary ]] && echo yes || echo no)" \
    'each owner writes its own summary'
assert_contains "$(cat "$repo/.ak/runs/r0.wave1.summary")" 'issue=21 pr=' 'the older owner summary contains only its item'
assert_contains "$(cat "$repo/.ak/runs/r1.wave1.summary")" 'issue=22 pr=' 'the current owner summary contains only its item'
unset REAL_LN MARKER_TRACE CONCURRENT_STARTED CONCURRENT_OUT CONCURRENT_RC CONCURRENT_DONE
rm -rf "$WORK/marker-bin"

# A newer collected attempt outranks an old terminal row whose settlement refreshed the file timestamp.
mkdir -p "$WORK/wt/attempt-old/.ak" "$WORK/wt/attempt-new/.ak"
green_result >"$WORK/wt/attempt-new/.ak/result"
jq -n --arg wt "$WORK/wt/attempt-old" '{run:"attempt-01-old",open_wave:1,items:[{kind:"issue",n:25,worktree:$wt,wave:1,state:"spawned",ended:"ended-without-result",needs:[]}]}' >"$repo/.ak/runs/attempt-01-old.json"
jq -n --arg wt "$WORK/wt/attempt-new" '{run:"attempt-02-new",open_wave:1,items:[{kind:"issue",n:25,worktree:$wt,wave:1,state:"collected",needs:[]}]}' >"$repo/.ak/runs/attempt-02-new.json"
touch "$repo/.ak/runs/attempt-01-old.json"
out=$("$AK" wait --issue 25 --check 2>&1); rc=$?
assert_eq 3 "$rc" 'the newest successful attempt owns the named item and opens its correction round'
assert_contains "$out" 'issue=25 state=running' 'the newer correction round waits for a new result'
assert_eq null "$(jq -r '.items[0].round_at // null' "$repo/.ak/runs/attempt-01-old.json")" 'an older ended attempt is not correction-stamped'
assert_eq yes "$(jq -r '.items[0].round_at // empty' "$repo/.ak/runs/attempt-02-new.json" | grep -Eq '^[0-9]+$' && echo yes || echo no)" \
    'the latest owner receives the correction stamp'

# A newer collected run is authoritative even if an older spawned row has no .ended marker.
mkdir -p "$WORK/wt/attempt-live-old/.ak" "$WORK/wt/attempt-collected-new/.ak"
green_result >"$WORK/wt/attempt-collected-new/.ak/result"
jq -n --arg wt "$WORK/wt/attempt-live-old" '{run:"20261116-110001",harness:"claude",session:"old-session",open_wave:1,items:[{kind:"issue",n:27,worktree:$wt,wave:1,state:"spawned",needs:[]}]}' >"$repo/.ak/runs/20261116-110001.json"
jq -n --arg wt "$WORK/wt/attempt-collected-new" '{run:"20261116-110002",harness:"claude",session:"new-session",open_wave:1,items:[{kind:"issue",n:27,worktree:$wt,wave:1,state:"collected",needs:[]}]}' >"$repo/.ak/runs/20261116-110002.json"
old_owner_subdir="$HOME/.claude/projects/$slug/old-session/subagents"
mkdir -p "$old_owner_subdir"
printf '{"type":"user","message":{"content":"worktree %s"}}\n' "$WORK/wt/attempt-live-old" >"$old_owner_subdir/agent-old.jsonl"
printf '{"finished":true}\n' >"$old_owner_subdir/agent-old.meta.json"
touch "$repo/.ak/runs/20261116-110001.json"
out=$("$AK" wait --issue 27 --check 2>&1); rc=$?
assert_eq 3 "$rc" 'the latest non-queued attempt is authoritative'
assert_contains "$out" 'issue=27 state=running' 'the newer collected attempt opens its correction round'
assert_eq null "$(jq -r '.items[0].round_at // null' "$repo/.ak/runs/20261116-110001.json")" 'the older spawned row without .ended is not stamped'
assert_eq yes "$(jq -r '.items[0].round_at // empty' "$repo/.ak/runs/20261116-110002.json" | grep -Eq '^[0-9]+$' && echo yes || echo no)" \
    'the newest collected owner receives the correction stamp'

# Transcript discovery uses the owning run's provider and root session, even when wait runs in a different harness.
mkdir -p "$WORK/wt/codex-owner/.ak" "$WORK/codex-owner/sessions/2026/10/24"
jq -n --arg wt "$WORK/wt/codex-owner" '{run:"r2",open_wave:1,harness:"codex",session:"saved-root",items:[{kind:"issue",n:24,worktree:$wt,wave:1,state:"spawned",needs:[]}]}' >"$repo/.ak/runs/r2.json"
sed -e 's/01a16bd5-d8ed-7b30-aacc-c6261877bc16/saved-root/g' -e 's#/root/normal#/root/issue_24#g' \
    "$fx/child-normal.jsonl" >"$WORK/codex-owner/sessions/2026/10/24/rollout-owner.jsonl"
export CODEX_HOME="$WORK/codex-owner"
out=$("$AK" wait --issue 24 --check 2>&1); rc=$?
assert_eq 0 "$rc" 'an owner transcript can be read from a saved Codex session under a Claude caller'
assert_contains "$out" 'issue=24 state=ended-without-result' 'the owner session supplies the transcript evidence'
rm -f "$repo/.ak/runs/current"
out=$("$AK" wait --issue 24 --check 2>&1); rc=$?
assert_eq 0 "$rc" 'a named wait can still find its owner when no current pointer exists'
assert_contains "$out" 'issue=24 state=ended-without-result' 'historical owner lookup does not depend on current'
printf 'r1\n' >"$repo/.ak/runs/current"

# A malformed current run must not hide a valid historical owner from a named wait.
printf 'broken current run\n' >"$repo/.ak/runs/broken.json"
printf 'broken\n' >"$repo/.ak/runs/current"
out=$("$AK" wait --issue 24 --check 2>&1); rc=$?
assert_eq 0 "$rc" 'a corrupt current run does not block valid historical owner lookup'
assert_contains "$out" 'issue=24 state=ended-without-result' 'the historical item remains visible'
printf 'r1\n' >"$repo/.ak/runs/current"
unset CODEX_HOME

printf '{"run":"r1","open_wave":1,"items":[{"kind":"issue","n":23,"worktree":"","wave":1,"state":"queued","needs":[]}]}' >"$repo/.ak/runs/r1.json"
out=$("$AK" wait --issue 23 --check 2>&1); rc=$?
assert_eq 1 "$rc" 'a named queued item without a worktree is an explicit non-success'
assert_contains "$out" 'issue=23 state=queued' 'the named queued item is disclosed'

out=$("$AK" wait --issue 999 --check 2>&1); rc=$?
assert_eq 1 "$rc" 'a named item absent from all run records is an explicit non-success'
assert_contains "$out" 'issue=999 state=missing' 'the absent item is disclosed'

# A plain named wait on queued work exits without falsely stamping it ended or writing a summary.
printf '{"run":"r1","open_wave":1,"items":[{"kind":"issue","n":26,"worktree":"","wave":1,"state":"queued","needs":[]}]}' >"$repo/.ak/runs/r1.json"
rm -f "$repo/.ak/runs/r1.wave1.summary"
out=$("$AK" wait --issue 26 2>&1); rc=$?
assert_eq 1 "$rc" 'a plain named wait on queued work is a non-success'
assert_contains "$out" 'issue=26 state=queued' 'the queued state is explicit'
assert_eq queued "$(jq -r '.items[0].state' "$repo/.ak/runs/r1.json")" 'the queued row remains unchanged'
assert_eq no "$([[ -f $repo/.ak/runs/r1.wave1.summary ]] && echo yes || echo no)" 'the queued wait writes no settled summary'

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
assert_eq "$reported5"$'\n'"wave=1 settled=1/1" "$(cat "$WORK/w2.out")" 'with the summary'
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
assert_eq "wave=1 settled=2/2" "$(tail -n 1 "$sum1")" 'the summary file ends with the closing count'
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
assert_contains "$(tail -n 1 "$WORK/c1.out")" 'wave=1 settled=1/1' 'and the closing count'
assert_eq null "$(jq -r '.items[0].round_at' "$repo/.ak/runs/r1.json")" 'the round is closed once the item settles'

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
assert_eq true "$(jq -r '.items[0].round_at > 0' "$repo/.ak/runs/r1.json")" 'the round persists between calls'
printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=fixed\n' >"$WORK/wt/13/.ak/result"
out=$("$AK" wait --check --issue 13 2>&1); rc=$?
assert_eq 0 "$rc" 'a newer result settles --check'
assert_eq $'issue=13 state=reported\nwave=1 settled=1/1\nnext=ak wait --issue 13' "$out" 'with the item reported, and the command that settles it'
"$AK" wait --issue 13 >/dev/null 2>&1; rc=$?
assert_eq 0 "$rc" 'the blocking wait shares the stamp and settles on the same result'
assert_eq null "$(jq -r '.items[0].round_at' "$repo/.ak/runs/r1.json")" 'the round is closed after the settle, so the next round starts fresh'

# A correction that finishes before the first --check still counts: a Codex root checks only after the child's notice,
# so no clock set at the check can predate the new result. The last settle's identities are the baseline.
set_run 14
rm -rf "$subdir"
green_result >"$WORK/wt/14/.ak/result"
"$AK" wait >/dev/null 2>&1
printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=fixed-early\n' >"$WORK/wt/14/.ak/result"
out=$("$AK" wait --check --issue 14 2>&1); rc=$?
assert_eq 0 "$rc" 'a result written before the first --check settles the round'
assert_contains "$out" 'issue=14 state=reported' 'and reads reported'
set_run 15
rm -rf "$subdir"
claude_agent a15 15 true
"$AK" wait >/dev/null 2>&1
touch -d '+5 seconds' "$subdir/agent-a15.jsonl" "$subdir/agent-a15.meta.json"
out=$("$AK" wait --check --issue 15 2>&1); rc=$?
assert_eq 0 "$rc" 'an end record written before the first --check settles the round'
assert_contains "$out" 'issue=15 state=ended-without-result' 'and reads ended'
out=$("$AK" wait --check --issue 15 2>&1)
assert_contains "$out" 'issue=15 state=ended-without-result' 'a second --check reads the same'

# A transcript may receive its final tail write after the previous settle. A correction check must not mistake that
# late write for the resumed worker ending when the worker starts writing during the terminal-state quiescence check.
set_run 17
rm -rf "$subdir"
claude_agent a17 17 true
"$AK" wait >/dev/null 2>&1
printf '{"type":"assistant","message":{"content":"late tail"}}\n' >>"$subdir/agent-a17.jsonl"
touch "$subdir/agent-a17.meta.json"
(sleep 1; printf '{"finished":false}\n' >"$subdir/agent-a17.meta.json"; printf '{"type":"assistant","message":{"content":"resumed"}}\n' >>"$subdir/agent-a17.jsonl") &
resumed=$!
out=$(AK_WAIT_POLL_S=2 "$AK" wait --check --issue 17 2>&1); rc=$?
wait "$resumed"
assert_eq 3 "$rc" 'a late terminal tail does not settle a correction that resumes during the quiescence check'
assert_eq $'issue=17 state=running\nwave=1 settled=0/1' "$out" 'the resumed correction remains running instead of becoming replaceable'
green_result >"$WORK/wt/17/.ak/result"
out=$("$AK" wait --check --issue 17 2>&1); rc=$?
assert_eq 0 "$rc" 'the resumed correction still settles when it reports'
assert_contains "$out" 'issue=17 state=reported' 'and reads the correction result'

# A worker that did not report is recorded terminal in the run, so ak plan may replace it.
set_run 16
rm -rf "$subdir"
claude_agent a16 16 true
"$AK" wait >/dev/null 2>&1
assert_eq ended-without-result "$(jq -r '.items[0].ended' "$repo/.ak/runs/r1.json")" 'an ended worker is recorded in the run item'

# Every in-flight item up to the open wave is watched, not only the newest wave.
printf '{"run":"r1","open_wave":2,"items":[{"kind":"issue","n":5,"worktree":"%s","wave":1,"state":"spawned","needs":[]},{"kind":"issue","n":6,"worktree":"%s","wave":2,"state":"spawned","needs":[]}]}\n' "$WORK/wt/5" "$WORK/wt/6" >"$repo/.ak/runs/r1.json"
rm -rf "$subdir"
mkdir -p "$WORK/wt/6/.ak"
rm -f "$WORK/wt/5/.ak/result" "$WORK/wt/6/.ak/result"
green_result >"$WORK/wt/6/.ak/result"
touch "$WORK/wt/5/.ak"
out=$("$AK" wait --check 2>&1); rc=$?
assert_eq $'issue=5 state=running\nissue=6 state=reported\nwave=2 settled=1/2' "$out" 'a wave-1 worker still out is watched while wave 2 is open'
assert_eq 3 "$rc" 'and keeps --check at 3'

# The marker and the summary belong to the run and session that started the wait.
set_run 5
rm -rf "$subdir"
claude_agent a5 5 false
export AK_WAIT_HANG_S=60
"$AK" wait >"$WORK/w1.out" 2>&1 &
w1=$!
sleep 1
assert_contains "$(cat "$marker")" 'run=r1' 'the marker names the run'
printf '{"run":"r2","open_wave":1,"items":[{"kind":"issue","n":6,"worktree":"%s","wave":1,"state":"spawned","needs":[]}]}\n' "$WORK/wt/6" >"$repo/.ak/runs/r2.json"
printf 'r2\n' >"$repo/.ak/runs/current"
rm -f "$WORK/wt/6/.ak/result"
green_result >"$WORK/wt/6/.ak/result"
out=$(CLAUDE_CODE_SESSION_ID=sess-2 timeout 20 "$AK" wait 2>&1)
assert_contains "$out" 'wave=1 settled=1/1' 'a wait for another run and session settles on its own'
assert_eq "$w1" "$(sed -n 's/^pid=//p' "$marker")" 'and leaves the first watcher marker alone'
assert_eq yes "$([[ -f $repo/.ak/runs/r2.wave1.summary ]] && echo yes || echo no)" 'its summary is under its own run'
green_result >"$WORK/wt/5/.ak/result"
wait "$w1"
assert_eq yes "$([[ -f $repo/.ak/runs/r1.wave1.summary ]] && echo yes || echo no)" 'the first watcher wrote its summary under the run it captured'
assert_contains "$(cat "$repo/.ak/runs/r1.wave1.summary")" 'issue=5 pr=' 'with its own worker'
printf 'r1\n' >"$repo/.ak/runs/current"
export AK_WAIT_HANG_S=3

# A run file that cannot be rewritten stops the wait: the summary never says settled over an unchanged run.
set_run 5
rm -rf "$subdir" "$sum1"
green_result >"$WORK/wt/5/.ak/result"
mkdir -- "$repo/.ak/runs/r1.json.tmp"
out=$("$AK" wait 2>&1); rc=$?
rmdir -- "$repo/.ak/runs/r1.json.tmp"
assert_eq 1 "$([[ $rc -ne 0 ]] && echo 1 || echo 0)" 'a failed run file write exits nonzero'
assert_not_contains "$out" 'settled=1/1' 'and prints no settled summary'
assert_eq no "$([[ -e $sum1 ]] && echo yes || echo no)" 'and writes none'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'and drops the marker'
assert_eq no "$([[ -e $repo/.ak/locks/run ]] && echo yes || echo no)" 'and the run lock'
finish
