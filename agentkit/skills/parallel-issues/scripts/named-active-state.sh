#!/usr/bin/env bash
# Classify one operator-named active issue from durable local liveness evidence.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}

repo_root=''
ledger=''
issue=''
open_pr='none'
fresh_hours=2
now_epoch=''
action=classify
attempt='' run_id='' worker_id='' worktree='' branch='' disposition='' evidence=''

usage() {
    printf 'usage: %s --repo-root DIR --ledger FILE --issue N --open-pr N|none --fresh-hours N [--now-epoch EPOCH]\n' "$PROGRAM" >&2
    printf '%s\n' 'Lifecycle: --action reserve|record|release|inventory|prune (same root/ledger)' \
        'reserve: --issue N --worktree DIR --branch B --run-id ID --attempt UNIQUE' \
        'record: --attempt ID --worker-id ID; release: --attempt ID --disposition rejected|stopped|completed|handed-back --evidence RECEIPT' >&2
    exit "${1:-2}"
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --action|--attempt|--run-id|--worker-id|--worktree|--branch|--disposition|--evidence|\
        --repo-root|--ledger|--issue|--open-pr|--fresh-hours|--now-epoch)
            (($# >= 2)) || usage
            option=${1#--}; option=${option//-/_}
            printf -v "$option" '%s' "$2"
            shift 2
            ;;
        --)
            shift
            (($# == 0)) || die 'unexpected positional arguments after --'
            break
            ;;
        -h | --help) usage 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done

case $action in classify|reserve|record|release|inventory|prune) ;; *) die 'invalid action' ;; esac
[[ $action != classify && $action != reserve || $issue =~ ^[1-9][0-9]*$ ]] || die '--issue must be a positive integer'
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
# The primary checkout owns one ledger even when invoked from a linked worktree.
repo_root=$(git -C "$repo_root" worktree list --porcelain | sed -n 's/^worktree //p' | head -n 1)
repo_root=$(realpath -e -- "$repo_root") || die 'could not resolve primary checkout'
[[ -n $ledger ]] || die '--ledger is required'
[[ ! -L $ledger ]] || die 'ledger must not be a symlink'
ledger_path=$(realpath -m -- "$ledger") || die 'could not canonicalize --ledger'
case $ledger_path in
    "$repo_root"/.agent/runs/*) ;;
    *) die '--ledger must be inside REPO_ROOT/.agent/runs' ;;
esac

if [[ $action == classify && $open_pr != none ]]; then
    printf 'held-active:#%s reason=pr pr=#%s\n' "$issue" "$open_pr"
    exit 0
fi

if [[ $action != classify ]]; then
    [[ $ledger_path == "$repo_root/.agent/runs/active-workers.ndjson" ]] || die 'lifecycle requires the repository-wide active-workers.ndjson'
    parent=$(dirname -- "$ledger_path")
    mkdir -p -- "$parent"
    [[ ! -L $parent && -O $parent ]] || die 'ledger parent must be owner-controlled'
    mode=$(stat -c %a -- "$parent")
    (( (8#$mode & 8#022) == 0 )) || die 'ledger parent must not be group/world writable'
    lock="$ledger_path.lock"
    [[ ! -L $lock && (! -e $lock || (-f $lock && -O $lock)) ]] || die 'unsafe ledger lock'
    exec {lock_fd}>>"$lock"
    flock -w 10 "$lock_fd" || die 'ownership lock unavailable after 10 seconds'
fi

if [[ ! -e $ledger_path && $action == classify ]]; then
    printf 'stale-active=1[#%s]\n' "$issue"
    exit 0
fi
if [[ -e $ledger_path || -L $ledger_path ]]; then
    [[ ! -L $ledger_path && -f $ledger_path && -r $ledger_path && -O $ledger_path ]] ||
        die 'ledger must be a readable, owner-controlled regular file'
    ledger_mode=$(stat -c '%a' -- "$ledger_path") || die 'could not inspect ledger permissions'
    (( (8#$ledger_mode & 8#077) == 0 )) || die 'ledger must be owner-private'
else
    # An absent ledger is empty only while holding its mutation lock.
    : >"$ledger_path"
fi

# Parse each physical NDJSON line independently so corruption remains inspectable.
# Age only exempts terminal validation, never erases evidence used to select owners.
entries=$(jq -Rnc --argjson now "$now_epoch" --argjson hours "$fresh_hours" '
    def failure($keys; $predicate): {keys:$keys, predicate:$predicate};
    def validate:
        if type != "object" then failure([]; "object")
        else
        ["version","issue","worktree","branch","state","heartbeatEpoch"] as $base |
        ($base + ["runId","attempt","workerId","disposition","evidence"]) as $v2 |
        (keys_unsorted - $v2) as $extra |
        ($base - keys_unsorted) as $missing |
        if .version != 1 and .version != 2 then failure(["version"]; "version")
        elif .version == 2 and ($extra | length) > 0 then failure($extra; "allowed-keys")
        elif ($missing | length) > 0 then failure($missing; "required-fields")
        elif (.version == 1 or (.version == 2 and has("workerId") and
            ([.runId, .attempt, .disposition] | all(type == "string" and length > 0)) and
            (.workerId == null or (.workerId | type == "string" and length > 0)) and
            (.evidence | type == "string") and
            (if .state == "active" then .workerId != null and .disposition == "returned"
             elif .state == "unknown" then .workerId == null and .disposition == "reserved"
             else .state == "terminal" and (.evidence | length > 0) and
                (.disposition == "rejected" or .disposition == "stopped" or
                 .disposition == "completed" or .disposition == "handed-back") end))) | not
          then failure(["runId","attempt","workerId","disposition","evidence","state"]; "v2-ownership")
        elif (.issue | type == "number" and . > 0 and floor == .) | not then failure(["issue"]; "positive-integer")
        elif (.worktree | type == "string" and startswith("/")) | not then failure(["worktree"]; "absolute-path")
        elif (.branch | type == "string" and length > 0) | not then failure(["branch"]; "nonempty-string")
        elif (.state == "active" or .state == "terminal" or (.version == 2 and .state == "unknown")) | not then failure(["state"]; "state")
        elif ((.heartbeatEpoch == null) or (.heartbeatEpoch | type == "number" and . >= 0 and floor == .)) | not
          then failure(["heartbeatEpoch"]; "heartbeat")
        else null end end;
    [inputs | {line:input_line_number, raw:.} |
        . + (try {row:(.raw | fromjson)} catch {error:., keys:[], predicate:"json"}) |
        if has("row") then
            . + {aged:(.row | if type == "object" then
                .state == "terminal" and (.heartbeatEpoch | type == "number" and . >= 0 and floor == . and . < ($now - $hours * 3600))
                else false end)} |
            . + {diagnostic:(.row | validate)}
        else . end]
' "$ledger_path") || die 'could not inspect worker evidence'

if [[ $action == prune ]]; then
    # Even historical active rows and incomplete/unknown parsed reservations are
    # conservative holds. Unparseable bytes can be removed only with no such row.
    jq -e 'all(.[] | select(has("row"));
        .row | type == "object" and .state == "terminal")' <<<"$entries" >/dev/null ||
        die 'prune refused: active, unknown or indeterminate worker evidence; reconcile runtime first'
    staged=$(mktemp "$parent/.active-workers.XXXXXX")
    trap 'rm -f -- "$staged"' EXIT
    jq -r '.[] | select(has("row") and (.aged | not)) | .raw' <<<"$entries" >"$staged"
    mv -f -- "$staged" "$ledger_path"
    jq -r '.[] | select((has("row") | not) or .aged) |
        "pruned line \(.line) reason=\(if .aged then "aged-terminal" else "unparseable" end)"' <<<"$entries"
    printf 'prune complete\n'
    exit 0
fi

if [[ $action != inventory ]]; then
    diagnostic=$(jq -r '.[] | select((has("row") | not) or ((.aged | not) and .diagnostic != null)) |
        "line \(.line) keys=\((.diagnostic.keys // .keys) | join(",")) predicate=\(.diagnostic.predicate // .predicate)"' <<<"$entries")
    [[ -z $diagnostic ]] || die "ledger contains malformed worker evidence: $diagnostic"
fi

if [[ $action != classify ]]; then
    rows=$(jq -c '[.[] | select(has("row")) | .row | select(type == "object")]' <<<"$entries")
    # Canonicalize legacy rows too: lexical aliases must not hide an older owner.
    while IFS= read -r old_path; do
        canonical=$(realpath -m -- "$old_path") || die 'invalid worktree path'
        rows=$(jq -c --arg old "$old_path" --arg new "$canonical" \
            'map(if .worktree == $old then .worktree = $new else . end)' <<<"$rows")
    done < <(jq -r '.[].worktree | select(type == "string" and startswith("/"))' <<<"$rows" | sort -u)
    latest=$(jq -c 'group_by(.worktree) | map(last)' <<<"$rows")
    if [[ $action == inventory ]]; then
        jq -c --argjson latest "$latest" '$latest + [.[] |
            select((has("row") | not) or .diagnostic != null) |
            {line, raw} + (.diagnostic // {keys, predicate, error})]' <<<"$entries"
        exit 0
    fi
    [[ $attempt =~ ^[A-Za-z0-9_-]+$ ]] || die '--attempt must be a stable unique identifier'
    if [[ $action == reserve ]]; then
        [[ -n $run_id && -n $branch && -d $worktree ]] || die 'reserve needs run, branch and existing worktree'
        worktree=$(realpath -e -- "$worktree")
        jq -e --arg p "$worktree" --arg a "$attempt" --argjson i "$issue" \
            'all(.[]; .attempt != $a) and (group_by(.worktree) | map(last) |
             all(.[]; (.worktree != $p and .issue != $i) or .state == "terminal"))' \
            <<<"$rows" >/dev/null || die 'ownership held or attempt already used; reconcile before retry'
        next=$(jq -nc --argjson i "$issue" --arg p "$worktree" --arg b "$branch" \
            --arg r "$run_id" --arg a "$attempt" --argjson t "$now_epoch" \
            '{version:2, issue:$i, worktree:$p, branch:$b, runId:$r, attempt:$a,
              workerId:null, state:"unknown", disposition:"reserved", evidence:"", heartbeatEpoch:$t}')
    else
        current=$(jq -c --arg a "$attempt" '[.[] | select(.attempt == $a)] | last // empty' <<<"$latest")
        [[ -n $current && $(jq -r .state <<<"$current") != terminal ]] || die 'no live reservation for attempt'
        if [[ $action == record ]]; then
            [[ -n $worker_id ]] || die '--worker-id is required'
            jq -e --arg id "$worker_id" '.workerId == null or .workerId == $id' <<<"$current" >/dev/null || die 'worker ID cannot change'
            next=$(jq -c --arg id "$worker_id" --argjson t "$now_epoch" \
                '.workerId=$id | .state="active" | .disposition="returned" | .heartbeatEpoch=$t' <<<"$current")
        else
            case $disposition in rejected|stopped|completed|handed-back) ;; *) die 'invalid terminal disposition' ;; esac
            [[ -n $evidence ]] || die 'release requires confirmed runtime evidence'
            [[ $disposition != rejected || $(jq -r .state <<<"$current") == unknown ]] || die 'a returned worker cannot be rejected'
            next=$(jq -c --arg d "$disposition" --arg e "$evidence" --argjson t "$now_epoch" \
                '.state="terminal" | .disposition=$d | .evidence=$e | .heartbeatEpoch=$t' <<<"$current")
        fi
    fi
    staged=$(mktemp "$parent/.active-workers.XXXXXX")
    trap 'rm -f -- "$staged"' EXIT
    cat -- "$ledger_path" >"$staged"
    printf '%s\n' "$next" >>"$staged"
    mv -f -- "$staged" "$ledger_path"
    printf '%s\n' "$next"
    exit 0
fi

# Durable v2 ownership never expires; an older active issue cannot be hidden by
# a terminal row for another worktree. Legacy-only ledgers retain old semantics.
held=$(jq -sc --argjson i "$issue" 'group_by(.worktree) | map(last) |
    [.[] | select(.version == 2 and .issue == $i and .state != "terminal")] | first // empty' "$ledger_path")
if [[ -n $held ]]; then
    printf 'held-active:#%s reason=%s\n' "$issue" "$(jq -r .state <<<"$held")"
    exit 0
fi

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
