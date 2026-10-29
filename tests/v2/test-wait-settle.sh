#!/usr/bin/env bash
# One readiness call returns the collected summary, without releasing the next wave.
TEST_NAME=v2-wait-settle
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1
export HOME="$WORK/home" CLAUDE_CODE_SESSION_ID=settle-test AK_WAIT_HANG_S=60 AK_WAIT_POLL_S=1
mkdir -p "$HOME" "$repo/.ak/runs" "$WORK/a/.ak" "$WORK/b/.ak"
runfile="$repo/.ak/runs/r.json"
summary="$repo/.ak/runs/r.wave1.summary"
marker="$repo/.ak/wave.open"
reset_run() {
    rm -f "$WORK/a/.ak/result" "$WORK/b/.ak/result" "$summary"
    jq -n --arg a "$WORK/a" --arg b "$WORK/b" '{run:"r",open_wave:1,items:[
        {kind:"issue",n:1,worktree:$a,wave:1,state:"spawned",needs:[]},
        {kind:"issue",n:2,worktree:$b,wave:1,state:"spawned",needs:[]},
        {kind:"issue",n:3,worktree:"",wave:2,state:"queued",needs:[1]}]}' >"$runfile"
    printf 'r\n' >"$repo/.ak/runs/current"
}
result() { printf 'pr=https://github.com/acme/widget/pull/%s\nci=green\nreview=done\nhead=abc\nnote=%s\n' "$1" "$2"; }

reset_run
result 11 first >"$WORK/a/.ak/result"
out=$("$AK" wait --check --settle 2>&1); rc=$?
assert_eq 3 "$rc" 'one active worker returns pending immediately'
assert_eq $'issue=1 state=reported\nissue=2 state=running\nwave=1 settled=1/2' "$out" 'pending output identifies both workers'
assert_eq 'spawned spawned queued' "$(jq -r '[.items[].state]|join(" ")' "$runfile")" 'a pending check collects nothing'
assert_eq no "$([[ -e $marker || -e $summary ]] && echo yes || echo no)" 'pending leaves no marker or summary'
result 12 second >"$WORK/b/.ak/result"
out=$("$AK" wait --check --settle 2>&1); rc=$?
assert_eq 0 "$rc" 'ready workers settle in this call'
assert_contains "$out" 'issue=1 pr=https://github.com/acme/widget/pull/11 ci=green review=done note=first' 'the call returns the first collected result'
assert_contains "$out" 'issue=2 pr=https://github.com/acme/widget/pull/12 ci=green review=done note=second' 'the call returns the second collected result'
assert_not_contains "$out" 'next=ak wait' 'no second wait call is needed'
assert_eq "wave=1 settled=2/2" "$(tail -n 1 <<<"$out")" 'the returned summary closes the wave'
assert_eq "$out" "$(cat "$summary" 2>/dev/null)" 'the same summary is persisted'
assert_eq 'collected collected queued' "$(jq -r '[.items[].state]|join(" ")' "$runfile")" 'collection leaves the next wave queued'
assert_eq 1 "$(jq -r .open_wave "$runfile")" 'the root still decides whether to advance'
assert_eq "$out" "$("$AK" wait --check --settle 2>&1)" 'a repeated unnamed call replays the settled summary'
assert_eq no "$([[ -e $marker || -e $repo/.ak/locks/run ]] && echo yes || echo no)" 'settlement clears its marker and lock'

# Named corrections compare against the previous settle, not the time of this call.
out=$("$AK" wait --check --settle --issue 1 2>&1); rc=$?
assert_eq 3 "$rc" 'an old result cannot settle a correction'
result 11 corrected >"$WORK/a/.ak/result"
out=$("$AK" wait --check --settle --issue 1 2>&1); rc=$?
assert_eq 0 "$rc" 'a new correction result settles without another command'
assert_contains "$out" 'note=corrected' 'the correction summary carries the new result'
assert_eq null "$(jq -r '.items[0].round_at' "$runfile")" 'settlement closes the correction stamp'

# A live watcher of this run that is settling (no worker running) is attached to, and its summary is returned: a
# Codex root whose stray `ak wait` was mid-settle got exit 3 "state=settling", ended its turn with no child left to
# wake it, and the trial ran to its cap (bench 2026-10-27, trial 20261027T154157Z).
reset_run
result 11 first >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
proc_start() {
    if [[ -r /proc/$1/stat ]]; then
        local line fields
        line=$(<"/proc/$1/stat")
        read -ra fields <<<"${line##*) }"
        printf '%s\n' "${fields[19]}"
    else
        ps -o lstart= -p "$1" | sed 's/^ *//'
    fi
}
# The holder: owns the marker for two seconds, then publishes the summary and drops the marker, like settle does.
holder_gate="$WORK/settle-holder-ready"
(
    while [[ ! -e $holder_gate ]]; do sleep 0.01; done
    sleep 2
    printf '%s\n' \
        'issue=1 pr=https://github.com/acme/widget/pull/11 ci=green review=done note=first' \
        "wave=1 settled=2/2 summary=$summary" >"$summary"
    rm -f "$marker"
) &
holder=$!
printf 'pid=%s\nstart=%s\nsession=settle-test\nrun=r\n' "$holder" "$(proc_start "$holder")" >"$marker"
: >"$holder_gate"
out=$(timeout 10 "$AK" wait --check --settle 2>&1); rc=$?
wait "$holder"
assert_eq 0 "$rc" 'a readiness call attaches to a watcher that is settling and returns its summary'
assert_contains "$out" 'issue=1 pr=https://github.com/acme/widget/pull/11 ci=green review=done note=first' 'the holder summary carries its collected result'
assert_contains "$out" 'wave=1 settled=2/2' 'the summary the holder published is returned'
assert_not_contains "$out" 'state=settling' 'no pending line is printed once the holder has settled'
assert_eq no "$([[ -e $marker ]] && echo yes || echo no)" 'the holder dropped its marker and the caller wrote none'
# A live watcher while a worker is still out is not attached to: pending is returned without blocking.
reset_run
result 11 first >"$WORK/a/.ak/result"
printf 'pid=%s\nstart=%s\nsession=settle-test\nrun=r\n' "$$" "$(proc_start $$)" >"$marker"
out=$(timeout 5 "$AK" wait --check --settle 2>&1); rc=$?
assert_eq 3 "$rc" 'a live watcher with a worker still running returns pending without attaching'
assert_contains "$out" 'issue=2 state=running' 'the pending line names the running worker'
assert_eq "$$" "$(sed -n 's/^pid=//p' "$marker")" 'the live watcher marker stays intact'
rm -f "$marker"
# If a worker resumes after the readiness probe while a same-session watcher owns the marker, attachment rechecks it.
reset_run
result 11 first >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
printf 'pid=%s\nstart=%s\nsession=settle-test\nrun=r\n' "$$" "$(proc_start $$)" >"$marker"
mkdir -p "$WORK/attach-bin"
export REAL_LN REVIVE_RESULT="$WORK/b/.ak/result"
REAL_LN=$(command -v ln)
cat >"$WORK/attach-bin/ln" <<'SH'
#!/usr/bin/env bash
"$REAL_LN" "$@"
rc=$?
if [[ ${*: -1} == */wave.open ]]; then rm -f "$REVIVE_RESULT"; fi
exit "$rc"
SH
chmod +x "$WORK/attach-bin/ln"
out=$(PATH="$WORK/attach-bin:$PATH" timeout 5 "$AK" wait --check --settle 2>&1); rc=$?
assert_eq 3 "$rc" 'attachment returns pending when a worker resumes while another watcher holds the marker'
assert_contains "$out" 'issue=2 state=running' 'attachment reports the worker that resumed'
assert_eq "$$" "$(sed -n 's/^pid=//p' "$marker")" 'attachment leaves the other watcher marker intact'
rm -f "$marker"
unset REAL_LN REVIVE_RESULT
reset_run
result 11 first >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
printf 'pid=%s\nstart=%s\nsession=other-session\nrun=r\n' "$$" "$(proc_start $$)" >"$marker"
out=$("$AK" wait --check --settle 2>&1); rc=$?
assert_eq 0 "$rc" 'another session marker does not block this settlement'
assert_eq "$$" "$(sed -n 's/^pid=//p' "$marker")" 'another session marker is not removed'
rm -f "$marker"

# Settlement also resolves the CI status, rather than returning the stale receipt.
reset_run
route 'api repos/acme/widget/pulls/11' '{"number":11,"head":{"sha":"abc"}}'
route 'api repos/acme/widget/commits/abc/check-runs*' '{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}'
result 11 first | sed 's/ci=green/ci=pending/' >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
out=$("$AK" wait --check --settle 2>&1); rc=$?
assert_eq 0 "$rc" 'reported workers with pending receipts settle through CI'
assert_contains "$out" 'issue=1 pr=https://github.com/acme/widget/pull/11 ci=green' 'the same call includes the live green CI result'
assert_contains "$(cat "$FAKE_GH_LOG")" 'commits/abc/check-runs' 'settlement actually reads CI'

# Simulate a worker resuming between the readiness probe and acquisition of the marker.
# Delegate the real link operation, then remove its result at that process boundary.
reset_run
result 11 first >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
mkdir "$WORK/bin"
export REAL_LN REVIVE_RESULT="$WORK/b/.ak/result"
REAL_LN=$(command -v ln)
cat >"$WORK/bin/ln" <<'SH'
#!/usr/bin/env bash
"$REAL_LN" "$@" || exit $?
if [[ ${*: -1} == */wave.open ]]; then rm -f "$REVIVE_RESULT"; fi
SH
chmod +x "$WORK/bin/ln"
out=$(PATH="$WORK/bin:$PATH" timeout 5 "$AK" wait --check --settle 2>&1); rc=$?
assert_eq 3 "$rc" 'a worker that resumes during marker acquisition returns pending instead of blocking'
assert_contains "$out" 'issue=2 state=running' 'the resumed worker is rechecked before settling'
assert_eq 'spawned spawned queued' "$(jq -r '[.items[].state]|join(" ")' "$runfile")" 'the raced check collects neither worker'
assert_eq no "$([[ -e $marker || -e $summary ]] && echo yes || echo no)" 'the raced check drops its marker and publishes no summary'

# A failed state write must not claim success or leave locks behind.
reset_run
result 11 first >"$WORK/a/.ak/result"
result 12 second >"$WORK/b/.ak/result"
mkdir "$runfile.tmp"
out=$("$AK" wait --check --settle 2>&1); rc=$?
rmdir "$runfile.tmp"
assert_eq 1 "$rc" 'failed collection is an error'
assert_not_contains "$out" 'settled=2/2' 'a write failure prints no successful summary'
assert_eq no "$([[ -e $marker || -e $repo/.ak/locks/run || -e $summary ]] && echo yes || echo no)" 'failure cleans up without publishing a summary'

out=$("$AK" wait --settle 2>&1); rc=$?
assert_eq 2 "$rc" '--settle requires --check'
assert_contains "$("$AK" wait --help)" 'wait [--issue N | --pr N]... [--check [--settle]]' 'help exposes the combined readiness and settlement mode'
finish
