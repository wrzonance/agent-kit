# shellcheck shell=bash disable=SC2016
# ak wait [--issue N | --pr N]... [--check [--settle]]: wait for the open wave and collect its results.
# --check returns readiness; --check --settle also collects a ready wave in that call. While settling it owns the marker
# $MAIN/.ak/wave.open, which a second ak wait reads to attach instead of starting a second watcher.
# shellcheck source=collect.sh
source "$AK_HOME/lib/collect.sh"
# shellcheck source=transcript.sh
source "$AK_HOME/lib/transcript.sh"

WAIT_NAMED=()   # "kind:N" per item named for a correction round
ROUND_AT=0      # when the item's correction round was called (set per item in item_state); 0 outside a round
SEEN_RES=''     # the identity of the item's result, and of its transcript, at its last settle: a round counts only what differs
SEEN_TR=''
WAIT_CHECK=0    # --check: answer at once, with a short grace for a worker already in its receipt
WAIT_SETTLE=0   # --check --settle: collect ready named owners in this call
RUN_ID=''       # the run this ak wait captured at start; its marker and summary belong to it
SUMMARY=''      # the settled wave's lines, built by settle_line
OWNER_HARNESS='' # provider recorded by the run currently being watched
OWNER_SESSION='' # root session recorded by the run currently being watched

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
    local tmp="$MARKER.$$" session
    session=$(my_session)
    {
        printf 'pid=%s\nstart=%s\nsession=%s\nrun=%s\n' "$$" "$(proc_start "$$")" "$session" "$RUN_ID"
        [[ -n $session ]] || printf 'cwd=%s\n' "$PWD"
    } >"$tmp"
    ln -- "$tmp" "$MARKER" 2>/dev/null
    local rc=$?
    rm -f -- "$tmp"
    return "$rc"
}

# my_session: the harness session id this ak wait runs under.
my_session() {
    if [[ $OWNER_HARNESS == codex || $OWNER_HARNESS == claude ]]; then printf '%s\n' "$OWNER_SESSION"
    elif [[ $(harness) == codex ]]; then printf '%s\n' "${CODEX_THREAD_ID:-}"
    else printf '%s\n' "${CLAUDE_CODE_SESSION_ID:-}"; fi
}

# owner_context: use the harness and root session saved with the run, not whichever harness invokes wait today.
owner_context() {
    OWNER_HARNESS=$(jq -r '.harness // empty' "$RUNFILE")
    OWNER_SESSION=$(jq -r '.session // empty' "$RUNFILE")
    [[ -n $OWNER_HARNESS ]] || OWNER_HARNESS=$(harness)
    if [[ -z $OWNER_SESSION ]]; then
        if [[ $OWNER_HARNESS == codex ]]; then OWNER_SESSION=${CODEX_THREAD_ID:-}
        elif [[ $OWNER_HARNESS == claude ]]; then OWNER_SESSION=${CLAUDE_CODE_SESSION_ID:-}; fi
    fi
}

# marker_mine: the live marker was written by a watcher of this run and session (or, with no session, this cwd).
marker_mine() {
    local session
    session=$(my_session)
    [[ $(marker_get run) == "$RUN_ID" && $(marker_get session) == "$session" ]] &&
        { [[ -n $session ]] || [[ $(marker_get cwd) == "$PWD" ]]; }
}

marker_drop() { [[ $(marker_get pid) != "$$" ]] || rm -f -- "$MARKER"; }

# spawn_since WORKTREE SPAWNED_AT: when the item's current worker was spawned: the later of the run file's spawned_at and
# the worktree's prompt or resolve file (rewritten at every spawn, re-spawn and merge-down).
spawn_since() {
    local since=${2:-0} file m
    for file in "$1/.ak/prompt.md" "$1/.ak/resolve"; do
        [[ -e $file ]] || continue
        m=$(file_mtime "$file")
        ((m <= since)) || since=$m
    done
    printf '%s\n' "$since"
}

# ident_result WORKTREE: the identity of the worker's result file: its content and its time. Empty without one.
ident_result() {
    local file=$1/.ak/result
    if [[ -f $file ]]; then printf '%s:%s\n' "$(cksum <"$file" | cut -d' ' -f1)" "$(file_mtime "$file")"; fi
}

# ident_transcript PATH: the identity of a transcript and its meta file, which change whenever the worker works again.
ident_transcript() {
    local meta=${1%.jsonl}.meta.json m=0
    [[ ! -e $meta ]] || m=$(file_mtime "$meta")
    printf '%s:%s:%s\n' "$1" "$(file_mtime "$1")" "$m"
}

# item_idents KIND N WORKTREE SPAWNED_AT: "RESULT-IDENT US TRANSCRIPT-IDENT", where US is the unit separator.
item_idents() {
    local transcript='' tr_id=''
    if [[ -n $3 ]]; then
        transcript=$(transcript_find "$3" "${1}_$2" "$(spawn_since "$3" "${4:-0}")" "$OWNER_HARNESS" "$OWNER_SESSION")
        [[ -z $transcript ]] || tr_id=$(ident_transcript "$transcript")
        printf '%s\037%s\n' "$(ident_result "$3")" "$tr_id"
    else
        printf '\037\n'
    fi
}

# transcript_responded_after WORKTREE PATH SINCE: prove the transcript moved past this spawn's prompt/resolve marker.
# Without a marker, require a strictly newer whole-second mtime; equality is ambiguous and stays running.
transcript_responded_after() {
    local wt=$1 transcript=$2 since=$3 file boundary=''
    for file in "$wt/.ak/prompt.md" "$wt/.ak/resolve"; do
        [[ -e $file ]] || continue
        if [[ -z $boundary || $file -nt $boundary ]]; then boundary=$file; fi
    done
    if [[ -n $boundary ]]; then [[ $transcript -nt $boundary ]]
    else (( $(file_mtime "$transcript") > since )); fi
}

# fresh IDENT SEEN: true when a correction round may count what IDENT names: always outside a round, else only when it
# differs from what the last settle saw. The comparison needs no clock, so a correction that finishes before the first
# --check (a Codex root checks only after the child's notice) still counts.
fresh() { ((ROUND_AT == 0)) || [[ $1 != "$2" ]]; }

# quiet_s SECONDS: how long a worker has been quiet; a correction round counts from its call at the earliest.
quiet_s() {
    local call
    if ((ROUND_AT > 0)); then
        call=$(($(date +%s) - ROUND_AT))
        (($1 <= call)) || { printf '%d\n' "$call"; return 0; }
    fi
    printf '%d\n' "$1"
}

# item_meta KIND N: the round and the last-settle identities of the item, into ROUND_AT, SEEN_RES and SEEN_TR.
item_meta() {
    local row
    row=$(jq -r --arg k "$1" --argjson n "$2" '[.items[] | select(.kind == $k and .n == $n)][0] |
        [(.round_at // 0), (.seen.result // ""), (.seen.transcript // "")] | map(tostring) | join("\u001f")' "$RUNFILE")
    IFS=$'\037' read -r ROUND_AT SEEN_RES SEEN_TR <<<"$row"
}

# item_state KIND N WORKTREE SPAWNED_AT: reported, ended-without-result, hung, unwatched or running, with a note when it helps.
# A correction round resumes the same worker: its result counts when it differs from the one the last settle saw, and an
# end record likewise; a hang is judged from the call at the earliest.
# final_grace WORKTREE SINCE: in --check, a worker whose ak receipt started after its spawn gets AK_WAIT_FINAL_S
# (default 30) to report. One reported 130 ms after a --check said running and ended before the root's wait_agent
# began, which then slept its full hour (bench 2026-10-29). A receipt still waiting on CI outlasts the grace.
final_grace() {
    local marker=$1/.ak/receipt-started deadline
    ((WAIT_CHECK)) && [[ -f $marker && ! -L $marker ]] || return 1
    (($(file_mtime "$marker") >= $2)) || return 1
    deadline=$((SECONDS + ${AK_WAIT_FINAL_S:-30}))
    while ((SECONDS < deadline)); do
        [[ -f $1/.ak/result ]] && fresh "$(ident_result "$1")" "$SEEN_RES" && return 0
        sleep 1
    done
    return 1
}

item_state() {
    local kind=$1 n=$2 wt=$3 hang=${AK_WAIT_HANG_S:-1200} transcript terminal_id terminal_state taken='' since item_status
    item_meta "$kind" "$n"
    if [[ -z $wt ]]; then
        item_status=$(jq -r --arg k "$kind" --argjson n "$n" '[.items[] | select(.kind == $k and .n == $n)][0].state // ""' "$RUNFILE")
        if [[ $item_status == queued ]]; then echo 'queued note=item is queued without a worktree'; return 0; fi
        # Nothing to look at: running until the run file itself has been quiet for the threshold.
        if (($(quiet_s $(($(date +%s) - $(file_mtime "$RUNFILE")))) >= hang)); then
            echo 'unwatched note=no worktree recorded for this item'
        else
            echo running
        fi
        return 0
    fi
    if [[ -f $wt/.ak/result ]] && fresh "$(ident_result "$wt")" "$SEEN_RES"; then echo reported; return 0; fi
    since=$(spawn_since "$wt" "${4:-0}")
    transcript=$(transcript_find "$wt" "${kind}_$n" "$since" "$OWNER_HARNESS" "$OWNER_SESSION")
    if [[ -z $transcript && $OWNER_HARNESS == codex ]] && (($(date +%s) - since >= 4 * ${AK_WAIT_POLL_S:-15})); then
        # No worker of this spawn after four polls: Codex keeps a finished worker's name, so the spawn under it failed
        # and the root's message reached the old worker, which answers from its context and ends. Its end is this
        # item's end, so the root replans now instead of waiting on a worker nobody started.
        transcript=$(transcript_find "$wt" "${kind}_$n" 0 "$OWNER_HARNESS" "$OWNER_SESSION")
        if [[ -n $transcript ]] && transcript_responded_after "$wt" "$transcript" "$since"; then
            taken=" note=the earlier worker ${kind}_$n answered this spawn and ended"
        else
            transcript=''
        fi
    fi
    if [[ -n $transcript ]]; then
        terminal_state=$(transcript_state "$transcript")
        case $terminal_state in
            ended | errored)
                terminal_id=$(ident_transcript "$transcript")
                if fresh "$terminal_id" "$SEEN_TR"; then
                    # A worker can finish its previous turn after settle but before it picks up a correction. Confirm a
                    # correction's terminal identity stays quiet for one poll so that tail cannot spawn a duplicate.
                    if ((ROUND_AT > 0)); then
                        sleep "${AK_WAIT_POLL_S:-15}"
                        if [[ -f $wt/.ak/result ]] && fresh "$(ident_result "$wt")" "$SEEN_RES"; then echo reported; return 0; fi
                        terminal_state=$(transcript_state "$transcript")
                        [[ $terminal_state =~ ^(ended|errored)$ && $(ident_transcript "$transcript") == "$terminal_id" ]] || { echo running; return 0; }
                    fi
                    echo "ended-without-result$taken"
                    return 0
                fi ;;
        esac
        if (($(quiet_s "$(transcript_age "$transcript")") >= hang)); then echo hung; return 0; fi
        if final_grace "$wt" "$since"; then echo reported; else echo running; fi
        return 0
    fi
    if (($(quiet_s "$(worktree_idle_s "$wt")") >= hang)); then
        echo 'unwatched note=no transcript matched; fell back to worktree activity'
    else
        echo running
    fi
}

# watched: "KIND N WORKTREE" per item to watch: the named ones, else every item still out in the open wave or an
# earlier one (a release can pass a wave whose blocker shipped while another of its workers is live).
watched() {
    local named
    named=$(printf '%s\n' "${WAIT_NAMED[@]}" | jq -R 'select(. != "")' | jq -sc .)
    jq -r --argjson named "$named" '(.open_wave // 1) as $w | .items[] |
        select((.state | IN("spawned", "pending", "merge-up")) as $out |
               if ($named | length) > 0 then ((.kind + ":" + (.n | tostring)) as $id | $named | index($id)) != null
               else (.wave // 1) <= $w and $out end) |
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

# find_owner KIND N: newest timestamp-ordered non-queued attempt, falling back to the newest queued record.
# Run IDs are saved in timestamp order; settlement can refresh a JSON file's mtime without changing its attempt order.
find_owner() {
    local kind=$1 n=$2 file row state fallback=''
    local -a files=()
    mapfile -t files < <(find "$MAIN/.ak/runs" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null | LC_ALL=C sort -r)
    for file in "${files[@]}"; do
        row=$(jq -r --arg k "$kind" --argjson n "$n" '[.items[] | select(.kind == $k and .n == $n)][-1].state // empty' \
            "$file" 2>/dev/null) || continue
        [[ -n $row ]] || continue
        [[ -n $fallback ]] || fallback=$(basename -- "$file" .json)
        state=$row
        if [[ $state != queued ]]; then
            basename -- "$file" .json
            return 0
        fi
    done
    [[ -n $fallback ]] || return 1
    printf '%s\n' "$fallback"
}

# load_owner RUN: switch all run-scoped reads and writes to one named item's owner.
load_owner() {
    RUN_ID=$1
    RUNFILE="$MAIN/.ak/runs/$RUN_ID.json"
    jq -e . "$RUNFILE" >/dev/null 2>&1 || die "run file unreadable: $RUNFILE" 'ak plan'
    owner_context
}

# next_step KIND N STATE: the command that recovers a worker that did not report.
next_step() {
    local plan="ak plan --issue $2" stop=''
    [[ $1 == issue ]] || plan="ak pr-plan --pr $2"
    if [[ $3 == hung ]]; then
        stop='stop its worker (Claude TaskStop, Codex interrupt_agent), then '
    fi
    printf '%s%s\n' "$stop" "$plan"
}

# item_settled KIND N ENDED: record what this settle saw: the identities a later correction round compares against, and,
# for a worker that did not report, its terminal state, so ak plan may replace it. Closes the item's round.
item_settled() {
    local row wt at idents
    row=$(jq -r --arg k "$1" --argjson n "$2" '[.items[] | select(.kind == $k and .n == $n)][0] |
        [(.worktree // ""), (.spawned_at // 0)] | map(tostring) | join("\u001f")' "$RUNFILE")
    IFS=$'\037' read -r wt at <<<"$row"
    idents=$(item_idents "$1" "$2" "$wt" "$at")
    run_update '(.items[] | select(.kind == $k and .n == $n)) |= (.seen = {result: $r, transcript: $t} | .round_at = null |
        if $e == "" then del(.ended) else .ended = $e end)' --arg k "$1" --argjson n "$2" --arg e "$3" \
        --arg r "${idents%%$'\037'*}" --arg t "${idents#*$'\037'}"
}

# settle_line LINE: add the summary lines of one watched item to SUMMARY. A reported worker is collected here, inside the
# wait, so the CI wait happens in the silence and the root's one wake already carries the final state. Not run in a command
# substitution: a failed run file write must stop the wait, not end up in a summary that says settled.
settle_line() {
    local id=${1%% *} kind n state=${1#* state=} own=$RUNFILE
    kind=${id%%=*} n=${id#*=}
    if [[ ${state%% *} != reported ]]; then
        run_lock wait
        item_settled "$kind" "$n" "${state%% *}"
        run_unlock
        RUN_LOCK=''
        SUMMARY+="$1 next=$(next_step "$kind" "$n" "${state%% *}")"$'\n'
        return 0
    fi
    LINES=()
    run_lock wait
    collect_one "$kind" "$n"
    if [[ $COLLECT_STATE == collected ]]; then
        item_settled "$kind" "$n" ''
        # The same reconciliation ak collect --issue runs: a run that held this issue as parked or red releases its dependents.
        [[ $kind != issue ]] || release_other_runs "$n" "$COLLECT_WORKTREE"
    fi
    RUNFILE=$own
    run_unlock
    RUN_LOCK=''
    if ((${#LINES[@]})); then SUMMARY+=$(printf '%s\n' "${LINES[@]}")$'\n'; else SUMMARY+="$1"$'\n'; fi
}

# settle STATES: print the summary of a settled wave and write it beside the run file. The marker goes only afterwards.
settle() {
    local line total=0 w file
    w=$(wave_number)
    file="$MAIN/.ak/runs/$RUN_ID.wave$w.summary"
    SUMMARY=''
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        total=$((total + 1))
        settle_line "$line"
    done <<<"$1"
    # No path on the closing count: roots read the file it named, a turn for lines they already had (bench 2026-10-28).
    SUMMARY+="wave=$w settled=$total/$total"
    printf '%s\n' "$SUMMARY" >"$file"
    printf '%s\n' "$SUMMARY"
}

# wait_loop [CHECK]: poll until nothing is running (CHECK returns 3 instead); settle once. With a summary already written
# (another watcher settled it while this one attached), print that summary instead.
wait_loop() {
    local states file
    while :; do
        states=$(wave_state)
        ! grep -q 'state=running' <<<"$states" && break
        if [[ ${1:-0} == 1 ]]; then report "$states" || true; return 3; fi
        sleep "${AK_WAIT_POLL_S:-15}"
    done
    file="$MAIN/.ak/runs/$RUN_ID.wave$(wave_number).summary"
    if [[ -z $states && ${#WAIT_NAMED[@]} -eq 0 && -f $file ]]; then cat -- "$file"; return 0; fi
    settle "$states"
}

# attach: a watcher is live; wait for its marker to clear. A readiness caller rechecks the wave while attached so it
# can return pending if a worker resumes after the initial probe. Plain waits retain their blocking behavior.
attach() {
    local check=${1:-0} states
    while marker_live; do
        if ((check)); then
            states=$(wave_state)
            if grep -q 'state=running' <<<"$states"; then report "$states" || true; return 3; fi
        fi
        sleep "${AK_WAIT_POLL_S:-15}"
    done
}

# open_corrections: a correction round adds each named item to the open wave (so the hook marker and collect --wave see
# it) and stamps the call time. An out item is left alone unless its prior worker ended and no round is open. The identities
# its last settle saw are kept; an item no settle saw (collected by hand) is compared with what is there now.
open_corrections() {
    local id kind n row wt at idents state seen round ended
    for id in "${WAIT_NAMED[@]}"; do
        kind=${id%%:*} n=${id#*:}
        row=$(jq -r --arg k "$kind" --argjson n "$n" '[.items[] | select(.kind == $k and .n == $n and (.worktree // "") != "")][0] //
            {state: "none"} | [.state, .worktree, (.spawned_at // 0), ((.seen // null) != null), (.round_at // 0), (.ended // "")] |
            map(tostring) | join("\u001f")' "$RUNFILE")
        IFS=$'\037' read -r state wt at seen round ended <<<"$row"
        [[ $state != none ]] || continue
        if [[ $state =~ ^(spawned|pending|merge-up)$ ]]; then
            [[ $round == 0 && -n $ended ]] || continue
        fi
        idents=''
        [[ $seen == true ]] || idents=$(item_idents "$kind" "$n" "$wt" "$at")
        run_lock wait
        run_update '(.open_wave // 1) as $w | (.items[] | select(.kind == $k and .n == $n and (.worktree // "") != "")) |=
            (.wave = $w | .state = "spawned" | .round_at = $now | del(.ended) |
             if .seen == null then .seen = {result: $r, transcript: $t} else . end)' --arg k "$kind" --argjson n "$n" \
            --argjson now "$(date +%s)" --arg r "${idents%%$'\037'*}" --arg t "${idents#*$'\037'}"
        run_unlock
        RUN_LOCK=''
    done
}

# next_wait: the command that settles the wave once --check reports none running, with the same named items.
next_wait() {
    local id out='next=ak wait'
    for id in "${WAIT_NAMED[@]}"; do out+=" --${id%%:*} ${id#*:}"; done
    printf '%s\n' "$out"
}

# wait_owner: wait and settle the currently loaded run using only its owned items.
wait_owner() {
    local check=$1 collect=$2 states rc
    plan_context wait
    if ((check)); then
        open_corrections
        states=$(wave_state)
        if ((collect == 0)); then
            report "$states" || return 3
            next_wait
            return 0
        fi
        if grep -q 'state=running' <<<"$states"; then report "$states" || true; return 3; fi
    else
        open_corrections
        states=$(wave_state)
        if grep -q 'state=queued' <<<"$states"; then
            report "$states" || true
            return 1
        fi
    fi
    until marker_take; do
        if ! marker_live; then rm -f -- "$MARKER"; continue; fi
        marker_mine || break
        attach "$check" || return $?
    done
    trap 'marker_drop; run_unlock' EXIT
    trap 'exit 143' TERM INT
    wait_loop "$check"
    rc=$?
    marker_drop
    return "$rc"
}

# named_wait: resolve each requested ID to its owning run, then keep every read, stamp, and summary in that run.
named_wait() {
    local id kind n owner states pending=0 errors=0
    local -a owners=() missing=() all_named=("${WAIT_NAMED[@]}")
    local -A groups=() state_by_owner=()
    for id in "${WAIT_NAMED[@]}"; do
        kind=${id%%:*} n=${id#*:}
        owner=$(find_owner "$kind" "$n") || owner=''
        if [[ -z $owner ]]; then
            missing+=("$kind=$n state=missing note=item is absent from saved runs next=$([[ $kind == issue ]] && echo 'ak plan --issue' || echo 'ak pr-plan --pr') $n")
            errors=1
            continue
        fi
        if [[ -z ${groups[$owner]:-} ]]; then owners+=("$owner"); fi
        groups[$owner]+="${groups[$owner]:+ }$id"
    done
    for owner in "${owners[@]}"; do
        load_owner "$owner"
        read -ra WAIT_NAMED <<<"${groups[$owner]}"
        plan_context wait
        ((WAIT_CHECK)) && open_corrections
        states=$(wave_state)
        state_by_owner[$owner]=$states
        [[ $states != *'state=running'* ]] || pending=1
        [[ $states != *'state=queued'* ]] || errors=1
    done
    if ((WAIT_CHECK)); then
        for owner in "${owners[@]}"; do
            load_owner "$owner"
            if ((${#owners[@]} == 1)); then report "${state_by_owner[$owner]}" || true
            else
                printf '%s\n' "${state_by_owner[$owner]}"
                printf 'wave=%s settled=%s/%s\n' "$(wave_number)" \
                    "$(grep -vc 'state=running' <<<"${state_by_owner[$owner]}" || true)" \
                    "$(grep -c . <<<"${state_by_owner[$owner]}" || true)"
            fi
        done
        ((${#missing[@]} == 0)) || printf '%s\n' "${missing[@]}"
        ((pending)) && return 3
        ((errors)) && return 1
        if ((!WAIT_SETTLE)); then
            WAIT_NAMED=("${all_named[@]}")
            next_wait
            return 0
        fi
    else
        if ((errors)); then
            for owner in "${owners[@]}"; do printf '%s\n' "${state_by_owner[$owner]}"; done
            ((${#missing[@]} == 0)) || printf '%s\n' "${missing[@]}"
            return 1
        fi
        for owner in "${owners[@]}"; do
            load_owner "$owner"
            read -ra WAIT_NAMED <<<"${groups[$owner]}"
            wait_owner 0 0 || return $?
        done
        ((${#missing[@]} == 0)) || printf '%s\n' "${missing[@]}"
        ((errors)) && return 1
        return 0
    fi
    # Every owned item is ready; settle each run under its own marker and summary path.
    for owner in "${owners[@]}"; do
        load_owner "$owner"
        read -ra WAIT_NAMED <<<"${groups[$owner]}"
        wait_owner 1 1 || return $?
    done
    ((${#missing[@]} == 0)) || printf '%s\n' "${missing[@]}"
    ((errors)) && return 1
    return 0
}

cmd_main() {
    local check=0 collect=0 states id usage='usage: ak wait [--issue N | --pr N]... [--check [--settle]]'
    while (($#)); do
        case $1 in
            --check) check=1; WAIT_CHECK=1; shift ;;
            --settle) collect=1; shift ;;
            --issue | --pr)
                [[ ${2:-} =~ ^[0-9]+$ ]] || usage_die "$usage"
                id="${1#--}:$2"
                [[ " ${WAIT_NAMED[*]} " == *" $id "* ]] || WAIT_NAMED+=("$id")
                shift 2 ;;
            *) usage_die "$usage" ;;
        esac
    done
    ((collect == 0 || check == 1)) || usage_die "$usage"
    WAIT_SETTLE=$collect
    MAIN=$(main_root)
    MARKER="$MAIN/.ak/wave.open"
    if [[ -f $MAIN/.ak/runs/current ]]; then
        RUN_ID=$(<"$MAIN/.ak/runs/current")
        RUNFILE="$MAIN/.ak/runs/$RUN_ID.json"
        if ! jq -e . "$RUNFILE" >/dev/null 2>&1; then
            ((${#WAIT_NAMED[@]})) || die "run file unreadable: $RUNFILE" 'ak plan'
            RUN_ID=''
            RUNFILE=''
        else
            owner_context
        fi
    elif ((${#WAIT_NAMED[@]} == 0)); then
        die 'no current run' 'ak plan'
    fi
    if ((${#WAIT_NAMED[@]})); then named_wait; return $?; fi
    WAIT_NAMED=()
    wait_owner "$check" "$collect"
}
