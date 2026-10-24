# shellcheck shell=bash
# ak wait [--issue N]... [--check]: block until every worker of the open wave has reported, ended or gone quiet, so the
# root wakes once per wave. Reads result files and transcripts; changes no run state. While it runs it owns the marker
# $MAIN/.ak/wave.open, which a second ak wait reads to attach instead of starting a second watcher.
# shellcheck source=transcript.sh
source "$AK_HOME/lib/transcript.sh"

WAIT_ISSUES=()

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

# item_state KIND N WORKTREE SPAWNED_AT: reported, ended-without-result, hung, unwatched or running, with a note when it helps.
item_state() {
    local kind=$1 n=$2 wt=$3 hang=${AK_WAIT_HANG_S:-1200} transcript
    if [[ -z $wt ]]; then
        # Nothing to look at: running until the run file itself has been quiet for the threshold.
        if (($(date +%s) - $(stat -c %Y -- "$RUNFILE") >= hang)); then
            echo 'unwatched note=no worktree recorded for this item'
        else
            echo running
        fi
        return 0
    fi
    if [[ -f $wt/.ak/result ]]; then echo reported; return 0; fi
    transcript=$(transcript_find "$wt" "$kind-$n" "$(spawn_since "$wt" "${4:-0}")")
    if [[ -n $transcript ]]; then
        case $(transcript_state "$transcript") in
            ended | errored) echo ended-without-result; return 0 ;;
        esac
        if (($(transcript_age "$transcript") >= hang)); then echo hung; else echo running; fi
        return 0
    fi
    if (($(worktree_idle_s "$wt") >= hang)); then
        echo 'unwatched note=no transcript matched; fell back to worktree activity'
    else
        echo running
    fi
}

# watched: "KIND N WORKTREE" per item to watch: the named ones, else the open wave's items still out.
watched() {
    local named
    named=$(printf '%s\n' "${WAIT_ISSUES[@]}" | jq -R 'select(. != "") | tonumber' | jq -sc .)
    jq -r --argjson named "$named" '(.open_wave // 1) as $w | .items[] |
        select((.state | IN("spawned", "pending", "merge-up")) as $out |
               if ($named | length) > 0 then (.n as $n | $named | index($n)) != null and ($out or (.worktree // "") != "")
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

# wait_loop: poll until nothing is running; print once, settled.
wait_loop() {
    local states
    while :; do
        states=$(wave_state)
        ! grep -q 'state=running' <<<"$states" && break
        sleep "${AK_WAIT_POLL_S:-15}"
    done
    report "$states" || true
}

# attach: a watcher is live; wait for its marker to clear. The caller then takes over if workers are still out.
attach() {
    while marker_live; do sleep "${AK_WAIT_POLL_S:-15}"; done
}

cmd_main() {
    local check=0
    while (($#)); do
        case $1 in
            --check) check=1; shift ;;
            --issue) [[ ${2:-} =~ ^[0-9]+$ ]] || usage_die 'usage: ak wait [--issue N]... [--check]'; WAIT_ISSUES+=("$2"); shift 2 ;;
            *) usage_die 'usage: ak wait [--issue N]... [--check]' ;;
        esac
    done
    MAIN=$(main_root)
    MARKER="$MAIN/.ak/wave.open"
    [[ -f $MAIN/.ak/runs/current ]] || die 'no current run' 'ak plan'
    RUNFILE="$MAIN/.ak/runs/$(<"$MAIN/.ak/runs/current").json"
    jq -e . "$RUNFILE" >/dev/null 2>&1 || die "run file unreadable: $RUNFILE" 'ak plan'
    if ((check)); then
        report "$(wave_state)" || exit 3
        return 0
    fi
    mkdir -p -- "$MAIN/.ak"
    until marker_take; do
        if marker_live; then attach; else rm -f -- "$MARKER"; fi
    done
    trap marker_drop EXIT
    trap 'exit 143' TERM INT
    wait_loop
}
