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
ARG_LIMIT=200
ARG_STATUS=""
ARG_JSON=0

usage() {
    cat << 'EOF'
board-list.sh -- Project board contents grouped by status, in a single call.

Usage:
  board-list.sh [--repo-root DIR] [--status NAME] [--limit N] [--json]

Options:
  --repo-root DIR  Repository to read .agent/board.json from (default: cwd).
  --status NAME    Only this column, e.g. --status Ready.
  --limit N        Items to request (default 200).
  --json           Emit the normalised records instead of the table.

Reads the project number and owner from .agent/board.json, so it never
rediscovers the board. Exit 0 on success, 1 on a failed call, 2 on usage,
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
[[ -n $number && -n $owner ]] ||
    die_blocked '.agent/board.json declares no project number or owner'

raw=$(gh project item-list "$number" --owner "$owner" --format json --limit "$ARG_LIMIT" 2>&1) ||
    die "gh project item-list failed: $(head -1 <<< "$raw")"

# Normalise once. A board holds draft items and pull requests as well as issues,
# and every one of them has a status worth reporting -- filtering to issues here
# is what would send the agent back to the raw API for the rest.
records=$(jq -c --arg want "$ARG_STATUS" '
    [ .items[]?
      | { status: (.status // "(no status)"),
          number: (.content.number // null),
          type:   (.content.type // "Item"),
          title:  (.title // .content.title // "(untitled)") }
    ]
    | map(select($want == "" or .status == $want))
' <<< "$raw" 2> /dev/null) || die 'could not parse the board response'

if ((ARG_JSON)); then
    printf '%s\n' "$records"
    exit 0
fi

total=$(jq -r 'length' <<< "$records")
printf 'board= project=%s owner=%s items=%s calls=1%s\n\n' \
    "$number" "$owner" "$total" "${ARG_STATUS:+ status=$ARG_STATUS}"

# Grouped, most-active first: a board is read to find what to pick up next, and
# Done is the least interesting column for that.
jq -r '
    group_by(.status)
    | map({status: .[0].status, items: .})
    | sort_by([
        # The status must be bound BEFORE the pipe: inside `[...] | index(...)`
        # the dot is the literal array, so `.status` indexes an array by string.
        (.status as $s | (["In progress","In review","Ready","Backlog"] | index($s)) // 98),
        .status
      ])
    | .[]
    | "\(.status)  (\(.items | length))",
      (.items[] | "  \(if .number then "#\(.number)" else "-" end)  \(.title)"),
      ""
' <<< "$records"
