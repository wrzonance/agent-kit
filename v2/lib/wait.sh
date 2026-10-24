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
    for file in "$1"/.ak/* "$1"/.ak/logs/* "$gitdir/index" "$gitdir/HEAD"; do
        [[ -e $file ]] || continue
        m=$(stat -c %Y -- "$file")
        ((m <= newest)) || newest=$m
    done
    printf '%d\n' $(($(date +%s) - newest))
}

# item_state KIND N WORKTREE: reported, ended-without-result, hung, unwatched or running, with a note when it helps.
item_state() {
    local kind=$1 n=$2 wt=$3 hang=${AK_WAIT_HANG_S:-1200} transcript
    if [[ -f $wt/.ak/result ]]; then echo reported; return 0; fi
    transcript=$(transcript_find "$wt" "$kind-$n")
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
        select(if ($named | length) > 0 then (.n as $n | $named | index($n)) != null
               else (.wave // 1) == $w and (.state | IN("spawned", "pending", "merge-up")) end) |
        [.kind, .n, .worktree // ""] | @tsv' "$RUNFILE"
}

# wave_state: one line per watched item.
wave_state() {
    local kind n wt
    while IFS=$'\t' read -r kind n wt; do
        printf '%s=%s state=%s\n' "$kind" "$n" "$(item_state "$kind" "$n" "$wt")"
    done < <(watched)
}

# report STATES: print the lines and the closing count; return 0 when none is still running.
report() {
    local total settled
    total=$(grep -c . <<<"$1" || true)
    settled=$(grep -vc 'state=running' <<<"$1" || true)
    [[ -z $1 ]] || printf '%s\n' "$1"
    printf 'wave=%s settled=%s/%s\n' "$(jq -r '.open_wave // 1' "$RUNFILE")" "$settled" "$total"
    ((settled == total))
}

# wait_loop: poll until nothing is running (or, attached, until the marker clears); print once, settled.
wait_loop() {
    local states poll=${AK_WAIT_POLL_S:-15}
    while :; do
        states=$(wave_state)
        if [[ $1 == own ]]; then
            ! grep -q 'state=running' <<<"$states" && break
        else
            marker_live || break
        fi
        sleep "$poll"
    done
    [[ $1 == own ]] || states=$(wave_state)
    report "$states" || true
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
        if marker_live; then wait_loop attach; return 0; fi
        rm -f -- "$MARKER"
    done
    trap marker_drop EXIT
    trap 'exit 143' TERM INT
    wait_loop own
}
