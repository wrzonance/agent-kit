#!/usr/bin/env bash
# stall-check.sh -- is a worker's worktree still moving, judged by the newest mtime
# alone (never pgrep or process archaeology; issue #224 WS4)? State lives in a
# caller-named file per worker; the streak counts consecutive quiet checks.
# Verdicts (one line on stdout):
#   active   the newest mtime advanced since the previous check
#   quiet    no change yet, but not past the threshold and streak
#   stalled  no change for >= threshold minutes across two or more consecutive checks
# The same line reports last-verification=<log basename> and last-rc=<N> for
# the newest completed agent-run log, or none/none when no terminal marker exists.
# Exit: 0 active or quiet, 3 stalled, 2 usage error or unreadable evidence.
set -euo pipefail

readonly PROGRAM=${0##*/}
readonly STALL_THRESHOLD_MINUTES_DEFAULT=12

worktree=''
state_file=''
threshold_minutes=$STALL_THRESHOLD_MINUTES_DEFAULT

usage() {
    printf 'usage: %s --worktree PATH --state FILE [--threshold-minutes N]\n' "$PROGRAM" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --worktree)
            [[ -n ${2:-} ]] || die '--worktree requires a value'
            worktree=$2
            shift 2
            ;;
        --state)
            [[ -n ${2:-} ]] || die '--state requires a value'
            state_file=$2
            shift 2
            ;;
        --threshold-minutes)
            [[ -n ${2:-} ]] || die '--threshold-minutes requires a value'
            threshold_minutes=$2
            shift 2
            ;;
        -h | --help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n $worktree && -d $worktree ]] || die '--worktree must be an existing directory'
[[ -n $state_file ]] || die '--state is required'
[[ $threshold_minutes =~ ^[0-9]+$ ]] || die '--threshold-minutes must be a non-negative integer'
[[ ! -L $state_file ]] || die 'state file must not be a symlink'
worktree=$(cd -P -- "$worktree" && pwd -P) || die 'could not canonicalize the worktree'
state_canonical=$(realpath -m -- "$state_file") || die 'could not canonicalize the state path'
primary_root=$worktree
checkout_root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null || true)
if [[ -n $checkout_root && $(realpath -e -- "$checkout_root" 2>/dev/null || true) == "$worktree" ]]; then
    resolved_primary=$(git -C "$worktree" worktree list --porcelain 2>/dev/null |
        awk '/^worktree / { sub(/^worktree /, ""); print; exit }')
    [[ -z $resolved_primary ]] || primary_root=$(realpath -e -- "$resolved_primary") ||
        die 'could not canonicalize the primary checkout'
fi
for reserved_state in "$primary_root/.agent/session-ledger.ndjson" \
    "$primary_root/.agent/runs/active-workers.ndjson"; do
    reserved_canonical=$(realpath -m -- "$reserved_state") || die 'could not canonicalize a reserved workflow ledger'
    if [[ $state_canonical == "$reserved_canonical" ||
        (-e $state_file && -e $reserved_state && $state_file -ef $reserved_state) ]]; then
        die "--state must not alias a reserved workflow ledger: $reserved_canonical"
    fi
done

# Newest mtime under the worktree, .git excluded: git metadata churns for
# reasons that are not worker progress (fetches, lock probes), while every
# real sign of life -- source edits, .agent/logs/, checkpoints -- is a file.
# The state file and its mktemp siblings are excluded too: the documented
# state path lives INSIDE the worktree (.agent/stall-state), and a detector
# that counts its own writes as liveness never reaches a second quiet check.
newest=$(find "$worktree" -name .git -prune -o -name '.stall-check.*' -prune -o \
    -type f ! -path "$state_canonical" -printf '%T@\n' 2> /dev/null |
    LC_ALL=C sort -n | tail -n 1) || true
newest=${newest%%.*}
[[ -n $newest ]] || die 'no files found under the worktree; evidence unavailable'

last_verification=none
last_rc=none
logs_dir="$worktree/.agent/logs"
if [[ -d $logs_dir ]]; then
    while IFS= read -r -d '' candidate; do
        log=${candidate#* }
        marker=$(tail -n 1 -- "$log" 2> /dev/null) || continue
        if [[ $marker =~ ^===\ agent-run\ exited\ rc=([0-9]+)([[:space:]].*)?$ ]]; then
            last_verification=${log##*/}
            last_rc=${BASH_REMATCH[1]}
            break
        fi
    done < <(find "$logs_dir" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\0' 2> /dev/null | LC_ALL=C sort -zrn)
fi

previous_newest=''
quiet_streak=0
if [[ -e $state_file ]]; then
    [[ -f $state_file && -r $state_file ]] || die 'state file is not a readable regular file'
    while IFS='=' read -r key value; do
        case $key in
            newest) previous_newest=$value ;;
            quiet) quiet_streak=$value ;;
        esac
    done < "$state_file"
    [[ $previous_newest =~ ^[0-9]+$ ]] || previous_newest=''
    [[ $quiet_streak =~ ^[0-9]+$ ]] || quiet_streak=0
fi

now=$(date +%s)
verdict=active
if [[ -z $previous_newest || $newest -gt $previous_newest ]]; then
    quiet_streak=0
else
    quiet_streak=$((quiet_streak + 1))
    idle_seconds=$((now - newest))
    if ((quiet_streak >= 2 && idle_seconds >= threshold_minutes * 60)); then
        verdict=stalled
    else
        verdict=quiet
    fi
fi

state_dir=$(dirname -- "$state_file")
[[ -d $state_dir ]] || die "state directory does not exist: $state_dir"
state_tmp=$(mktemp "$state_dir/.stall-check.XXXXXXXXXX") || die 'could not write state'
printf 'newest=%s\nquiet=%s\n' "$newest" "$quiet_streak" > "$state_tmp"
mv -f -- "$state_tmp" "$state_file"

printf 'stall= worktree=%s newest=%s quiet-checks=%s threshold-minutes=%s verdict=%s last-verification=%s last-rc=%s\n' \
    "$worktree" "$newest" "$quiet_streak" "$threshold_minutes" "$verdict" \
    "$last_verification" "$last_rc"
[[ $verdict != stalled ]] || exit 3
exit 0
