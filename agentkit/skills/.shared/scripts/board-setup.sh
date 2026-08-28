#!/usr/bin/env bash
#
# board-setup.sh -- create a Project board, link it to the repository, and give
# it the canonical Status columns without clearing anyone's work.
#
# This exists because of what happens without it. `bootstrap-repo.sh` refuses to
# guess between boards, which is right, but it says nothing at all when the
# answer is "there is no board yet" -- so an onboarding session invented the
# path itself. It introspected the GraphQL schema across four calls, found
# `updateProjectV2Field`, and fired it. That worked, and only because the board
# it fired at was empty.
#
# `updateProjectV2Field` with `singleSelectOptions` REPLACES the whole option
# set. It does not match by name: an unchanged "Done" comes back with a new
# option id and every item that was in it is now in no column at all. Run
# against a populated board, the improvised path silently clears the board. It
# has already cost one real board its statuses.
#
# So the mutation is wrapped rather than documented. Snapshot every item's
# status, apply the vocabulary, re-assign by name. A board with items is not
# refused -- refusing is what sends an agent back to improvising -- it is
# restored.
#
# Reports, never guesses. Exit 3 means the environment is not ready (no gh, no
# project scope); exit 1 means a call failed and nothing further was attempted.
set -uo pipefail

PROGRAM=${0##*/}
ARG_REPO_ROOT=""
ARG_TITLE=""
ARG_PROJECT=""
ARG_VOCAB="Backlog,Ready,In progress,In review,Done"
# Boards are not always owned by whoever owns the repository: a personal repo
# can be tracked on an organization's board. Defaults to the repo's owner,
# which is the common case and the one worth not having to type.
ARG_OWNER=
ARG_DRY_RUN=0
ARG_NO_LINK=0

usage() {
    cat << 'EOF'
board-setup.sh -- create or adopt a Project board with the canonical columns.

Usage:
  board-setup.sh [--repo-root DIR] [--owner OWNER] [--title TITLE]
                 [--project N] [--vocab "A,B,C"] [--no-link] [--dry-run]

Options:
  --repo-root DIR  Repository to set the board up for (default: cwd).
  --owner OWNER    Owner of the BOARD (default: the repository's owner). Use
                   this when an organization's board tracks a repo owned by
                   someone else.
  --title TITLE    Title for a board this creates (default: the repo name).
  --project N      Adopt this existing board instead of creating one.
  --vocab "A,B,C"  Status column names, in order. Defaults to
                   "Backlog,Ready,In progress,In review,Done".
  --no-link        Do not link the board to the repository.
  --dry-run        Say what would happen; change nothing.

Creating a board does NOT link it to a repository. An unlinked board is why a
freshly onboarded repo still reports "no board" and why its issues never appear
on one, so this links by default.

Run bootstrap-repo.sh afterwards to write .agent/board.json from the result.
Exit 0 on success, 1 on a failed call, 2 on usage, 3 when the environment
cannot support the change.
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
die_env() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 3
}
warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
say() { printf '%s\n' "$*"; }

while (($#)); do
    case $1 in
        --) shift; break ;;
        --repo-root)
            [[ ${2:-} ]] || die_usage '--repo-root requires a value'
            ARG_REPO_ROOT=$2
            shift 2
            ;;
        --owner)
            [[ ${2:-} ]] || die_usage '--owner requires a value'
            ARG_OWNER=$2
            shift 2
            ;;
        --title)
            [[ ${2:-} ]] || die_usage '--title requires a value'
            ARG_TITLE=$2
            shift 2
            ;;
        --project)
            [[ ${2:-} =~ ^[0-9]{1,9}$ ]] || die_usage '--project requires a number'
            ARG_PROJECT=$2
            shift 2
            ;;
        --vocab)
            [[ ${2:-} ]] || die_usage '--vocab requires a value'
            ARG_VOCAB=$2
            shift 2
            ;;
        --no-link) ARG_NO_LINK=1 && shift ;;
        --dry-run) ARG_DRY_RUN=1 && shift ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

command -v gh > /dev/null 2>&1 || die_env 'the gh CLI is not installed'
command -v jq > /dev/null 2>&1 || die_env 'jq is not installed'

repo_root=${ARG_REPO_ROOT:-$PWD}
[[ -d $repo_root ]] || die "no such directory: $repo_root"
repo_root=$(cd -- "$repo_root" && pwd) || die "cannot enter $repo_root"

# Every value below is read from the repository this was pointed at, never from
# the process working directory -- the same defect bootstrap-repo.sh had.
slug=$(cd -- "$repo_root" && gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null) ||
    die_env "could not resolve the repository from gh in $repo_root"
repo_owner=${slug%%/*}
name=${slug#*/}
[[ -n $repo_owner && -n $name ]] || die "could not split a repository slug out of: $slug"
owner=${ARG_OWNER:-$repo_owner}

# --- the vocabulary ---------------------------------------------------------
# Split on commas only. A column named "In progress" has a space in it, so
# whitespace is content here, not a separator.
declare -a vocab=()
while IFS= read -r column; do
    column=${column#"${column%%[![:space:]]*}"}
    column=${column%"${column##*[![:space:]]}"}
    [[ -n $column ]] && vocab+=("$column")
done < <(tr ',' '\n' <<< "$ARG_VOCAB")
((${#vocab[@]} > 0)) || die_usage '--vocab named no columns'

# --- create or adopt --------------------------------------------------------
project_number=$ARG_PROJECT
if [[ -z $project_number ]]; then
    title=${ARG_TITLE:-$name}
    if ((ARG_DRY_RUN)); then
        say "would create project \"$title\" owned by $owner"
        say "would set its Status columns to: ${vocab[*]}"
        ((ARG_NO_LINK)) || say "would link it to $slug"
        say 'dry run: nothing changed'
        exit 0
    fi
    created=$(gh project create --owner "$owner" --title "$title" --format json 2> /dev/null) ||
        die_env "could not create a project for $owner -- gh needs the project scope (gh auth refresh -s project)"
    project_number=$(jq -r '.number // empty' <<< "$created" 2> /dev/null)
    [[ -n $project_number ]] || die 'the project was created but gh did not report its number'
    say "created project $project_number \"$title\" for $owner"
fi

fields=$(gh project field-list "$project_number" --owner "$owner" --limit 100 --format json 2> /dev/null) ||
    die "could not list fields for project $project_number"

status=$(jq -c 'first(.fields[]? | select(.name == "Status" and (.options | type) == "array")) // empty' \
    <<< "$fields")
[[ -n $status ]] || die "project $project_number has no single-select Status field"
field_id=$(jq -r '.id // empty' <<< "$status")
[[ -n $field_id ]] || die 'the Status field has no id'

# Already correct? Then the mutation is pure downside -- it would rewrite every
# option id and put the board through a restore for no change at all.
# Compared as JSON arrays rather than a joined string: "In progress" contains a
# space, so any separator that is also legal inside a column name can make two
# different vocabularies compare equal.
wanted_json=$(printf '%s
' "${vocab[@]}" | jq -R . | jq -sc .)
current_json=$(jq -c '[.options[].name]' <<< "$status")
if [[ $current_json == "$wanted_json" ]]; then
    say "project $project_number already has exactly these columns: ${vocab[*]}"
else
    # --- snapshot ------------------------------------------------------------
    # Before the destructive part, not after. If the mutation succeeds and this
    # had not run, the assignments are gone and nothing can name what they were.
    items=$(gh project item-list "$project_number" --owner "$owner" --limit 1000 --format json 2> /dev/null) ||
        die "could not read the items on project $project_number; refusing to replace its columns blind"
    snapshot=$(jq -c '[.items[]? | select(.status != null and .status != "")
        | {id, status}]' <<< "$items" 2> /dev/null || printf '[]')
    at_risk=$(jq 'length' <<< "$snapshot")

    if ((ARG_DRY_RUN)); then
        say "would replace the Status columns of project $project_number"
        say "  from: $(jq -r '[.options[].name] | join(", ")' <<< "$status")"
        say "    to: ${vocab[*]}"
        ((at_risk == 0)) ||
            say "  and re-assign $at_risk item(s) whose status the replacement clears"
        say 'dry run: nothing changed'
        exit 0
    fi

    ((at_risk == 0)) ||
        warn "$at_risk item(s) have a status; replacing the columns clears all of them, so they will be re-assigned by name"

    options_arg=$(jq -cn --argjson names "$wanted_json" \
        '[$names[] | {name: ., color: "GRAY", description: ""}]')
    # Sent as a request body rather than through -f/-F. gh's -f sends every
    # value as a STRING, so a list of option objects arrives as one quoted blob
    # and the mutation is rejected -- observed the first time this ran for real.
    # shellcheck disable=SC2016  # GraphQL variable names, not shell expansions.
    mutation='mutation($fieldId: ID!, $options: [ProjectV2SingleSelectFieldOptionInput!]) {
      updateProjectV2Field(input: {fieldId: $fieldId, singleSelectOptions: $options}) {
        projectV2Field { ... on ProjectV2SingleSelectField { id options { id name } } } } }'
    mutation_payload=$(jq -n --arg q "$mutation" --arg fid "$field_id" --argjson opts "$options_arg" \
        '{query: $q, variables: {fieldId: $fid, options: $opts}}')
    updated=$(gh api graphql --input - 2> /dev/null <<< "$mutation_payload") ||
        die "could not set the Status columns on project $project_number"
    # A GraphQL error is a 200 with an errors array, so a non-zero exit is not
    # the only way this fails.
    [[ $(jq -r 'has("errors")' <<< "$updated" 2> /dev/null) != true ]] ||
        die "the Status mutation was rejected: $(jq -rc '.errors[0].message // "unknown"' <<< "$updated")"

    new_options=$(jq -c '.data.updateProjectV2Field.projectV2Field.options // []' <<< "$updated")
    [[ $(jq 'length' <<< "$new_options") -gt 0 ]] ||
        die 'the mutation returned no options; the board may need its statuses restored by hand'
    say "set the Status columns of project $project_number to: ${vocab[*]}"

    # --- restore -------------------------------------------------------------
    # By NAME, because the ids the snapshot holds no longer exist. A status
    # whose column did not survive the rename has nowhere to go; say so per
    # item rather than dropping it silently.
    if ((at_risk > 0)); then
        project_id=$(gh project view "$project_number" --owner "$owner" --format json 2> /dev/null |
            jq -r '.id // empty')
        [[ -n $project_id ]] || die 'restored nothing: could not resolve the project id'
        restored=0 orphaned=0
        while IFS=$'\t' read -r item_id item_status; do
            [[ -n $item_id ]] || continue
            option_id=$(jq -r --arg s "$item_status" \
                'first(.[] | select(.name == $s) | .id) // empty' <<< "$new_options")
            if [[ -z $option_id ]]; then
                warn "item $item_id was \"$item_status\", which is not one of the new columns; left unset"
                ((orphaned++))
                continue
            fi
            if gh project item-edit --id "$item_id" --project-id "$project_id" \
                --field-id "$field_id" --single-select-option-id "$option_id" > /dev/null 2>&1; then
                ((restored++))
            else
                warn "could not restore item $item_id to \"$item_status\""
                ((orphaned++))
            fi
        done < <(jq -r '.[] | [.id, .status] | @tsv' <<< "$snapshot")
        if ((orphaned > 0)); then
            say "restored $restored item status(es); $orphaned left unset"
        else
            say "restored $restored item status(es)"
        fi
    fi
fi

# --- link -------------------------------------------------------------------
# A board that is not linked is invisible to the repository: bootstrap-repo.sh
# asks the REPO which boards it has, gets nothing, and falls back to prompting
# across every board the owner has. New issues do not land on it either.
if ((ARG_NO_LINK == 0)); then
    if ((ARG_DRY_RUN)); then
        say "would link project $project_number to $slug"
    elif gh project link "$project_number" --owner "$owner" --repo "$slug" > /dev/null 2>&1; then
        say "linked project $project_number to $slug"
    else
        warn "could not link project $project_number to $slug; link it in the board's settings, or the repo will keep reporting no board"
    fi
fi

say ''
say "next: \"\$agentkit/.shared/scripts/bootstrap-repo.sh\" --repo-root $repo_root --project $project_number"
