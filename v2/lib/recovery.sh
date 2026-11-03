# shellcheck shell=bash
# Planning a new run distinguishes a worker still out from work its predecessor left behind.
# shellcheck source=transcript.sh
source "$AK_HOME/lib/transcript.sh"

# issue_active N [SKIP_RUNFILE]: why N must not spawn again, or nothing. Collect passes its run file:
# its receipt satisfies a queued wave, whereas a fresh plan must check whether that PR is still open.
issue_active() {
    local n=$1 skip=${2:-} file item state wt needs ended seen=0 pr json parked record parked_head head
    while IFS= read -r file; do
        [[ $file != "$skip" ]] || continue
        item=$(jq -r --argjson n "$n" '[.items[] | select(.kind == "issue" and .n == $n)][0] // empty |
            [.state, .worktree // "", (.needs | map("#" + tostring) | join(",")), (.ended // "")] | join("|")' "$file")
        [[ -n $item ]] || continue
        seen=1
        IFS='|' read -r state wt needs ended <<<"$item"
        case $state in
            queued) ! run_live "$file" || { printf 'queued-after-%s\n' "$needs"; return 0; } ;;
            spawned | red | blocked) ! worker_out "$wt" "$file" "$ended" || { printf 'running\n'; return 0; } ;;
            parked) ! resumed_park "$wt" || ! worker_out "$wt" "$file" || { printf 'running\n'; return 0; } ;;
        esac
        break
    done < <(find "$MAIN/.ak/runs" -maxdepth 1 -name '*.json' 2>/dev/null | LC_ALL=C sort -Vr)
    wt=$(issue_worktree "$n")
    # A known worktree can outlive its run record. Never count a merely existing directory as ownership.
    if ((seen == 0)) && [[ -f $wt/.ak/issue ]] && [[ $(cat "$wt/.ak/issue") == "$n" ]] && worker_out "$wt" ''; then
        printf 'running\n'; return 0
    fi
    if [[ -f $wt/.ak/result ]]; then
        parked=$(sed -n 's/^note=parked: //p' "$wt/.ak/result" | head -n 1)
        if [[ -n $parked ]]; then
            # Naming the issue is the operator's explicit decision to revisit its parked cause.
            [[ ${NAMED:-0} != 0 ]] || {
            record=$(handed_file "$wt") || { printf 'parked\n'; return 0; }
            [[ ! -L $record.parked && -f $record.parked ]] || { printf 'parked\n'; return 0; }
            parked_head=$(head -n 1 -- "$record.parked")
            head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || { printf 'parked\n'; return 0; }
            [[ $head != "$parked_head" ]] || { printf 'parked\n'; return 0; }
            }
        fi
    fi
    [[ -f $wt/.ak/result ]] || return 0
    pr=$(sed -n 's/^pr=//p' "$wt/.ak/result" | head -n 1)
    [[ $pr == http* ]] || return 0
    if [[ -n $skip ]]; then printf 'shipped:%s\n' "$pr"; return 0; fi
    # Only a PR number from this repository reaches the API, never a worker-supplied URL or command.
    n=${pr##*/}
    [[ $n =~ ^[0-9]+$ && $pr == *"/$SLUG/pull/$n" ]] || { printf 'pr-state-unreadable\n'; return 0; }
    json=$(api "repos/$SLUG/pulls/$n") || { printf 'pr-state-unreadable:ak pr-plan --pr %s\n' "$n"; return 0; }
    case $(jq -r '.state // ""' <<<"$json" 2>/dev/null) in
        open) printf 'shipped:%s\n' "$pr" ;;
        closed) ;;
        *) printf 'pr-state-unreadable:ak pr-plan --pr %s\n' "$n" ;;
    esac
}

# worker_transcript WORKTREE RUNFILE: find the worker in its owning session, not necessarily this invocation's.
worker_transcript() {
    local wt=$1 file=$2 owner='' provider since=0 n m
    provider=$(harness)
    n=${wt##*/issue-}
    if [[ -f $file ]]; then
        owner=$(jq -r '.session // ""' "$file")
        provider=$(jq -r --arg h "$provider" '.harness // $h' "$file")
        since=$(jq -r --arg wt "$wt" '[.items[] | select(.worktree == $wt) | .spawned_at // 0] | max // 0' "$file")
    fi
    if [[ -f $wt/.ak/prompt.md ]]; then
        m=$(file_mtime "$wt/.ak/prompt.md")
        ((m <= since)) || since=$m
    fi
    if [[ $provider == codex ]]; then
        CODEX_THREAD_ID=${owner:-${CODEX_THREAD_ID:-}} transcript_codex "issue_$n" "$since"
    else
        CLAUDE_CODE_SESSION_ID=${owner:-${CLAUDE_CODE_SESSION_ID:-}} transcript_claude "$wt" "$since"
    fi
}

# worker_out WORKTREE RUNFILE [ENDED]: live transcript evidence outranks a previous hang/stop classification.
# Without a transcript, an explicit end releases the work; otherwise recent files protect it.
worker_out() {
    local wt=$1 age tr since=0 state
    [[ -n $wt && -d $wt && ! -f $wt/.ak/result ]] || return 1
    tr=$(worker_transcript "$wt" "$2")
    if [[ -n $tr ]]; then
        state=$(transcript_state "$tr")
        [[ $state == running ]] || return 1
        (($(transcript_age "$tr") < ${AK_WAIT_HANG_S:-1200}))
        return
    fi
    [[ -z ${3:-} ]] || return 1
    if [[ -e $wt/.ak/logs || -e $wt/.ak/setup.ok ]] ||
        [[ -n $(GIT_OPTIONAL_LOCKS=0 git -C "$wt" status --porcelain --untracked-files=all 2>/dev/null) ]]; then
        (($(worktree_idle_s "$wt") < ${AK_WAIT_HANG_S:-1200}))
        return
    fi
    [[ ! -f $wt/.ak/prompt.md ]] || since=$(file_mtime "$wt/.ak/prompt.md")
    age=$(($(date +%s) - since))
    ((age < ${AK_SPAWN_GRACE:-600}))
}

# resumed_park WORKTREE: work after a removed park result means its worker was answered in place.
resumed_park() {
    local wt=$1
    [[ -n $wt && ! -f $wt/.ak/result && -f $wt/.ak/parked ]] || return 1
    [[ -n $(find "$wt/.ak/logs" -type f -newer "$wt/.ak/parked" -print -quit 2>/dev/null) ]]
}

# run_live FILE: does the run still have a worker out? Used only to protect a queued item.
run_live() {
    local wt state ended
    while IFS='|' read -r state wt ended; do
        [[ $state != parked ]] || resumed_park "$wt" || continue
        worker_out "$wt" "$1" "$ended" && return 0
    done < <(jq -r '.items[] | select(.state | IN("spawned", "red", "blocked", "parked")) |
        [.state, .worktree // "", .ended // ""] | join("|")' "$1")
    return 1
}
