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
                            .agent/cache/board-items.json performs the mutation
                            directly when both trusted caches match this repo;
                            a cache miss reads that one declared board before
                            editing and refreshes the item cache.
  --all-boards              Walk EVERY project the issue is on: keep going after
                            a successful move, and keep going past a board that
                            has no Status field or no matching Status option.
                            One output line is printed per such board.
  -h, --help                Print this help and exit 0.

Without --all-boards (the default) the run stops at the first board that is
successfully updated, and also stops at the first board that has no Status field
or no matching Status option.

Output (stdout carries only these lines):
  moved #42 -> "In review" on project #3 "Example Board" (board.json, 1 call)
  moved #42 -> "In review" on project #3 "Example Board" (board.json, 2 calls)
  no-op: issue #42 is not on any project board
  no-op: project #3 "Example Board" has no Status field
  no-op: project #3 "Example Board" has no matching Status option "In review"
  moved=1 no-op=0 of=1

Successful runs end with a summary of terminal evidence lines. Compare its
`of` count with the captured issue-result lines to detect truncated output.

The "(board.json, 1 call)" warm path deliberately skips reading the card's
current status before mutating it -- that read is the API call this path
exists to avoid. So it reports "moved" even when the card was already in the
target status; only the slower paths can report the "already" no-op above.
Callers must treat "moved" as covering both "moved" and "already there".

Exit status: 0 on a move or a no-op, 1 on bad arguments or an API error.
EOF
}

die() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

moved_count=0
noop_count=0

report_moved() {
    moved_count=$((moved_count + 1))
    printf '%s\n' "$1"
}

report_noop() {
    noop_count=$((noop_count + 1))
    printf '%s\n' "$1"
}

# Keep the documented terminal shape: no-op: issue #%s already "%s".

report_summary() {
    printf 'moved=%d no-op=%d of=%d\n' "$moved_count" "$noop_count" \
        "$((moved_count + noop_count))"
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
repository_name=${repository#*/}
cached_mutation_rejected=0

# Query the issue's own project memberships instead of enumerating every
# project in the organization. --paginate follows projectItems connections
# past the first page; jq -s combines the page responses into one item array.
issue_project_items() {
    local issue_number=$1 query memberships
    # shellcheck disable=SC2016
    query='query($owner:String!,$name:String!,$number:Int!,$endCursor:String) {
      repository(owner:$owner, name:$name) {
        issue(number:$number) {
          projectItems(first:100, after:$endCursor) {
            nodes {
              id
              project { id number title owner { login } }
              fieldValueByName(name:"Status") {
                ... on ProjectV2ItemFieldSingleSelectValue { name optionId }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }'
    memberships=$(gh api graphql --paginate \
        -F "owner=$owner" -F "name=$repository_name" -F "number=$issue_number" \
        -f "query=$query" 2>/dev/null) || return 1
    [[ -n $memberships ]] || return 1
    jq -s -c '
        if all(.[]; .data.repository.issue.projectItems? | type == "object")
        then [.[].data.repository.issue.projectItems.nodes[]?]
        else error("issue project membership response is malformed")
        end
    ' <<< "$memberships"
}

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
    trusted_cache_file "$board_file" || return 1
    jq -e --argjson v "$BOARD_SCHEMA_VERSION" '.schemaVersion == $v' \
        <"$board_file" >/dev/null 2>&1
}

# A cache is trusted only when both the file itself AND every directory the
# trusted path depends on -- up to and including .agent/ -- are regular
# (non-symlink), owned by the operator, and cannot be changed by another user
# through group/world write permissions. Permission to *replace* a file comes
# from its containing directory, not the file, so a group- or world-writable
# .agent/ or .agent/cache/ would let another local user unlink board.json or
# board-items.json and substitute their own content -- checking the file
# alone would miss exactly that attack.
trusted_cache_file() {
    local file=$1
    [[ -n $file ]] || return 1
    trusted_cache_dir "$repo_root/.agent" || return 1
    if [[ $file == "$items_file" ]]; then
        trusted_cache_dir "$repo_root/.agent/cache" || return 1
    fi
    [[ -f $file && ! -L $file && -r $file && -O $file ]] || return 1
    trusted_cache_mode "$file"
}

# Shared by trusted_cache_file (files) and trusted_cache_dir (directories):
# the last three octal mode digits must show no group- or world-write bit.
trusted_cache_mode() {
    local path=$1 mode
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    mode=${mode: -3}
    [[ ${mode:1:1} != [2367] && ${mode:2:1} != [2367] ]]
}

trusted_cache_dir() {
    local dir=$1
    [[ -n $dir && -d $dir && ! -L $dir && -O $dir ]] || return 1
    trusted_cache_mode "$dir"
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
command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'
status_is_valid || die \
    "Status must be 'Backlog', 'Ready', 'In progress', 'In review', 'Done', or a column declared in .agent/board.json."

# Merge one issue -> item mapping into the cache, scoped to its board. Written
# temp-then-move so a concurrent reader never sees a half-written file.
cache_item_id() {
    local project_id=$1 issue=$2 item=$3 project_owner=$4 project_number=$5
    local existing='{}' staged
    [[ -n $items_file && -n $project_id && -n $item ]] || return 0
    mkdir -p -- "$(dirname -- "$items_file")" 2>/dev/null || return 0
    if trusted_cache_file "$items_file"; then
        existing=$(jq -c --argjson v "$BOARD_SCHEMA_VERSION" --arg repository "$repository" \
            --arg owner "$project_owner" --arg number "$project_number" --arg p "$project_id" \
            'if (.schemaVersion == $v and .repository == $repository and
                 .owner == $owner and (.projectNumber | tostring) == $number and
                 .project == $p and (.items | type) == "object")
             then .items else {} end' \
            <"$items_file" 2>/dev/null || printf '{}')
    fi
    [[ -n $existing ]] || existing='{}'
    staged=$(mktemp "$(dirname -- "$items_file")/.items.XXXXXX") || return 0
    if jq -n --argjson v "$BOARD_SCHEMA_VERSION" --arg repository "$repository" \
        --arg owner "$project_owner" --argjson number "$project_number" \
        --arg p "$project_id" --argjson items "$existing" \
        --arg n "$issue" --arg id "$item" \
        '{schemaVersion: $v, repository: $repository, owner: $owner,
          projectNumber: $number, project: $p,
          items: ($items + {($n): $id})}' \
        >"$staged" 2>/dev/null; then
        if chmod 600 -- "$staged" && mv -- "$staged" "$items_file"; then
            :
        else
            rm -f -- "$staged"
        fi
    else
        rm -f -- "$staged"
    fi
}

# Remove one issue -> item mapping after a cached mutation is rejected. The
# rewrite is atomic so a later fallback cannot retry the same stale id.
invalidate_cached_item() {
    local project_id=$1 issue=$2 project_owner=$3 project_number=$4 staged
    [[ -n $items_file && -n $project_id && -n $issue && -n $project_owner &&
        -n $project_number ]] || return 0
    trusted_cache_file "$items_file" || return 0
    staged=$(mktemp "$(dirname -- "$items_file")/.items.XXXXXX") || return 0
    if jq --argjson v "$BOARD_SCHEMA_VERSION" --arg repository "$repository" \
        --arg owner "$project_owner" --arg number "$project_number" \
        --arg p "$project_id" --arg n "$issue" '
        if (.schemaVersion == $v and .repository == $repository and
            .owner == $owner and (.projectNumber | tostring) == $number and
            .project == $p and (.items | type) == "object")
        then .items |= del(.[$n])
        else .
        end' <"$items_file" >"$staged" 2>/dev/null; then
        if chmod 600 -- "$staged" && mv -- "$staged" "$items_file"; then
            :
        else
            rm -f -- "$staged"
        fi
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

    if ! jq -n --argjson version "$BOARD_SCHEMA_VERSION" --arg repository "$repository" \
        --arg owner "$board_owner" \
        --argjson number "$project_number" --arg project "$project_id" --arg title "$project_title" \
        --arg field "$field_id" --argjson options "$options" --arg fingerprint "$fingerprint" \
        --arg generated_at "$generated_at" \
        '{schemaVersion: $version, repository: $repository, owner: $owner,
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
    if trusted_cache_file "$board_file" &&
        existing_substantive=$(jq -S -c 'del(.generatedAt)' <"$board_file" 2>/dev/null); then
        if [[ $staged_substantive == "$existing_substantive" ]]; then
            rm -f -- "$staged"
            return 0
        fi
    fi
    chmod 600 -- "$staged" && mv -- "$staged" "$board_file"
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

board_provenance_matches() {
    local project_number=$1 project_id=$2 project_owner=$3
    jq -e --arg repository "$repository" --arg owner "$project_owner" \
        --arg number "$project_number" --arg project "$project_id" '
        .repository == $repository and .owner == $owner and
        (.project.number | tostring) == $number and .project.id == $project
    ' <"$board_file" >/dev/null 2>&1
}

item_cache_provenance_matches() {
    local project_number=$1 project_id=$2 project_owner=$3
    jq -e --argjson v "$BOARD_SCHEMA_VERSION" --arg repository "$repository" \
        --arg owner "$project_owner" --arg number "$project_number" \
        --arg project "$project_id" '
        .schemaVersion == $v and .repository == $repository and
        .owner == $owner and (.projectNumber | tostring) == $number and
        .project == $project and (.items | type) == "object"
    ' <"$items_file" >/dev/null 2>&1
}

# A trusted board and item cache are the fail-closed boundary for a warm move:
# provenance and file safety are checked locally, then the cached IDs go
# directly to the one mutation. Returns 0 when every requested issue is
# handled, 1 on cache doubt, and 2 when a trusted cached mutation is rejected.
try_fast_path() {
    local project_number project_id project_title field_id option_id item_id issue_number
    local project_owner

    ((all_boards == 0)) || return 1
    board_readable || return 1
    trusted_cache_file "$items_file" || return 1

    project_number=$(jq -r '.project.number // empty' <"$board_file" 2>/dev/null) || return 1
    project_id=$(jq -r '.project.id // empty' <"$board_file" 2>/dev/null) || return 1
    project_title=$(jq -r '.project.title // "?"' <"$board_file" 2>/dev/null) || return 1
    field_id=$(jq -r '.statusField.id // empty' <"$board_file" 2>/dev/null) || return 1
    option_id=$(board_option_id "$status") || return 1
    [[ -n $project_number && -n $project_id && -n $field_id && -n $option_id ]] || return 1

    project_owner=$(jq -r '.owner // empty' <"$board_file" 2>/dev/null) || return 1
    [[ -n $project_owner ]] || return 1
    board_provenance_matches "$project_number" "$project_id" "$project_owner" || return 1
    item_cache_provenance_matches "$project_number" "$project_id" "$project_owner" || return 1

    for issue_number in "${issue_numbers[@]}"; do
        item_id=$(jq -r --arg n "$issue_number" '.items[$n] // empty' \
            <"$items_file" 2>/dev/null) || return 1
        [[ -n $item_id ]] || return 1
    done

    for issue_number in "${issue_numbers[@]}"; do
        item_id=$(jq -r --arg n "$issue_number" '.items[$n] // empty' \
            <"$items_file" 2>/dev/null) || return 1
        gh project item-edit \
            --id "$item_id" \
            --project-id "$project_id" \
            --field-id "$field_id" \
            --single-select-option-id "$option_id" >/dev/null 2>&1 || {
                invalidate_cached_item "$project_id" "$issue_number" "$project_owner" "$project_number"
                return 2
            }
        cache_item_id "$project_id" "$issue_number" "$item_id" "$project_owner" "$project_number"
        completed_issues[$issue_number]=1
        report_moved "moved #$issue_number -> \"$status\" on project #$project_number \"$project_title\" (board.json, 1 call)"
    done
    return 0
}

# board.json names a trusted project and Status field. A missing item cache uses
# one live item-list read, then the declared board IDs for the mutation.
# Returns 0 moved, 1 cannot use this path, 2 the API rejected the edit.
try_known_board() {
    local project_number project_id project_title field_id option_id items_json item_id issue_number
    local project_owner

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
    [[ -n $project_owner ]] || return 1
    board_provenance_matches "$project_number" "$project_id" "$project_owner" || return 1

    items_json=$(gh project item-list "$project_number" --owner "$project_owner" \
        --limit "$ITEM_LIMIT" --format json 2>/dev/null) || return 1
    [[ -n $items_json ]] || return 1

    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
        item_id=$(select_item_id "$issue_number" "$items_json")
        [[ -n $item_id ]] || continue
        current_status=$(select_item_status "$item_id" "$items_json")
        if [[ -n $current_status && $current_status == "$status" ]]; then
            report_noop "no-op: issue #$issue_number already \"$current_status\""
            completed_issues[$issue_number]=1
            continue
        fi
        gh project item-edit \
            --id "$item_id" \
            --project-id "$project_id" \
            --field-id "$field_id" \
            --single-select-option-id "$option_id" >/dev/null 2>&1 || {
                invalidate_cached_item "$project_id" "$issue_number" "$project_owner" "$project_number"
                return 2
            }
        cache_item_id "$project_id" "$issue_number" "$item_id" "$project_owner" "$project_number"
        completed_issues[$issue_number]=1
        report_moved "moved #$issue_number -> \"$status\" on project #$project_number \"$project_title\" (board.json, 2 calls)"
    done
    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] || return 1
    done
    return 0
}

# Resolve issues that were absent from the declared board item listing by
# reading their own project memberships. This is deliberately the final
# default path when board.json is trusted: an issue on another board is a
# terminal no-op, not permission to scan every project in the organization.
try_declared_memberships() {
    local project_number project_id project_title field_id option_id project_owner
    local memberships item_id current_status issue_number

    ((all_boards == 0)) || return 1
    board_readable || return 1
    project_number=$(jq -r '.project.number // empty' <"$board_file" 2>/dev/null) || return 1
    project_id=$(jq -r '.project.id // empty' <"$board_file" 2>/dev/null) || return 1
    project_title=$(jq -r '.project.title // "?"' <"$board_file" 2>/dev/null) || return 1
    field_id=$(jq -r '.statusField.id // empty' <"$board_file" 2>/dev/null) || return 1
    option_id=$(board_option_id "$status") || return 1
    project_owner=$(jq -r '.owner // empty' <"$board_file" 2>/dev/null) || return 1
    [[ -n $project_number && -n $project_id && -n $field_id && -n $option_id &&
        -n $project_owner ]] || return 1
    board_provenance_matches "$project_number" "$project_id" "$project_owner" || return 1

    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
        memberships=$(issue_project_items "$issue_number") || return 2
        item_id=$(jq -r --arg project "$project_id" --arg number "$project_number" \
            --arg owner "$project_owner" '
            first(.[] | select(
                ((.project.id // "") == $project) or
                (((.project.number // "") | tostring) == $number and
                 ((.project.owner.login // "") | ascii_downcase) == ($owner | ascii_downcase))
            ) | .id) // empty
        ' <<< "$memberships")
        if [[ -z $item_id ]]; then
            ((cached_mutation_rejected == 0)) || return 2
            report_noop "no-op: issue #$issue_number is not on any project board"
            completed_issues[$issue_number]=1
            continue
        fi

        current_status=$(jq -r --arg item "$item_id" '
            first(.[] | select(.id == $item)
                  | (.fieldValueByName.name // empty)) // empty
        ' <<< "$memberships")
        if [[ -n $current_status && $current_status == "$status" ]]; then
            report_noop "no-op: issue #$issue_number already \"$current_status\""
            completed_issues[$issue_number]=1
            continue
        fi
        gh project item-edit \
            --id "$item_id" \
            --project-id "$project_id" \
            --field-id "$field_id" \
            --single-select-option-id "$option_id" >/dev/null 2>&1 || {
                invalidate_cached_item "$project_id" "$issue_number" "$project_owner" "$project_number"
                return 2
            }
        cache_item_id "$project_id" "$issue_number" "$item_id" "$project_owner" "$project_number"
        completed_issues[$issue_number]=1
        report_moved "moved #$issue_number -> \"$status\" on project #$project_number \"$project_title\" (projectItems)"
    done
    return 0
}

# --all-boards is the only mode allowed to inspect boards beyond board.json.
# It walks the issue's paginated projectItems connection, then resolves each
# matching board's Status field without listing that board's cards.
process_project_memberships() {
    local memberships issue_number item_id project_number project_id project_title project_owner
    local current_status fields_json status_field_id option_id

    ((all_boards == 1)) || return 1
    for issue_number in "${issue_numbers[@]}"; do
        memberships=$(issue_project_items "$issue_number") || return 2
        if [[ $(jq 'length' <<< "$memberships") == 0 ]]; then
            report_noop "no-op: issue #$issue_number is not on any project board"
            completed_issues[$issue_number]=1
            continue
        fi
        while IFS=$'\t' read -r item_id project_number project_id project_title project_owner current_status; do
            [[ -n $item_id && -n $project_number && -n $project_id ]] || continue
            [[ -n $project_title ]] || project_title='(untitled)'
            [[ -n $project_owner ]] || project_owner=$owner
            if ! fields_json=$(gh project field-list "$project_number" --owner "$project_owner" \
                --limit "$FIELD_LIMIT" --format json 2>/dev/null); then
                printf 'Warning: could not list fields for project #%s; skipping it.\n' \
                    "$project_number" >&2
                continue
            fi
            status_field_id=$(jq -r \
                'first(.fields[]? | select((.name | ascii_downcase) == "status") | .id) // empty' \
                <<< "$fields_json")
            if [[ -z $status_field_id ]]; then
                report_noop "no-op: project #$project_number \"$project_title\" has no Status field"
                completed_issues[$issue_number]=1
                continue
            fi
            option_id=$(jq -r --arg wanted "$status" \
                'first(.fields[]? | select((.name | ascii_downcase) == "status") |
                 .options[]? | select((.name | ascii_downcase) == ($wanted | ascii_downcase)) | .id) // empty' \
                <<< "$fields_json")
            if [[ -z $option_id ]]; then
                report_noop "no-op: project #$project_number \"$project_title\" has no matching Status option \"$status\""
                completed_issues[$issue_number]=1
                continue
            fi
            if [[ -n $current_status && $current_status == "$status" ]]; then
                report_noop "no-op: issue #$issue_number already \"$current_status\""
                completed_issues[$issue_number]=1
                continue
            fi
            gh project item-edit \
                --id "$item_id" \
                --project-id "$project_id" \
                --field-id "$status_field_id" \
                --single-select-option-id "$option_id" >/dev/null 2>&1 ||
                die "Could not move issue #$issue_number to '$status'."
            completed_issues[$issue_number]=1
            report_moved "moved #$issue_number -> \"$status\" on project #$project_number \"$project_title\""
        done < <(jq -r '.[] | [(.id // ""), (.project.number // ""), (.project.id // ""),
            (.project.title // ""), (.project.owner.login // ""),
            (.fieldValueByName.name // "")] | @tsv' <<< "$memberships")
    done
    return 0
}

fast_rc=0
try_fast_path || fast_rc=$?
if ((fast_rc == 0)); then
    report_summary
    exit 0
fi
if ((fast_rc == 1)); then
    known_rc=0
    try_known_board || known_rc=$?
    if ((known_rc == 0)); then
        report_summary
        exit 0
    fi
    if ((known_rc == 2)); then
        fast_rc=2
    fi
fi
if ((fast_rc == 2)); then
    # Exactly one retry, via the full discovery path below. A second rejection
    # is a real error and must surface rather than be papered over by a loop.
    printf 'board changed - the cached ids were rejected; rediscovering once\n' >&2
    printf 'board changed - commit the regenerated .agent/board.json\n' >&2
    cached_mutation_rejected=1
fi

# A trusted declaration closes the default search boundary. Only an invalid
# or absent declaration may use the legacy organization-wide fallback.
if ((all_boards == 0)) && board_readable; then
    declared_rc=0
    try_declared_memberships || declared_rc=$?
    if ((declared_rc == 0)); then
        report_summary
        exit 0
    fi
    if ((declared_rc == 2)); then
        die 'Could not list issue project memberships.'
    fi
fi

# Explicit --all-boards is driven by each issue's own paginated memberships;
# it never needs to enumerate the organization's unrelated projects.
if ((all_boards == 1)); then
    memberships_rc=0
    process_project_memberships || memberships_rc=$?
    ((memberships_rc == 0)) || die 'Could not list issue project memberships.'
    for issue_number in "${issue_numbers[@]}"; do
        [[ ${completed_issues[$issue_number]+yes} == yes ]] && continue
        report_noop "no-op: issue #$issue_number is not on any project board"
    done
    report_summary
    exit 0
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
            report_noop "no-op: project #$project_number \"$project_title\" has no Status field"
            completed_issues[$issue_number]=1
        done
        return 4
    fi

    option_id=$(jq -r --arg status "$status" \
        'first(.fields[]? | select((.name | ascii_downcase) == "status") | .options[]? | select((.name | ascii_downcase) == ($status | ascii_downcase)) | .id) // empty' \
        <<< "$fields_json")
    if [[ -z $option_id ]]; then
        for issue_number in "${board_issues[@]}"; do
            report_noop "no-op: project #$project_number \"$project_title\" has no matching Status option \"$status\""
            completed_issues[$issue_number]=1
        done
        return 4
    fi

    for issue_number in "${board_issues[@]}"; do
        item_id=$(select_item_id "$issue_number" "$items_json")
        current_status=$(select_item_status "$item_id" "$items_json")
        if [[ -n $current_status && $current_status == "$status" ]]; then
            report_noop "no-op: issue #$issue_number already \"$current_status\""
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
        cache_item_id "$project_id" "$issue_number" "$item_id" "$owner" "$project_number"
        completed_issues[$issue_number]=1
        report_moved "moved #$issue_number -> \"$status\" on project #$project_number \"$project_title\""
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
        report_noop "no-op: issue #$issue_number is not on any project board"
    done
    report_summary
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
    report_noop "no-op: issue #$issue_number is not on any project board"
done
report_summary
