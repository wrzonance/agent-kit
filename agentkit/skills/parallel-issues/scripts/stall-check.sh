#!/usr/bin/env bash
# stall-check.sh -- is a worker's worktree still moving, judged by mtime alone?
#
# Stall detection is a rule, not forensics. A live worker leaves filesystem
# evidence: edits, .agent/logs/ writes, checkpoint updates. The newest mtime
# under the worktree is therefore the liveness signal, and this helper is the
# single place that reads it -- never `pgrep`, `stat` archaeology, or process
# inspection improvised per incident (issue #224 WS4).
#
# Verdicts, one machine-readable line on stdout:
#   active   the newest mtime advanced since the previous check
#   quiet    no change yet, but not past the threshold and streak
#   stalled  no filesystem change for >= threshold minutes across two or more
#            consecutive checks -- interrupt, re-dispatch once, then park
#
# State lives in a caller-named file (one worker each); the streak counts
# consecutive quiet checks so one slow moment cannot read as a stall.
#
# EXIT CODES
#   0  active or quiet
#   3  stalled
#   2  usage error or unreadable evidence
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

# Newest mtime under the worktree, .git excluded: git metadata churns for
# reasons that are not worker progress (fetches, lock probes), while every
# real sign of life -- source edits, .agent/logs/, checkpoints -- is a file.
newest=$(find "$worktree" -name .git -prune -o -type f -printf '%T@\n' 2> /dev/null |
    LC_ALL=C sort -n | tail -n 1) || true
newest=${newest%%.*}
[[ -n $newest ]] || die 'no files found under the worktree; evidence unavailable'

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

printf 'stall= worktree=%s newest=%s quiet-checks=%s threshold-minutes=%s verdict=%s\n' \
    "$worktree" "$newest" "$quiet_streak" "$threshold_minutes" "$verdict"
[[ $verdict != stalled ]] || exit 3
exit 0
