# shellcheck shell=bash disable=SC2016
# ak wait [--issue N | --pr N]... [--check]: block until every worker of the open wave has reported, ended or gone quiet, so the
# root wakes once per wave. Reads result files and transcripts; changes no run state. While it runs it owns the marker
# $MAIN/.ak/wave.open, which a second ak wait reads to attach instead of starting a second watcher.
# shellcheck source=collect.sh
source "$AK_HOME/lib/collect.sh"
# shellcheck source=transcript.sh
source "$AK_HOME/lib/transcript.sh"

WAIT_NAMED=()   # "kind:N" per item named for a correction round
CALL_REF=''     # the item's correction-round stamp (set per item in item_state); only activity newer than it counts

# proc_start PID: an id of the process's start time, so a reused pid does not look like the watcher.
proc_start() {
    local stat fields
    if [[ -r /proc/$1/stat ]]; then
        stat=$(<"/proc/$1/stat")
        stat=${stat##*) }
        read -ra fields <<<"$stat"
        printf '%s\n' "${fields[19]}"
    else
        ps -o lstart= -p "$1" 2>/dev/null | sed 's/^ *//'
    fi
}

marker_get() { sed -n "s/^$1=//p" "$MARKER" 2>/dev/null | head -n 1; }

# marker_live: true when the marker names a running watcher.
marker_live() {
    local pid start
    [[ -f $MARKER ]] || return 1
    pid=$(marker_get pid)
    start=$(marker_get start)
    [[ $pid =~ ^[0-9]+$ && -n $start ]] && kill -0 "$pid" 2>/dev/null && [[ $(proc_start "$pid") == "$start" ]]
}

# marker_take: write the marker, atomically and only when none exists; false when another watcher won.
marker_take() {
    local tmp="$MARKER.$$" session=${CLAUDE_CODE_SESSION_ID:-}
    [[ $(harness) != codex ]] || session=${CODEX_THREAD_ID:-}
    {
        printf 'pid=%s\nstart=%s\nsession=%s\n' "$$" "$(proc_start "$$")" "$session"
        [[ -n $session ]] || printf 'cwd=%s\n' "$PWD"
    } >"$tmp"
    ln -- "$tmp" "$MARKER" 2>/dev/null
    local rc=$?
    rm -f -- "$tmp"
    return "$rc"
}

marker_drop() { [[ $(marker_get pid) != "$$" ]] || rm -f -- "$MARKER"; }

# worktree_idle_s WORKTREE: seconds since the newest sign of life in a worktree (its .ak files, index and HEAD).
worktree_idle_s() {
    local newest=0 file m gitdir
    gitdir=$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null) || gitdir=''
    for file in "$1/.ak" "$1"/.ak/* "$1"/.ak/logs/* "$gitdir/index" "$gitdir/HEAD"; do
        [[ -e $file ]] || continue
        m=$(stat -c %Y -- "$file")
        ((m <= newest)) || newest=$m
    done
    printf '%d\n' $(($(date +%s) - newest))
}

# spawn_since WORKTREE SPAWNED_AT: when the item's current worker was spawned: the later of the run file's spawned_at and
# the worktree's prompt or resolve file (rewritten at every spawn, re-spawn and merge-down).
spawn_since() {
    local since=${2:-0} file m
    for file in "$1/.ak/prompt.md" "$1/.ak/resolve"; do
        [[ -e $file ]] || continue
        m=$(stat -c %Y -- "$file")
        ((m <= since)) || since=$m
    done
    printf '%s\n' "$since"
}

# round_stamp KIND N: the file whose mtime is when this item's correction round was called. It persists across ak wait
# calls (--check and the blocking wait share it) until the item settles.
round_stamp() { printf '%s/.ak/round.%s-%s\n' "$MAIN" "$1" "$2"; }

# fresh PATH: true when a correction round may count PATH: always outside one, else only when written after the call.
fresh() { [[ -z $CALL_REF || $1 -nt $CALL_REF ]]; }

# quiet_s SECONDS: how long a worker has been quiet; a correction round counts from its call at the earliest.
quiet_s() {
    local call
    if [[ -n $CALL_REF ]]; then
        call=$(($(date +%s) - $(stat -c %Y -- "$CALL_REF")))
        (($1 <= call)) || { printf '%d\n' "$call"; return 0; }
    fi
    printf '%d\n' "$1"
}

# item_state KIND N WORKTREE SPAWNED_AT: reported, ended-without-result, hung, unwatched or running, with a note when it helps.
# A correction round resumes the same worker: its result counts when newer than the call, and an end record or hang is
# judged from activity after the call only.
item_state() {
    local kind=$1 n=$2 wt=$3 hang=${AK_WAIT_HANG_S:-1200} transcript
    CALL_REF=$(round_stamp "$kind" "$n")
    [[ -e $CALL_REF ]] || CALL_REF=''
    if [[ -z $wt ]]; then
        # Nothing to look at: running until the run file itself has been quiet for the threshold.
        if (($(quiet_s $(($(date +%s) - $(stat -c %Y -- "$RUNFILE")))) >= hang)); then
            echo 'unwatched note=no worktree recorded for this item'
        else
            echo running
        fi
        return 0
    fi
    if [[ -f $wt/.ak/result ]] && fresh "$wt/.ak/result"; then echo reported; return 0; fi
    transcript=$(transcript_find "$wt" "$kind-$n" "$(spawn_since "$wt" "${4:-0}")")
    if [[ -n $transcript ]]; then
        case $(transcript_state "$transcript") in
            ended | errored)
                if fresh "$transcript" || fresh "${transcript%.jsonl}.meta.json"; then echo ended-without-result; return 0; fi ;;
        esac
        if (($(quiet_s "$(transcript_age "$transcript")") >= hang)); then echo hung; else echo running; fi
        return 0
    fi
    if (($(quiet_s "$(worktree_idle_s "$wt")") >= hang)); then
        echo 'unwatched note=no transcript matched; fell back to worktree activity'
    else
        echo running
    fi
}

# watched: "KIND N WORKTREE" per item to watch: the named ones, else the open wave's items still out.
watched() {
    local named
    named=$(printf '%s\n' "${WAIT_NAMED[@]}" | jq -R 'select(. != "")' | jq -sc .)
    jq -r --argjson named "$named" '(.open_wave // 1) as $w | .items[] |
        select((.state | IN("spawned", "pending", "merge-up")) as $out |
               if ($named | length) > 0 then ((.kind + ":" + (.n | tostring)) as $id | $named | index($id)) != null and ($out or (.worktree // "") != "")
               else (.wave // 1) == $w and $out end) |
        [.kind, .n, .worktree // "", .spawned_at // 0] | map(tostring) | join("\u001f")' "$RUNFILE"
}

# wave_state: one line per watched item.
wave_state() {
    local kind n wt at
    while IFS=$'\037' read -r kind n wt at; do
        printf '%s=%s state=%s\n' "$kind" "$n" "$(item_state "$kind" "$n" "$wt" "$at")"
    done < <(watched)
}

# report STATES: print the lines and the closing count; return 0 when none is still running.
report() {
    local total settled
    total=0 settled=0
    if [[ -n $1 ]]; then
        total=$(grep -c . <<<"$1" || true)
        settled=$(grep -vc 'state=running' <<<"$1" || true)
    fi
    [[ -z $1 ]] || printf '%s\n' "$1"
    printf 'wave=%s settled=%s/%s\n' "$(jq -r '.open_wave // 1' "$RUNFILE")" "$settled" "$total"
    ((settled == total))
}

# wave_number: the open wave.
wave_number() { jq -r '.open_wave // 1' "$RUNFILE"; }

# next_step KIND N STATE: the command that recovers a worker that did not report.
next_step() {
    local plan="ak plan --issue $2" stop=''
    [[ $1 == issue ]] || plan="ak pr-plan --pr $2"
    if [[ $3 == hung ]]; then
        stop='stop its worker (Claude TaskStop, Codex interrupt_agent), then '
    fi
    printf '%s%s\n' "$stop" "$plan"
}

# settle_line LINE: the summary lines of one watched item. A reported worker is collected here, inside the wait, so the
# CI wait happens in the silence and the root's one wake already carries the final state.
settle_line() {
    local id=${1%% *} kind n state=${1#* state=}
    kind=${id%%=*} n=${id#*=}
    rm -f -- "$(round_stamp "$kind" "$n")"
    if [[ ${state%% *} != reported ]]; then
        printf '%s next=%s\n' "$1" "$(next_step "$kind" "$n" "${state%% *}")"
        return 0
    fi
    LINES=()
    run_lock wait
    collect_one "$kind" "$n"
    run_unlock
    if ((${#LINES[@]})); then printf '%s\n' "${LINES[@]}"; else printf '%s\n' "$1"; fi
}

# settle STATES: print the summary of a settled wave and write it beside the run file. The marker goes only afterwards.
settle() {
    local line out='' total=0 w file
    w=$(wave_number)
    file="$MAIN/.ak/runs/$(<"$MAIN/.ak/runs/current").wave$w.summary"
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        total=$((total + 1))
        out+=$(settle_line "$line")$'\n'
    done <<<"$1"
    out+="wave=$w settled=$total/$total summary=$file"
    printf '%s\n' "$out" >"$file"
    printf '%s\n' "$out"
}

# wait_loop: poll until nothing is running; settle once. With nothing out and a summary already written for the wave
# (another watcher settled it while this one attached), print that summary instead.
wait_loop() {
    local states file
    while :; do
        states=$(wave_state)
        ! grep -q 'state=running' <<<"$states" && break
        sleep "${AK_WAIT_POLL_S:-15}"
    done
    file="$MAIN/.ak/runs/$(<"$MAIN/.ak/runs/current").wave$(wave_number).summary"
    if [[ -z $states && ${#WAIT_NAMED[@]} -eq 0 && -f $file ]]; then cat -- "$file"; return 0; fi
    settle "$states"
}

# attach: a watcher is live; wait for its marker to clear. The caller then takes over if workers are still out.
attach() {
    while marker_live; do sleep "${AK_WAIT_POLL_S:-15}"; done
}

# open_corrections: a correction round adds each named item without an open round to the open wave (so the hook marker and
# collect --wave see it) and stamps the call time. An item already out with a stamp is in a round: the stamp is reused.
open_corrections() {
    local id kind n state fresh_ids=()
    for id in "${WAIT_NAMED[@]}"; do
        kind=${id%%:*} n=${id#*:}
        state=$(jq -r --arg k "$kind" --argjson n "$n" '[.items[] | select(.kind == $k and .n == $n and (.worktree // "") != "")][0].state // "none"' "$RUNFILE")
        [[ $state != none ]] || continue
        if [[ $state =~ ^(spawned|pending|merge-up)$ && -e $(round_stamp "$kind" "$n") ]]; then continue; fi
        : >"$(round_stamp "$kind" "$n")"
        fresh_ids+=("$id")
    done
    ((${#fresh_ids[@]})) || return 0
    run_lock wait
    run_update '(.open_wave // 1) as $w | (.items[] | select(((.kind + ":" + (.n | tostring)) as $id | $named | index($id)) != null and (.worktree // "") != "")) |=
        (.wave = $w | .state = "spawned")' --argjson named "$(printf '%s\n' "${fresh_ids[@]}" | jq -R . | jq -sc .)"
    run_unlock
}

cmd_main() {
    local check=0 usage='usage: ak wait [--issue N | --pr N]... [--check]'
    while (($#)); do
        case $1 in
            --check) check=1; shift ;;
            --issue | --pr) [[ ${2:-} =~ ^[0-9]+$ ]] || usage_die "$usage"; WAIT_NAMED+=("${1#--}:$2"); shift 2 ;;
            *) usage_die "$usage" ;;
        esac
    done
    MAIN=$(main_root)
    MARKER="$MAIN/.ak/wave.open"
    [[ -f $MAIN/.ak/runs/current ]] || die 'no current run' 'ak plan'
    RUNFILE="$MAIN/.ak/runs/$(<"$MAIN/.ak/runs/current").json"
    jq -e . "$RUNFILE" >/dev/null 2>&1 || die "run file unreadable: $RUNFILE" 'ak plan'
    if ((check)); then
        open_corrections
        report "$(wave_state)" || exit 3
        return 0
    fi
    plan_context wait
    open_corrections
    until marker_take; do
        if marker_live; then attach; else rm -f -- "$MARKER"; fi
    done
    trap marker_drop EXIT
    trap 'exit 143' TERM INT
    wait_loop
}
