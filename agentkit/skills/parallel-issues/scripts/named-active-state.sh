#!/usr/bin/env bash
# Classify one operator-named active issue from durable local liveness evidence.
set -euo pipefail

readonly PROGRAM=${0##*/}

repo_root=''
ledger=''
issue=''
open_pr='none'
fresh_hours=''
now_epoch=''

usage() {
    printf 'usage: %s --repo-root DIR --ledger FILE --issue N --open-pr N|none --fresh-hours N [--now-epoch EPOCH]\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --repo-root)
            (($# >= 2)) || usage
            repo_root=$2
            shift 2
            ;;
        --ledger)
            (($# >= 2)) || usage
            ledger=$2
            shift 2
            ;;
        --issue)
            (($# >= 2)) || usage
            issue=$2
            shift 2
            ;;
        --open-pr)
            (($# >= 2)) || usage
            open_pr=$2
            shift 2
            ;;
        --fresh-hours)
            (($# >= 2)) || usage
            fresh_hours=$2
            shift 2
            ;;
        --now-epoch)
            (($# >= 2)) || usage
            now_epoch=$2
            shift 2
            ;;
        -h | --help) usage 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ $issue =~ ^[1-9][0-9]*$ ]] || die '--issue must be a positive integer'
[[ $open_pr == none || $open_pr =~ ^[1-9][0-9]*$ ]] ||
    die '--open-pr must be a positive integer or none'
[[ $fresh_hours =~ ^[1-9][0-9]*$ ]] || die '--fresh-hours must be a positive integer'
if [[ -z $now_epoch ]]; then
    now_epoch=$(date +%s) || die 'could not read the current time'
fi
[[ $now_epoch =~ ^[0-9]+$ ]] || die '--now-epoch must be a non-negative integer'

repo_root=$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null) ||
    die '--repo-root must be a Git checkout'
repo_root=$(cd -P -- "$repo_root" && pwd -P) || die 'could not canonicalize --repo-root'
[[ -n $ledger ]] || die '--ledger is required'
[[ ! -L $ledger ]] || die 'ledger must not be a symlink'
ledger_path=$(realpath -m -- "$ledger") || die 'could not canonicalize --ledger'
case $ledger_path in
    "$repo_root"/.agent/runs/*) ;;
    *) die '--ledger must be inside REPO_ROOT/.agent/runs' ;;
esac

if [[ $open_pr != none ]]; then
    printf 'held-active:#%s reason=pr pr=#%s\n' "$issue" "$open_pr"
    exit 0
fi

if [[ ! -e $ledger_path ]]; then
    printf 'stale-active=1[#%s]\n' "$issue"
    exit 0
fi
[[ ! -L $ledger_path && -f $ledger_path && -r $ledger_path && -O $ledger_path ]] ||
    die 'ledger must be a readable, owner-controlled regular file'
ledger_mode=$(stat -c '%a' -- "$ledger_path") || die 'could not inspect ledger permissions'
(( (8#$ledger_mode & 8#022) == 0 )) || die 'ledger must not be group/world writable'

# Every row is validated before one issue is selected. A malformed unrelated
# row means the root-owned evidence set is not trustworthy enough to dispatch.
jq -e -s '
    all(.[];
        type == "object" and
        ((keys_unsorted - ["version", "issue", "worktree", "branch", "state", "heartbeatEpoch"]) | length == 0) and
        (has("version") and has("issue") and has("worktree") and has("branch") and has("state") and has("heartbeatEpoch")) and
        .version == 1 and
        (.issue | type == "number" and . > 0 and floor == .) and
        (.worktree | type == "string" and startswith("/")) and
        (.branch | type == "string" and length > 0) and
        (.state == "active" or .state == "terminal") and
        ((.heartbeatEpoch == null) or
         (.heartbeatEpoch | type == "number" and . >= 0 and floor == .)))
' "$ledger_path" >/dev/null || die 'ledger contains malformed worker evidence'

record=$(jq -s -c --argjson issue "$issue" '[.[] | select(.issue == $issue)] | last // empty' \
    "$ledger_path") || die 'could not read worker evidence'
if [[ -z $record || $(jq -r '.state' <<<"$record") != active ]]; then
    printf 'stale-active=1[#%s]\n' "$issue"
    exit 0
fi

worktree=$(jq -r '.worktree' <<<"$record")
branch=$(jq -r '.branch' <<<"$record")
registered=no
current_worktree=''
current_branch=''
while IFS= read -r line; do
    case $line in
        worktree\ *) current_worktree=${line#worktree } ;;
        branch\ *) current_branch=${line#branch } ;;
        '')
            if [[ $current_worktree == "$worktree" &&
                  $current_branch == "refs/heads/$branch" &&
                  $current_worktree != "$repo_root" ]]; then
                registered=yes
            fi
            current_worktree=''
            current_branch=''
            ;;
    esac
done < <(git -C "$repo_root" worktree list --porcelain; printf '\n')

if [[ $registered == yes ]]; then
    printf 'held-active:#%s reason=worktree\n' "$issue"
    exit 0
fi

heartbeat=$(jq -r '.heartbeatEpoch // empty' <<<"$record")
if [[ -n $heartbeat ]]; then
    ((heartbeat <= now_epoch)) || die 'worker heartbeat is in the future'
    if ((now_epoch - heartbeat <= fresh_hours * 3600)); then
        printf 'held-active:#%s reason=heartbeat\n' "$issue"
        exit 0
    fi
fi

printf 'stale-active=1[#%s]\n' "$issue"
