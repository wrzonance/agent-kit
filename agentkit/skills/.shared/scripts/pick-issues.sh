#!/usr/bin/env bash
# Select the issues an autonomous run may start, in two calls.
#
# `--fast-mode` dispatches without asking, so the selection has to be made by
# something that cannot be talked into a bad pick by an issue body. This script
# answers one question mechanically -- which issues are eligible to start right
# now -- and leaves the judgement call that is genuinely the agent's (which of
# them touch the same files) to the conflict analysis that follows.
#
# Eligible means all of:
#   * the issue is OPEN;
#   * its board Status is Ready, or Backlog when --include-backlog is set;
#   * nothing it is blocked by is still open.
#
# The blocked-by half is why this exists rather than a board query. GitHub issue
# dependencies live on the issue, not on the project item, so a board read alone
# reports a blocked issue as ready to start -- and an autonomous run would take
# it. Every dependency is fetched in one aliased batch, so the cost is two calls
# whatever the candidate count.
#
# Usage:
#   pick-issues.sh [--repo-root DIR] [--limit N] [--include-backlog]
#                  [--ready-only] [--json]
#
# Exit: 0 success (including an empty selection), 1 a call failed or the board
#       read was truncated (declared total exceeds what --limit fetched -- a
#       partial read cannot judge the whole board, so it refuses to select),
#       2 bad usage, 3 gh unavailable/unauthenticated (environment-blocked).
set -euo pipefail

readonly PROGRAM=${0##*/}
# 1000, not 50. A 123-card board answered through a 50-item window reported
# "candidates=3 of=123" -- two numbers describing different populations on one
# line, read by an unattended run as a whole-board scan. board-list.sh already
# carries this lesson (see its ARG_LIMIT comment); this script did not inherit
# it until this default caught the same defect on a live run.
readonly DEFAULT_LIMIT=1000
# Dependencies deep enough to exceed this are a planning problem, not a paging
# problem; the count is reported so a truncated read never reads as "unblocked".
readonly BLOCKER_PAGE=20

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
    printf 'usage: %s [--repo-root DIR] [--limit N] [--include-backlog] [--ready-only] [--json]\n' \
        "$PROGRAM" >&2
    exit 2
}

repo_root=''
limit=$DEFAULT_LIMIT
include_backlog=0
as_json=0

while (($#)); do
    case $1 in
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
        --json) as_json=1 ;;
        -h | --help) die_usage 'help requested' ;;
        *) die_usage "unknown argument: $1" ;;
    esac
    shift
done

[[ $limit =~ ^[0-9]{1,4}$ ]] || die_usage "--limit must be a number, got: $limit"

for tool in gh jq; do
    command -v "$tool" > /dev/null 2>&1 || die_blocked "$tool is not installed"
done

[[ -n $repo_root ]] || repo_root=$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")
board_file="$repo_root/.agent/board.json"
[[ -r $board_file ]] ||
    die_blocked "no .agent/board.json in $repo_root; run bootstrap-repo.sh first"

project_number=$(jq -r '.project.number // empty' "$board_file" 2> /dev/null || true)
board_owner=$(jq -r '.owner // empty' "$board_file" 2> /dev/null || true)
[[ -n $project_number && -n $board_owner ]] ||
    die_blocked '.agent/board.json declares no project number or owner'

# The board is shared across repositories more often than not, so an item's
# repository decides whether it is ours. Resolving it from --repo-root rather
# than the process working directory is the same correctness rule the board
# reader learned the hard way.
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

# A truncated read must not produce a selection: selection is an eligibility
# judgement over the whole board, and a partial read cannot make it. Reporting
# a plausible-looking subset here is the exact defect this script exists to
# avoid -- a confident, silently-wrong answer instead of a slow, honest one.
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

# Repository comes back as OWNER/REPO on some gh versions and as a URL on
# others; normalise both rather than matching either.
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
# One aliased batch, not one request per issue. The alias has to start with a
# letter, so the issue number is prefixed rather than used bare.
owner=${repository%%/*}
name=${repository##*/}
# shellcheck disable=SC2016  # GraphQL variable names, not shell expansions.
query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {'
while IFS= read -r n; do
    query+=" i${n}: issue(number: ${n}) { number state"
    query+=" blockedBy(first: ${BLOCKER_PAGE}) { totalCount nodes { number state } } }"
done < <(jq -r '.[].number' <<< "$candidates")
query+=' } }'

deps=$(gh api graphql -f query="$query" -f owner="$owner" -f name="$name" 2> /dev/null) ||
    die 'could not read issue dependencies'
# A rejected GraphQL query is an HTTP 200 with an errors array, so a zero exit
# is not proof the answer is usable. Selecting on a partial answer would call a
# blocked issue eligible, which is the one mistake this script exists to avoid.
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
              blockers: [ $b[] | select(.state == "OPEN") | .number ],
              blockerTotal: ($d.blockedBy.totalCount // 0),
              blockerRead: ($b | length) }
    )
    | map(select(.state == "OPEN"))
    | map(. + { eligible: ((.blockers | length) == 0 and .blockerTotal == .blockerRead) })
    | sort_by([(if (.status | ascii_downcase) == "ready" then 0 else 1 end), .number])
' <<< "$candidates") || die 'could not merge dependency state'

if ((as_json)); then
    printf '%s\n' "$selection"
    exit 0
fi

eligible=$(jq -r '[.[] | select(.eligible)] | length' <<< "$selection")
printf 'pick= project=%s owner=%s scanned=%s of=%s candidates=%s selectable=%s calls=2\n' \
    "$project_number" "$board_owner" "$fetched" "${declared_total:-$fetched}" "$count" "$eligible"

jq -r '.[]
    | if .eligible then "  " else "  SKIP " end
      + "#\(.number)  \(.status)  \(.title)"
      + (if .eligible then ""
         elif (.blockers | length) > 0 then "  [blocked by \((.blockers | map("#" + tostring) | join(", ")))]"
         else "  [\(.blockerTotal) blockers, only \(.blockerRead) read; treat as blocked]"
         end)' <<< "$selection"

((eligible > 0)) ||
    printf 'every candidate is blocked; nothing is eligible to start\n'
exit 0
