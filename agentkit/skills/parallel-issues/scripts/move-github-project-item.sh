#!/usr/bin/env bash
set -euo pipefail

# gh paginates these listings at 30 by default. Every lookup below must be able to
# see the whole board, or a card past the default page is indistinguishable from a
# card that is not on the board at all -- a silent no-op that still exits 0.
readonly ITEM_LIMIT=1000
readonly FIELD_LIMIT=100
readonly PROJECT_LIMIT=100

usage() {
    printf 'Usage: %s --issue-number N --status STATUS --repository OWNER/REPO [--all-boards]\n' "${0##*/}"
    cat <<'EOF'

Sets the Status field of an issue's card on the GitHub Project board(s) that
issue belongs to, and reports on stdout what it did.

Options:
  --issue-number N          Issue number, a positive integer (e.g. 42).
  --status STATUS           One of the canonical board columns:
                            'Backlog', 'Ready', 'In progress', 'In review', 'Done'.
                            Matched against the board's own options case-insensitively.
  --repository OWNER/REPO   Repository holding the issue (e.g. OWNER/REPO). Also
                            selects the card: boards shared across an org can hold
                            several issues numbered #N, one per repository.
  --repo-root DIR           Repository root holding .agent/ (default: git toplevel
                            of the cwd). A warm .agent/board.json plus
                            .agent/cache/board-items.json is refreshed after a
                            successful move, but live IDs are always validated
                            before mutation.
  --all-boards              Walk EVERY project the issue is on: keep going after
                            a successful move, and keep going past a board that
                            has no Status field or no matching Status option.
                            One output line is printed per such board.
  -h, --help                Print this help and exit 0.

Without --all-boards (the default) the run stops at the first board that is
successfully updated, and also stops at the first board that has no Status field
or no matching Status option.

Output (stdout carries only these lines):
  moved #42 -> "In review" on project #3 "Example Board"
  no-op: issue #42 is not on any project board
  no-op: project #3 "Example Board" has no Status field
  no-op: project #3 "Example Board" has no matching Status option "In review"

Exit status: 0 on a move or a no-op, 1 on bad arguments or an API error.
EOF
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

issue_number=
status=
repository=
repo_root=
all_boards=0

while (($#)); do
    case $1 in
        --issue-number)
            (($# >= 2)) || die "Missing value for $1."
            issue_number=$2
            shift 2
            ;;
        --status)
            (($# >= 2)) || die "Missing value for $1."
            status=$2
            shift 2
            ;;
        --repository)
            (($# >= 2)) || die "Missing value for $1."
            repository=$2
            shift 2
            ;;
        --repo-root)
            (($# >= 2)) || die "Missing value for $1."
            repo_root=$2
            shift 2
            ;;
        --all-boards)
            all_boards=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1."
            ;;
    esac
done

[[ $issue_number =~ ^[1-9][0-9]*$ ]] || die 'Issue number must be a positive integer.'
[[ $repository =~ ^[^/]+/[^/]+$ ]] || die 'Repository must have the form OWNER/REPO.'

owner=${repository%%/*}

# ---------------------------------------------------------------- .agent/ ---
# Static board facts a repository declared for itself. Every lookup below
# returns non-zero on ANY doubt -- missing file, unparseable JSON, unknown
# schemaVersion, or a cache built against a different board -- and the caller
# then discovers exactly as it always has.
readonly BOARD_SCHEMA_VERSION=1

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
board_file=
items_file=
if [[ -n $repo_root ]]; then
    board_file="$repo_root/.agent/board.json"
    items_file="$repo_root/.agent/cache/board-items.json"
fi

board_readable() {
    [[ -n $board_file && -r $board_file ]] || return 1
    jq -e --argjson v "$BOARD_SCHEMA_VERSION" '.schemaVersion == $v' \
        <"$board_file" >/dev/null 2>&1
}

# Prints the option id for a status name, matched case-insensitively so the
# board's own capitalisation wins over the caller's.
board_option_id() {
    local want=$1
    board_readable || return 1
    jq -er --arg s "$want" '
        first(.statusField.options | to_entries[]
              | select((.key | ascii_downcase) == ($s | ascii_downcase))
              | .value) // empty' <"$board_file" 2>/dev/null
}

# Status is validated BEFORE any network call: a typo must never reach the API.
# The canonical five always pass; a board that declares its own column names
# passes those too, so a non-canonical board is usable without editing this file.
status_is_valid() {
    case $status in
        'Backlog' | 'Ready' | 'In progress' | 'In review' | 'Done') return 0 ;;
    esac
    [[ -n $(board_option_id "$status" || true) ]]
}
status_is_valid || die \
    "Status must be 'Backlog', 'Ready', 'In progress', 'In review', 'Done', or a column declared in .agent/board.json."

# Merge one issue -> item mapping into the cache, scoped to its board. Written
# temp-then-move so a concurrent reader never sees a half-written file.
cache_item_id() {
    local project_id=$1 issue=$2 item=$3 existing='{}' staged
    [[ -n $items_file && -n $project_id && -n $item ]] || return 0
    mkdir -p -- "$(dirname -- "$items_file")" 2>/dev/null || return 0
    if [[ -r $items_file ]]; then
        existing=$(jq -c --arg p "$project_id" \
            'if (.project == $p and .schemaVersion == 1) then (.items // {}) else {} end' \
            <"$items_file" 2>/dev/null || printf '{}')
    fi
    staged=$(mktemp "$(dirname -- "$items_file")/.items.XXXXXX") || return 0
    if jq -n --argjson v "$BOARD_SCHEMA_VERSION" --arg p "$project_id" \
        --argjson items "${existing:-\{\}}" --arg n "$issue" --arg id "$item" \
        '{schemaVersion: $v, project: $p, items: ($items + {($n): $id})}' \
        >"$staged" 2>/dev/null; then
        mv -- "$staged" "$items_file"
    else
        rm -f -- "$staged"
    fi
}

# Match on issue number AND repository. Project v2 boards are routinely shared
# across every repo in an org, so number alone can select another repo's #N and
# mutate an unrelated card. .content.repository is a URL on some gh versions and
# OWNER/REPO on others; accept either, and fall back to .content.url.
select_item_id() {
    jq -r --argjson issue_number "$issue_number" --arg repository "$repository" '
        first(
            .items[]?
            | select(
                .content.number == $issue_number
                and (
                    ((.content.repository // "") | type == "string" and
                        ((ascii_downcase | rtrimstr("/")) == ($repository | ascii_downcase)
                         or (ascii_downcase | rtrimstr("/")) ==
                            ("https://github.com/" + ($repository | ascii_downcase))))
                    or ((.content.url // "") | type == "string" and
                        (ascii_downcase
                         | sub("^https?://[^/]+/"; "")
                         | startswith(($repository | ascii_downcase) + "/")))
                )
            )
            | .id
        ) // empty' <<< "$1"
}

# board.json names the project, but its IDs are repository-controlled hints, not
# authority. Rebind every ID against the live project before editing. This is
# still cheaper than walking every board the owner has on a fresh clone, while
# preventing a forged board or item cache from selecting an unrelated card.
# Returns 0 moved, 1 cannot use this path, 2 the API rejected the edit.
try_known_board() {
    local project_number project_id project_title field_id option_id items_json item_id
    local project_owner project_json live_project_id fields_json

    board_readable || return 1
    project_number=$(jq -r '.project.number // empty' <"$board_file" 2>/dev/null) || return 1
    project_id=$(jq -r '.project.id // empty' <"$board_file" 2>/dev/null) || return 1
    project_title=$(jq -r '.project.title // "?"' <"$board_file" 2>/dev/null) || return 1
    field_id=$(jq -r '.statusField.id // empty' <"$board_file" 2>/dev/null) || return 1
    option_id=$(board_option_id "$status") || return 1
    [[ -n $project_number && -n $project_id && -n $field_id && -n $option_id ]] || return 1

    project_owner=$(jq -r '.owner // empty' <"$board_file" 2>/dev/null) || return 1
    [[ -n $project_owner ]] || project_owner=$owner

    project_json=$(gh project view "$project_number" --owner "$project_owner" \
        --format json 2>/dev/null) || return 1
    live_project_id=$(jq -r '.id // empty' <<< "$project_json" 2>/dev/null) || return 1
    [[ -n $live_project_id && $live_project_id == "$project_id" ]] || return 1

    items_json=$(gh project item-list "$project_number" --owner "$project_owner" \
        --limit "$ITEM_LIMIT" --format json 2>/dev/null) || return 1
    [[ -n $items_json ]] || return 1
    item_id=$(select_item_id "$items_json")
    [[ -n $item_id ]] || return 1

    # Field and option IDs are also rebound live. board.json is useful for
    # validating a status before network access, but must not supply mutation
    # IDs after a branch has changed the board.
    fields_json=$(gh project field-list "$project_number" --owner "$project_owner" \
        --limit "$FIELD_LIMIT" --format json 2>/dev/null) || return 1
    field_id=$(jq -r \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .id) // empty' \
        <<< "$fields_json")
    option_id=$(jq -r --arg status "$status" \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .options[]?
         | select((.name | ascii_downcase) == ($status | ascii_downcase)) | .id) // empty' \
        <<< "$fields_json")
    [[ -n $field_id && -n $option_id ]] || return 1

    gh project item-edit \
        --id "$item_id" \
        --project-id "$project_id" \
        --field-id "$field_id" \
        --single-select-option-id "$option_id" >/dev/null 2>&1 || return 2

    cache_item_id "$project_id" "$issue_number" "$item_id"
    printf 'moved #%s -> "%s" on project #%s "%s" (board.json, 4 calls)\n' \
        "$issue_number" "$status" "$project_number" "$project_title"
    return 0
}

known_rc=0
try_known_board || known_rc=$?
if ((known_rc == 0)); then
    exit 0
fi
if ((known_rc == 2)); then
    # Exactly one retry, via the full discovery path below. A second rejection
    # is a real error and must surface rather than be papered over by a loop.
    printf 'board changed - the declared ids were rejected; rediscovering once\n' >&2
    printf 'board changed - commit the regenerated .agent/board.json\n' >&2
fi

# Handles one project board. Prints its own stdout line, except when the issue
# simply is not on this board (nothing to report for that case).
# Returns: 0 moved, 3 issue not on this board, 4 no-op reported for this board.
process_project() {
    local project_number=$1 project_id=$2 project_title=$3
    local items_json item_id fields_json status_field_id option_id

    # --limit is mandatory: gh defaults to 30 items, so on any real board the target
    # card is silently absent and this would report "not on any board" while exiting 0.
    if ! items_json=$(gh project item-list "$project_number" --owner "$owner" \
        --limit "$ITEM_LIMIT" --format json 2>/dev/null); then
        printf 'Warning: could not list items for project #%s; skipping it.\n' "$project_number" >&2
        return 3
    fi
    [[ -n $items_json ]] || return 3

    # Match on issue number AND repository. Project v2 boards are routinely shared
    # across every repo in an org, so number alone can select another repo's #N and
    # mutate an unrelated card. .content.repository is a URL on some gh versions and
    # OWNER/REPO on others; accept either, and fall back to .content.url.
    item_id=$(select_item_id "$items_json")
    [[ -n $item_id ]] || return 3

    if ! fields_json=$(gh project field-list "$project_number" --owner "$owner" \
        --limit "$FIELD_LIMIT" --format json); then
        die "Could not list fields for project #$project_number."
    fi

    status_field_id=$(jq -r \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .id) // empty' \
        <<< "$fields_json")
    if [[ -z $status_field_id ]]; then
        printf 'no-op: project #%s "%s" has no Status field\n' "$project_number" "$project_title"
        return 4
    fi

    option_id=$(jq -r --arg status "$status" \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .options[]? | select((.name | ascii_downcase) == ($status | ascii_downcase)) | .id) // empty' \
        <<< "$fields_json")
    if [[ -z $option_id ]]; then
        printf 'no-op: project #%s "%s" has no matching Status option "%s"\n' \
            "$project_number" "$project_title" "$status"
        return 4
    fi

    if ! gh project item-edit \
        --id "$item_id" \
        --project-id "$project_id" \
        --field-id "$status_field_id" \
        --single-select-option-id "$option_id" >/dev/null; then
        die "Could not move issue #$issue_number to '$status'."
    fi

    # Refresh the cache for diagnostics and future discovery, but never use it
    # as authority for a later mutation.
    cache_item_id "$project_id" "$issue_number" "$item_id"

    printf 'moved #%s -> "%s" on project #%s "%s"\n' \
        "$issue_number" "$status" "$project_number" "$project_title"
    return 0
}

if ! projects_json=$(gh project list --owner "$owner" \
    --limit "$PROJECT_LIMIT" --format json 2>/dev/null); then
    printf 'no-op: could not list projects for owner %s (gh may need the project scope)\n' "$owner"
    exit 0
fi
if [[ -z $projects_json ]]; then
    printf 'no-op: issue #%s is not on any project board\n' "$issue_number"
    exit 0
fi

found_on_board=0
while IFS=$'\t' read -r project_number project_id project_title; do
    [[ -n $project_number && -n $project_id ]] || continue
    [[ -n $project_title ]] || project_title='(untitled)'

    board_rc=0
    process_project "$project_number" "$project_id" "$project_title" || board_rc=$?
    if ((board_rc == 3)); then
        continue
    fi

    found_on_board=1
    if ((all_boards == 0)); then
        exit 0
    fi
done < <(jq -r '.projects[]? | [.number, .id, (.title // "")] | @tsv' <<< "$projects_json")

if ((found_on_board == 0)); then
    printf 'no-op: issue #%s is not on any project board\n' "$issue_number"
fi
