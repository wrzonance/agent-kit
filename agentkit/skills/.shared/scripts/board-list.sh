#!/usr/bin/env bash
#
# board-list.sh -- what is on the Project board, grouped by status, in one call.
#
# `triage-issues.sh` answers a different question: which OPEN ISSUES exist and
# what their board status is. Asked "what is on the board", an agent that had
# just been pointed at it ignored the advice -- correctly, because the board
# also holds Done and non-issue items the digest never reports.
#
# So it went to the raw API and spent three calls converging on a format, one of
# which returned nine hundred lines of JSON into its context. That is the waste
# this replaces: one call, one compact table, no JSON to wade through.
#
# Reports, never blocks. Exit 3 means the environment is not ready (no gh, no
# board declared); exit 1 means the call failed.
set -uo pipefail

PROGRAM=${0##*/}
ARG_REPO_ROOT=""
# 1000, not 200. A 230-item board answered through a 200-item window reported
# "157 Done" while the API said the board held 230 -- a count that cannot be
# reconciled with itself, and an agent that noticed spent six further calls
# trying to. The sibling mover already carries this lesson in a comment; this
# script was written later and did not inherit it.
ARG_LIMIT=1000
ARG_STATUS=""
ARG_ISSUE=""
ARG_ALL=0
ARG_JSON=0

usage() {
    cat << 'EOF'
board-list.sh -- Project board contents grouped by status, in a single call.

Usage:
  board-list.sh [--repo-root DIR] [--status NAME] [--issue N] [--limit N]
                [--all] [--json]

Options:
  --repo-root DIR  Repository to read .agent/board.json from (default: cwd).
  --status NAME    Only this column, e.g. --status Ready.
  --issue N        Where is issue N right now? One call, one line. Use this
                   to confirm a move instead of re-querying the whole board.
  --limit N        Items to request (default 1000).
  --all            List Done items individually instead of as a count.
  --json           Emit the normalised records instead of the table.

Reads the project number and owner from .agent/board.json, so it never
rediscovers the board. Issue lookups are additionally bound to the repository
declared by the target checkout. Exit 0 on success, 1 on a failed call, 2 on usage,
3 when the environment cannot support the query.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}
die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    usage >&2
    exit 2
}
die_blocked() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 3
}

while (($#)); do
    case $1 in
        --repo-root)
            [[ ${2:-} ]] || die_usage '--repo-root requires a value'
            ARG_REPO_ROOT=$2
            shift 2
            ;;
        --status)
            [[ ${2:-} ]] || die_usage '--status requires a value'
            ARG_STATUS=$2
            shift 2
            ;;
        --issue)
            [[ ${2:-} =~ ^#?[0-9]{1,9}$ ]] || die_usage '--issue requires an issue number'
            ARG_ISSUE=${2#\#}
            shift 2
            ;;
        --all) ARG_ALL=1 && shift ;;
        --limit)
            [[ ${2:-} =~ ^[0-9]{1,4}$ ]] || die_usage '--limit requires a number'
            ARG_LIMIT=$2
            shift 2
            ;;
        --json) ARG_JSON=1 && shift ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

for tool in gh jq; do
    command -v "$tool" > /dev/null 2>&1 || die_blocked "$tool is not installed"
done

repo_root=${ARG_REPO_ROOT:-$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")}
board="$repo_root/.agent/board.json"
[[ -r $board ]] ||
    die_blocked "no .agent/board.json in $repo_root; run bootstrap-repo.sh first"

number=$(jq -r '.project.number // empty' "$board" 2> /dev/null || true)
owner=$(jq -r '.owner // empty' "$board" 2> /dev/null || true)
board_title=$(jq -r '.project.title // empty' "$board" 2> /dev/null || true)
[[ -n $number && -n $owner ]] ||
    die_blocked '.agent/board.json declares no project number or owner'

raw=$(gh project item-list "$number" --owner "$owner" --format json --limit "$ARG_LIMIT" 2>&1) ||
    die "gh project item-list failed: $(head -1 <<< "$raw")"

# Normalise once. A board holds draft items and pull requests as well as issues,
# and every one of them has a status worth reporting -- filtering to issues here
# is what would send the agent back to the raw API for the rest.
all_records=$(jq -c '
    [ .items[]?
      | { status: (.status // "(no status)"),
          number: (.content.number // null),
          type:   (.content.type // "Item"),
          title:  (.title // .content.title // "(untitled)"),
          repository: (
            (.content.repository // "") as $repo
            | if ($repo | type) == "string" and $repo != "" then
                ($repo | sub("^https?://[^/]+/"; "") | rtrimstr("/"))
              elif ((.content.url // "") | type) == "string" and ((.content.url // "") != "") then
                ((.content.url | capture("github\\.com/(?<slug>[^/#?]+/[^/#?]+)").slug)
                 // null)
              else null end
            | if . == null then null else ascii_downcase end
          ) }
    ]
' <<< "$raw" 2> /dev/null) || die 'could not parse the board response'

# The API reports how many items the board HAS, separately from how many it
# returned. Comparing them is the difference between "8 items are Ready" and
# "8 of the items I happened to fetch are Ready" -- and only the second is what
# a truncated window can support. Answering the wrong one silently is how a
# reader ends up unable to reconcile the numbers, which is worse than a slow
# answer because it looks like a fact.
declared_total=$(jq -r '.totalCount // empty' <<< "$raw" 2> /dev/null || true)
fetched=$(jq -r 'length' <<< "$all_records")
truncated=0
[[ -n $declared_total ]] && ((fetched < declared_total)) && truncated=1

# "Where is #300 now?" -- the question asked after every move, and the one that
# used to require fetching the whole board and hand-writing a jq filter. Each
# hand-written filter differs slightly from the last, so the answers look like
# they disagree, and the natural response to answers that disagree is to ask
# again. One call, one stable line, ends that.
if [[ -n $ARG_ISSUE ]]; then
    repository=''
    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    resolver="$script_dir/repo-config.sh"
    if [[ -x $resolver ]]; then
        repository=$("$resolver" \
            --repo-root "$repo_root" --get AGENT_REPO_SLUG 2>/dev/null || true)
    fi
    if [[ -z $repository ]]; then
        if ! repository=$(cd -- "$repo_root" && gh repo view --json nameWithOwner -q .nameWithOwner \
            2>/dev/null); then
            repository=''
        fi
    fi
    [[ $repository =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        repository=''
    repository_lc=${repository,,}
    [[ -n $repository_lc ]] ||
        die_blocked 'cannot resolve the repository for an issue lookup'
    ((truncated == 0)) || printf 'warning: read %s of %s items; a miss below may be truncation, not absence\n' \
        "$fetched" "$declared_total" >&2
    hit=$(jq -r --argjson n "$ARG_ISSUE" --arg repo "$repository_lc" '
        map(select(.number == $n and .repository == $repo)) | .[0]
        | if . == null then "" else "#\(.number)  \(.status)  \(.title)" end
    ' <<< "$all_records" 2> /dev/null)
    if [[ -n $hit ]]; then
        printf 'board= project=%s owner=%s calls=1\n%s\n' "$number" "$owner" "$hit"
    else
        printf 'board= project=%s owner=%s calls=1\n#%s is not on this board\n' \
            "$number" "$owner" "$ARG_ISSUE"
    fi
    exit 0
fi

records=$(jq -c --arg want "$ARG_STATUS" \
    'map(select($want == "" or .status == $want))' <<< "$all_records" 2> /dev/null) ||
    die 'could not filter the board response'

if ((ARG_JSON)); then
    printf '%s\n' "$records"
    exit 0
fi

total=$(jq -r 'length' <<< "$records")
printf 'board=%s project=%s owner=%s items=%s of=%s calls=1%s\n' \
    "$board_title" "$number" "$owner" "$total" "${declared_total:-$fetched}" \
    "${ARG_STATUS:+ status=$ARG_STATUS}"
if ((truncated)); then
    printf 'TRUNCATED: read %s of %s items. Every count below is a count of what\n' \
        "$fetched" "$declared_total"
    printf 'was read, not of what the board holds. Re-run with --limit %s.\n' \
        "$((declared_total + 100))"
fi
printf '\n'

# Grouped, most-active first: a board is read to find what to pick up next, and
# Done is the least interesting column for that.
#
# Done is collapsed to a count unless it is what was asked for. On a real board
# it is the overwhelming majority -- 184 of 230 on the board this was measured
# against -- and printing it in full buries the four columns someone reading
# "what should I pick up next" actually came for.
collapse='["Done","Closed","Cancelled","Canceled"]'
((ARG_ALL == 0)) && [[ -z $ARG_STATUS ]] || collapse='[]'

jq -r --argjson collapse "$collapse" '
    group_by(.status)
    | map({status: .[0].status, items: .})
    | sort_by([
        # The status must be bound BEFORE the pipe: inside `[...] | index(...)`
        # the dot is the literal array, so `.status` indexes an array by string.
        (.status as $s | (["In progress","In review","Ready","Backlog"] | index($s)) // 98),
        .status
      ])
    | .[]
    | if (.status as $s | $collapse | index($s)) then
          "\(.status)  (\(.items | length))",
          "  (not listed; re-run with --status \(.status) to see them)",
          ""
      else
          "\(.status)  (\(.items | length))",
          (.items[] | "  \(if .number then "#\(.number)" else "-" end)  \(.title)"),
          ""
      end
' <<< "$records"
