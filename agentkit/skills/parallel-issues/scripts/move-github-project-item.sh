#!/usr/bin/env bash
set -euo pipefail

# gh paginates these listings at 30 by default. Every lookup below must be able to
# see the whole board, or a card past the default page is indistinguishable from a
# card that is not on the board at all -- a silent no-op that still exits 0.
readonly ITEM_LIMIT=1000
readonly FIELD_LIMIT=100
readonly PROJECT_LIMIT=100

usage() {
    printf 'Usage: %s --issue-number N [--issue-number N ...] --status STATUS --repository OWNER/REPO [--all-boards]\n' "${0##*/}"
    printf '       %s --issue-numbers N,N,... --status STATUS --repository OWNER/REPO [--all-boards]\n' "${0##*/}"
    cat <<'EOF'

Sets the Status field of an issue's card on the GitHub Project board(s) that
issue belongs to, and reports on stdout what it did.

Options:
  --issue-number N          Issue number, repeatable (e.g. 42).
  --issue-numbers N,N,...   Comma-separated issue numbers (may be repeated).
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

issue_numbers=()
status=
repository=
repo_root=
all_boards=0

add_issue_number() {
    local number=$1
    [[ $number =~ ^[1-9][0-9]*$ ]] || die 'Issue number must be a positive integer.'
    issue_numbers+=("$number")
}

add_issue_numbers() {
    local csv=$1 number
    [[ $csv =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] ||
        die 'Issue numbers must be a comma-separated list of positive integers.'
    local -a numbers=()
    IFS=',' read -ra numbers <<< "$csv"
    for number in "${numbers[@]}"; do
        add_issue_number "$number"
    done
}

while (($#)); do
    case $1 in
        --issue-number)
            (($# >= 2)) || die "Missing value for $1."
            add_issue_number "$2"
            shift 2
            ;;
        --issue-numbers)
            (($# >= 2)) || die "Missing value for $1."
            add_issue_numbers "$2"
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

(( ${#issue_numbers[@]} > 0 )) || die 'At least one issue number is required.'
[[ $repository =~ ^[^/]+/[^/]+$ ]] || die 'Repository must have the form OWNER/REPO.'

declare -a requested_issues=()
declare -A requested_seen=()
for issue_number in "${issue_numbers[@]}"; do
    [[ ${requested_seen[$issue_number]+yes} == yes ]] && continue
    requested_seen[$issue_number]=1
    requested_issues+=("$issue_number")
done
issue_numbers=("${requested_issues[@]}")
declare -A completed_issues=()

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

# Rebuild the declared board metadata from the live project and Status field.
# The temporary file lives beside board.json, so mv makes the refresh atomic.
refresh_board_metadata() {
    local board_owner=$1 project_number=$2 project_id=$3 project_title=$4 fields_json=$5
    local status_field field_id options fingerprint_input fingerprint generated_at staged
    local staged_substantive existing_substantive

    [[ -n $board_file ]] || return 0
    status_field=$(jq -c 'first(.fields[]? | select((.name | ascii_downcase) == "status")) // empty' \
        <<< "$fields_json") || return 1
    field_id=$(jq -r '.id // empty' <<< "$status_field") || return 1
    options=$(jq -c '[.options[]? | {key: .name, value: .id}] | from_entries' \
        <<< "$status_field") || return 1
    [[ -n $field_id && $options != '{}' ]] || return 1

    fingerprint_input=$(jq -S -c -n --arg project "$project_id" --arg field "$field_id" \
        --argjson options "$options" \
        '{p: $project, f: $field, o: ($options | to_entries | sort_by(.key) | map(.value))}') || return 1
    fingerprint="sha256:$(printf '%s' "$fingerprint_input" | sha256sum | cut -d' ' -f1)"
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    staged=$(mktemp "$(dirname -- "$board_file")/.board.XXXXXX") || return 1

    if ! jq -n --argjson version "$BOARD_SCHEMA_VERSION" --arg owner "$board_owner" \
        --argjson number "$project_number" --arg project "$project_id" --arg title "$project_title" \
        --arg field "$field_id" --argjson options "$options" --arg fingerprint "$fingerprint" \
        --arg generated_at "$generated_at" \
        '{schemaVersion: $version, owner: $owner,
          project: {number: $number, id: $project, title: $title},
          statusField: {id: $field, name: "Status", options: $options},
          generatedAt: $generated_at, fingerprint: $fingerprint}' > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi
    staged_substantive=$(jq -S -c 'del(.generatedAt)' <"$staged") || {
        rm -f -- "$staged"
        return 1
    }
    if [[ -r $board_file ]] &&
        existing_substantive=$(jq -S -c 'del(.generatedAt)' <"$board_file" 2>/dev/null); then
        if [[ $staged_substantive == "$existing_substantive" ]]; then
            rm -f -- "$staged"
            return 0
        fi
    fi
    mv -- "$staged" "$board_file"
}

# Match on issue number AND repository. Project v2 boards are routinely shared
# across every repo in an org, so number alone can select another repo's #N and
# mutate an unrelated card. .content.repository is a URL on some gh versions and
# OWNER/REPO on others; accept either, and fall back to .content.url.
select_item_id() {
    local issue_number=$1 items_json=$2
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
        ) // empty' <<< "$items_json"
}

# Return the live Status value for an item when the CLI includes field values.
# Older gh versions omit it; an empty result deliberately preserves the existing
# move behavior rather than guessing that a card is already at the target.
select_item_status() {
    local item_id=$1 items_json=$2
    jq -r --arg item_id "$item_id" '
        first(
            .items[]?
            | select(.id == $item_id)
            | (
                .status
                // (
                    (.fieldValues? // null) as $values
                    | (if ($values | type) == "object" then ($values.nodes? // [])
                       elif ($values | type) == "array" then $values
                       else [] end)[]?
                    | select(((.field.name // .name // "") | ascii_downcase) == "status")
                    | (.name // .value.name // .value.text // .value // empty)
                    | select(type == "string"))
            )
        ) // empty' <<< "$items_json"
}

# board.json names the project, but its IDs are repository-controlled hints, not
# authority. Rebind every ID against the live project before editing. This is
# still cheaper than walking every board the owner has on a fresh clone, while
# preventing a forged board or item cache from selecting an unrelated card.
# Returns 0 moved, 1 cannot use this path, 2 the API rejected the edit.
try_known_board() {
    local project_number project_id project_title field_id option_id items_json item_id issue_number
    local project_owner project_json live_project_id live_project_title fields_json

    # The cached board is a single-board acceleration.  It cannot satisfy the
    # --all-boards contract, which must enumerate every board the owner has.
    ((all_boards == 0)) || return 1
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
    live_project_title=$(jq -r '.title // empty' <<< "$project_json" 2>/dev/null) || return 1
    [[ -n $live_project_title ]] || live_project_title=$project_title

    items_json=$(gh project item-list "$project_number" --owner "$project_owner" \
        --limit "$ITEM_LIMIT" --format json 2>/dev/null) || return 1
    [[ -n $items_json ]] || return 1
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

    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
        item_id=$(select_item_id "$issue_number" "$items_json")
        [[ -n $item_id ]] || continue
        current_status=$(select_item_status "$item_id" "$items_json")
        if [[ -n $current_status && $current_status == "$status" ]]; then
            printf 'no-op: issue #%s already "%s"\n' "$issue_number" "$current_status"
            completed_issues[$issue_number]=1
            continue
        fi
        gh project item-edit \
            --id "$item_id" \
            --project-id "$project_id" \
            --field-id "$field_id" \
            --single-select-option-id "$option_id" >/dev/null 2>&1 || return 2
        cache_item_id "$project_id" "$issue_number" "$item_id"
        completed_issues[$issue_number]=1
        printf 'moved #%s -> "%s" on project #%s "%s" (board.json, 4 calls)\n' \
            "$issue_number" "$status" "$project_number" "$project_title"
    done
    if ((${#completed_issues[@]} > 0)); then
        if ! refresh_board_metadata "$project_owner" "$project_number" "$live_project_id" \
            "$live_project_title" "$fields_json"; then
            printf 'Warning: moved issue but could not refresh .agent/board.json\n' >&2
        fi
    fi
    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] || return 1
    done
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
    local items_json item_id current_status fields_json status_field_id option_id issue_number

    # --limit is mandatory: gh defaults to 30 items, so on any real board the target
    # card is silently absent and this would report "not on any board" while exiting 0.
    if ! items_json=$(gh project item-list "$project_number" --owner "$owner" \
        --limit "$ITEM_LIMIT" --format json 2>/dev/null); then
        printf 'Warning: could not list items for project #%s; skipping it.\n' \
            "$project_number" >&2
        return 3
    fi
    [[ -n $items_json ]] || return 3

    local -a board_issues=()
    for issue_number in "${issue_numbers[@]}"; do
        ((all_boards == 0)) && [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
        item_id=$(select_item_id "$issue_number" "$items_json")
        [[ -n $item_id ]] || continue
        board_issues+=("$issue_number")
    done
    ((${#board_issues[@]} > 0)) || return 3

    if ! fields_json=$(gh project field-list "$project_number" --owner "$owner" \
        --limit "$FIELD_LIMIT" --format json); then
        die "Could not list fields for project #$project_number."
    fi

    status_field_id=$(jq -r \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .id) // empty' \
        <<< "$fields_json")
    if [[ -z $status_field_id ]]; then
        for issue_number in "${board_issues[@]}"; do
            printf 'no-op: project #%s "%s" has no Status field\n' \
                "$project_number" "$project_title"
            completed_issues[$issue_number]=1
        done
        return 4
    fi

    option_id=$(jq -r --arg status "$status" \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .options[]? | select((.name | ascii_downcase) == ($status | ascii_downcase)) | .id) // empty' \
        <<< "$fields_json")
    if [[ -z $option_id ]]; then
        for issue_number in "${board_issues[@]}"; do
            printf 'no-op: project #%s "%s" has no matching Status option "%s"\n' \
                "$project_number" "$project_title" "$status"
            completed_issues[$issue_number]=1
        done
        return 4
    fi

    for issue_number in "${board_issues[@]}"; do
        item_id=$(select_item_id "$issue_number" "$items_json")
        current_status=$(select_item_status "$item_id" "$items_json")
        if [[ -n $current_status && $current_status == "$status" ]]; then
            printf 'no-op: issue #%s already "%s"\n' "$issue_number" "$current_status"
            completed_issues[$issue_number]=1
            continue
        fi
        if ! gh project item-edit \
            --id "$item_id" \
            --project-id "$project_id" \
            --field-id "$status_field_id" \
            --single-select-option-id "$option_id" >/dev/null; then
            die "Could not move issue #$issue_number to '$status'."
        fi
        cache_item_id "$project_id" "$issue_number" "$item_id"
        completed_issues[$issue_number]=1
        printf 'moved #%s -> "%s" on project #%s "%s"\n' \
            "$issue_number" "$status" "$project_number" "$project_title"
    done

    if ! refresh_board_metadata "$owner" "$project_number" "$project_id" "$project_title" \
        "$fields_json"; then
        printf 'Warning: moved issue but could not refresh .agent/board.json\n' >&2
    fi
    return 0
}

if ! projects_json=$(gh project list --owner "$owner" \
    --limit "$PROJECT_LIMIT" --format json 2>/dev/null); then
    die "Could not list projects for owner $owner."
fi
if [[ -z $projects_json ]]; then
    for issue_number in "${issue_numbers[@]}"; do
        printf 'no-op: issue #%s is not on any project board\n' "$issue_number"
    done
    exit 0
fi

while IFS=$'\t' read -r project_number project_id project_title; do
    [[ -n $project_number && -n $project_id ]] || continue
    [[ -n $project_title ]] || project_title='(untitled)'

    board_rc=0
    process_project "$project_number" "$project_id" "$project_title" || board_rc=$?
    ((board_rc == 3)) && continue

    if ((all_boards == 0)); then
        all_complete=1
        for issue_number in "${issue_numbers[@]}"; do
            [[ ${completed_issues[$issue_number]+yes} == yes ]] || { all_complete=0; break; }
        done
        ((all_complete == 1)) && break
    fi
done < <(jq -r '.projects[]? | [.number, .id, (.title // "")] | @tsv' <<< "$projects_json")

for issue_number in "${issue_numbers[@]}"; do
    [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
    printf 'no-op: issue #%s is not on any project board\n' "$issue_number"
done
