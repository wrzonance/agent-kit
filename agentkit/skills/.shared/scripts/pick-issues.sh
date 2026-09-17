#!/usr/bin/env bash
# Usage:
#   pick-issues.sh [--repo-root DIR] [--limit N] [--include-backlog]
#                  [--ready-only] [--fast-mode --slot-cap N] [--json]
# Exit: 0 success (including empty), 1 a call failed or the board read was truncated
#       (a partial read refuses to select), 2 bad usage, 3 gh unavailable/unauthenticated.
set -euo pipefail

readonly PROGRAM=${0##*/}
readonly DEFAULT_LIMIT=1000
readonly BLOCKER_PAGE=20
readonly FAST_MODE_CAP=10

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}
die_blocked() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 3
}
die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    printf 'usage: %s [--repo-root DIR] [--limit N] [--include-backlog] [--ready-only] [--fast-mode --slot-cap N] [--json]\n' \
        "$PROGRAM" >&2
    exit 2
}

repo_root=''
limit=$DEFAULT_LIMIT
include_backlog=0
as_json=0
fast_mode=0
slot_cap=$FAST_MODE_CAP
slot_cap_supplied=0

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --repo-root)
            shift
            (($#)) || die_usage '--repo-root requires a directory'
            repo_root=$1
            ;;
        --limit)
            shift
            (($#)) || die_usage '--limit requires a number'
            limit=$1
            ;;
        --include-backlog) include_backlog=1 ;;
        # The default already excludes Backlog. The flag exists so a caller can
        # say so explicitly and read back what it asked for.
        --ready-only) include_backlog=0 ;;
        --fast-mode) fast_mode=1 ;;
        --slot-cap)
            shift
            (($#)) || die_usage '--slot-cap requires a number'
            slot_cap=$1
            slot_cap_supplied=1
            ;;
        --json) as_json=1 ;;
        -h | --help) die_usage 'help requested' ;;
        *) die_usage "unknown argument: $1" ;;
    esac
    shift
done

[[ $limit =~ ^[0-9]{1,4}$ ]] || die_usage "--limit must be a number, got: $limit"
if ((fast_mode)); then
    [[ $slot_cap =~ ^[1-9][0-9]*$ && $slot_cap -le $FAST_MODE_CAP ]] ||
        die_usage "--slot-cap must be between 1 and $FAST_MODE_CAP in fast mode"
elif ((slot_cap_supplied)); then
    die_usage '--slot-cap requires --fast-mode'
fi

for tool in gh jq; do
    command -v "$tool" > /dev/null 2>&1 || die_blocked "$tool is not installed"
done

[[ -n $repo_root ]] || repo_root=$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")
repo_root=$(cd -- "$repo_root" 2>/dev/null && pwd -P) || die_blocked 'repository root is not a directory'
agent_dir="$repo_root/.agent"
[[ -d $agent_dir && ! -L $agent_dir && -O $agent_dir ]] ||
    die_blocked "$agent_dir must be an owned plain directory"
board_file="$agent_dir/board.json"
[[ -r $board_file ]] ||
    die_blocked "no .agent/board.json in $repo_root; run bootstrap-repo.sh first"

project_number=$(jq -r '.project.number // empty' "$board_file" 2> /dev/null || true)
board_owner=$(jq -r '.owner // empty' "$board_file" 2> /dev/null || true)
[[ -n $project_number && -n $board_owner ]] ||
    die_blocked '.agent/board.json declares no project number or owner'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repository=''
if [[ -x "$script_dir/repo-config.sh" ]]; then
    repository=$("$script_dir/repo-config.sh" --repo-root "$repo_root" \
        --get AGENT_REPO_SLUG 2> /dev/null || true)
fi
if [[ -z $repository ]]; then
    repository=$(
        cd -- "$repo_root" || exit 0
        gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || true
    )
fi
[[ $repository =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die_blocked 'cannot resolve the repository for a selection'

# ---------------------------------------------------------------- call one ---
items=$(gh project item-list "$project_number" --owner "$board_owner" \
    --limit "$limit" --format json 2> /dev/null) ||
    die "could not read project $project_number for owner $board_owner"

declared_total=$(jq -r '.totalCount // empty' <<< "$items" 2> /dev/null || true)
fetched=$(jq -r '(.items // []) | length' <<< "$items" 2> /dev/null || printf '0')

# Eligibility requires the whole board; a truncated read cannot select safely.
if [[ -n $declared_total ]] && ((fetched < declared_total)); then
    printf 'pick= project=%s owner=%s scanned=%s of=%s calls=1\n' \
        "$project_number" "$board_owner" "$fetched" "$declared_total" >&2
    printf 'TRUNCATED: read %s of %s items. Selection refused -- every count above is a\n' \
        "$fetched" "$declared_total" >&2
    printf 'count of what was read, not of what the board holds. Re-run with --limit %s.\n' \
        "$((declared_total + 100))" >&2
    exit 1
fi

wanted_statuses='["ready"]'
((include_backlog == 0)) || wanted_statuses='["ready","backlog"]'

candidates=$(jq -c --arg repo "${repository,,}" --argjson want "$wanted_statuses" '
    [ (.items // [])[]
      | select((.content.type // "") == "Issue")
      | { number: (.content.number // null),
          title:  (.content.title // .title // "(untitled)"),
          status: (.status // ""),
          repository: (
            ((.content.repository // "") | tostring)
            | sub("^https?://[^/]+/"; "") | rtrimstr("/") | ascii_downcase
          ) }
      | select(.number != null and .repository == $repo)
      | select((.status | ascii_downcase) as $s | $want | index($s) != null)
    ]' <<< "$items" 2> /dev/null) || die 'could not parse the project response'

count=$(jq -r 'length' <<< "$candidates")
if ((count == 0)); then
    if ((as_json)); then
        printf '[]\n'
    else
        printf 'pick= project=%s owner=%s scanned=%s of=%s candidates=0 selectable=0 calls=1\n' \
            "$project_number" "$board_owner" "$fetched" "${declared_total:-$fetched}"
        printf 'nothing is eligible to start\n'
    fi
    exit 0
fi

# ---------------------------------------------------------------- call two ---
owner=${repository%%/*}
name=${repository##*/}
# shellcheck disable=SC2016  # GraphQL variable names, not shell expansions.
query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'
while IFS= read -r n; do
    query+=" i${n}: issue(number: ${n}) { number state body"
    query+=" blockedBy(first: ${BLOCKER_PAGE}) { totalCount nodes { number state } } }"
done < <(jq -r '.[].number' <<< "$candidates")
query+=' } }'

deps=$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" 2> /dev/null) ||
    die 'could not read issue dependencies'
# GraphQL errors can accompany HTTP 200; partial data cannot prove eligibility.
if [[ $(jq -r 'has("errors")' <<< "$deps" 2> /dev/null) == true ]] ||
    [[ $(jq -r '.data.repository | type' <<< "$deps" 2> /dev/null) != object ]]; then
    die "the dependency query was rejected: $(jq -rc '.errors[0].message // "no data"' <<< "$deps" 2> /dev/null)"
fi

selection=$(jq -c --argjson deps "$(jq -c '.data.repository' <<< "$deps")" '
    map(
      . as $item
      | ($deps["i" + ($item.number | tostring)] // null) as $d
      | ($d.blockedBy.nodes // []) as $b
      | . + { state: ($d.state // "UNKNOWN"),
              body: ($d.body // ""),
              blockers: [ $b[] | select(.state == "OPEN") | .number ],
              blockerTotal: ($d.blockedBy.totalCount // 0),
              blockerRead: ($b | length) }
    )
    | map(select(.state == "OPEN"))
    | map(. + { eligible: ((.blockers | length) == 0 and .blockerTotal == .blockerRead) })
    | sort_by([(if (.status | ascii_downcase) == "ready" then 0 else 1 end), .number])
' <<< "$candidates") || die 'could not merge dependency state'

issue_paths=$script_dir/../../parallel-issues/scripts/issue-paths.sh
[[ -x $issue_paths ]] || die 'issue-paths.sh is unavailable'
triage=$script_dir/triage-issues.sh
[[ -x $triage ]] || die 'triage-issues.sh is unavailable'
body_file=$(mktemp "${TMPDIR:-/tmp}/pick-issues.body.XXXXXX") || die 'could not create body cache'
chmod 600 "$body_file"; trap 'rm -f -- "$body_file"' EXIT
cache_parent="$repo_root/.agent/cache"
cache_root="$cache_parent/pick-issues-bodies"
for dir in "$cache_parent" "$cache_root"; do
    [[ ! -L $dir && (! -e $dir || -d $dir) ]] || die "$dir exists and is not a plain directory"
    mkdir -p -- "$dir" || die "could not create $dir"
    [[ -O $dir ]] || die "$dir is not owned by the current user"
done
chmod 700 -- "$cache_root" || die 'could not restrict the issue body cache root'
[[ $(stat -c '%a' "$cache_root" 2>/dev/null) == 700 ]] || die 'issue body cache root is not mode 700'
cache_dir=$(mktemp -d "$cache_root/run.XXXXXX") || die 'could not create an invocation body cache'
chmod 700 -- "$cache_dir" || die 'could not restrict the invocation body cache'
[[ $(stat -c '%a' "$cache_dir" 2>/dev/null) == 700 ]] || die 'invocation body cache is not mode 700'
while IFS=$'\t' read -r issue body_b64; do
    printf '%s' "$body_b64" | base64 -d >"$body_file" || die "could not decode body for issue #$issue"
    records=$("$issue_paths" --issue "$issue" \
        --repo-root "$repo_root" --body-file "$body_file") || die "could not derive paths for issue #$issue"
    paths=$(awk '{sub(/^[^ ]+ /, ""); print}' <<<"$records" |
        jq -Rsc 'split("\n") | map(select(length > 0))')
    cache_file="$cache_dir/issue-$issue.json"
    cache_tmp=$(mktemp "$cache_dir/.issue-$issue.XXXXXX") || die "could not stage body cache for issue #$issue"
    jq -cn --arg repository "$repository" --argjson issue "$issue" --rawfile body "$body_file" \
        '{schemaVersion:1,repository:$repository,issue:$issue,body:$body}' >"$cache_tmp" ||
        die "could not encode body cache for issue #$issue"
    chmod 600 -- "$cache_tmp" || die "could not restrict body cache for issue #$issue"
    mv -f -- "$cache_tmp" "$cache_file" || die "could not publish body cache for issue #$issue"
    shape_record=$("$triage" --classify-shape "$body_file") || die "could not classify work shape for issue #$issue"
    work_shape=${shape_record#work-shape=}; work_shape=${work_shape%% signal=*}
    hold_reason=${shape_record#* signal=}
    selection=$(jq -c --argjson issue "$issue" --argjson paths "$paths" --rawfile body "$body_file" --arg cache "$cache_file" \
        --arg shape "$work_shape" --arg reason "$hold_reason" '
      map(if .number == $issue then
        . + {predictedWriteSet: $paths, workShape: $shape, bodyCache: $cache,
             requirementsDigest: ([.title[0:240]] +
               ($body | split("\n") | map(gsub("[[:cntrl:]]"; " ") |
                 gsub("^\\s+|\\s+$"; "") | select(length > 0) | .[0:240])) | .[:12])}
        | if $shape == "no-code" then .eligible = false | .holdReason = $reason else . end
      else . end)' <<<"$selection")
done < <(jq -r '.[] | [.number, (.body | @base64)] | @tsv' <<<"$selection")
selection=$(jq -c 'map(del(.body))' <<<"$selection")

# Fast mode marks the first N eligible issues and queues the rest for refill.
if ((fast_mode)); then
    selection=$(jq -c --argjson cap "$slot_cap" '
      [ .[] | select(.eligible) ] as $eligible |
      ($eligible[:$cap] | map(.number)) as $wave |
      map(. as $item | . + {
        dispatch: ($item.eligible and (($wave | index($item.number)) != null)),
        queued: ($item.eligible and (($wave | index($item.number)) == null))
      })
    ' <<< "$selection") || die 'could not mark fast-mode queue'
else
    selection=$(jq -c 'map(. + {dispatch: .eligible, queued: false})' <<< "$selection") ||
        die 'could not mark dispatch selection'
fi

if ((as_json)); then
    printf '%s\n' "$selection"
    exit 0
fi

eligible=$(jq -r '[.[] | select(.eligible)] | length' <<< "$selection")
dispatched=$(jq -r '[.[] | select(.dispatch)] | length' <<< "$selection")
queued=$(jq -r '[.[] | select(.queued)] | length' <<< "$selection")
printf 'pick= project=%s owner=%s scanned=%s of=%s candidates=%s selectable=%s dispatched=%s queued=%s calls=2\n' \
    "$project_number" "$board_owner" "$fetched" "${declared_total:-$fetched}" "$count" "$eligible" "$dispatched" "$queued"

jq -r '.[]
    | if .workShape == "no-code" then "  HOLD " elif .queued then "  QUEUE " elif .dispatch then "  " else "  SKIP " end
      + "#\(.number)  \(.status)  \(.title)"
      + (if .dispatch or .queued then ""
         elif .workShape == "no-code" then "  [no-code: \(.holdReason)]"
         elif (.blockers | length) > 0 then "  [blocked by \((.blockers | map("#" + tostring) | join(", ")))]"
         else "  [\(.blockerTotal) blockers, only \(.blockerRead) read; treat as blocked]"
         end)' <<< "$selection"

((eligible > 0)) ||
    printf 'every candidate is blocked; nothing is eligible to start\n'
exit 0
