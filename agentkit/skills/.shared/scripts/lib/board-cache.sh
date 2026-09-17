#!/usr/bin/env bash
# Shared repository-linked Project discovery and .agent/board.json writer.
# Source only: callers retain their own error and output contracts.

readonly BOARD_CACHE_SCHEMA_VERSION=1

board_cache_path_is_private() {
    local path=$1 mode
    [[ -f $path && ! -L $path && -r $path && -O $path ]] || return 1
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    mode=${mode: -3}
    [[ ${mode:1:1} != [2367] && ${mode:2:1} != [2367] ]]
}

board_cache_directory_is_private() {
    local path=$1 mode
    [[ -d $path && ! -L $path && -O $path ]] || return 1
    mode=$(stat -c '%a' -- "$path" 2>/dev/null) || return 1
    (( (8#$mode & 8#022) == 0 ))
}

# Write a complete cache from already-discovered project and Status-field data.
# Arguments: repo-root repository board-owner project-number project-id title fields-json
board_cache_write() {
    local repo_root=$1 repository=$2 board_owner=$3 project_number=$4
    local project_id=$5 project_title=$6 fields_json=$7
    local agent_dir board_file status_field field_id options fingerprint_input fingerprint
    local generated_at staged staged_substantive existing_substantive

    [[ -n $repo_root ]] || return 4
    agent_dir="$repo_root/.agent"
    board_file="$agent_dir/board.json"
    if [[ -e $agent_dir || -L $agent_dir ]]; then
        board_cache_directory_is_private "$agent_dir" || return 3
    elif ! (umask 077 && mkdir -- "$agent_dir") 2>/dev/null; then
        return 4
    fi
    board_cache_directory_is_private "$agent_dir" || return 3
    [[ -w $agent_dir ]] || return 4

    status_field=$(jq -c \
        'first(.fields[]? | select((.name | ascii_downcase) == "status")) // empty' \
        <<< "$fields_json") || return 1
    field_id=$(jq -r '.id // empty' <<< "$status_field") || return 1
    options=$(jq -c '[.options[]? | {key: .name, value: .id}] | from_entries' \
        <<< "$status_field") || return 1
    [[ -n $field_id && $options != '{}' ]] || return 2
    for tool in sha256sum date mktemp; do
        command -v "$tool" >/dev/null 2>&1 || return 4
    done
    fingerprint_input=$(jq -S -c -n --arg project "$project_id" --arg field "$field_id" \
        --argjson options "$options" \
        '{p: $project, f: $field, o: ($options | to_entries | sort_by(.key) | map(.value))}') ||
        return 1
    fingerprint="sha256:$(printf '%s' "$fingerprint_input" | sha256sum | cut -d' ' -f1)"
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    staged=$(mktemp "$agent_dir/.board.XXXXXX" 2>/dev/null) || return 4

    if ! jq -n --argjson version "$BOARD_CACHE_SCHEMA_VERSION" \
        --arg repository "$repository" --arg owner "$board_owner" \
        --argjson number "$project_number" --arg project "$project_id" \
        --arg title "$project_title" --arg field "$field_id" \
        --argjson options "$options" --arg fingerprint "$fingerprint" \
        --arg generated_at "$generated_at" \
        '{schemaVersion: $version, repository: $repository, owner: $owner,
          project: {number: $number, id: $project, title: $title},
          statusField: {id: $field, name: "Status", options: $options},
          generatedAt: $generated_at, fingerprint: $fingerprint}' > "$staged"; then
        rm -f -- "$staged"
        return 1
    fi

    staged_substantive=$(jq -S -c 'del(.generatedAt)' < "$staged") || {
        rm -f -- "$staged"
        return 1
    }
    if board_cache_path_is_private "$board_file" &&
        existing_substantive=$(jq -S -c 'del(.generatedAt)' < "$board_file" 2>/dev/null) &&
        [[ $staged_substantive == "$existing_substantive" ]]; then
        rm -f -- "$staged"
        return 0
    fi
    chmod 600 -- "$staged" && mv -- "$staged" "$board_file"
}

# Select one project using issue memberships first, then persist its cache when
# storage and Status metadata permit it. Returns 2 for no candidate, 3 for an
# unsafe cache path, and 5 when multiple candidates remain ambiguous.
board_cache_select() {
    local repo_root=$1 repository=$2 memberships=${3:-'[]'} repo_owner
    local membership_projects membership_count linked_count linked_memberships
    local linked_membership_count project fields_json write_rc

    membership_projects=$(jq -c \
        '[.[]?.project | select((.id // "") != "")] | unique_by(.id)' \
        <<< "$memberships" 2>/dev/null) || return 1
    membership_count=$(jq -r 'length' <<< "$membership_projects") || return 1
    linked_count=$(jq -r 'length' <<< "$BOARD_CACHE_LINKED_PROJECTS") || return 1

    if ((membership_count == 1)); then
        project=$(jq -c '.[0]' <<< "$membership_projects") || return 1
    elif ((membership_count > 1)); then
        linked_memberships=$(jq -c -n --argjson memberships "$membership_projects" \
            --argjson linked "$BOARD_CACHE_LINKED_PROJECTS" \
            '[$memberships[] as $membership | $linked[] |
              select(.id == $membership.id) | $membership] | unique_by(.id)') || return 1
        linked_membership_count=$(jq -r 'length' <<< "$linked_memberships") || return 1
        ((linked_membership_count == 1)) || return 5
        project=$(jq -c '.[0]' <<< "$linked_memberships") || return 1
    elif ((linked_count == 1)); then
        project=$(jq -c '.[0]' <<< "$BOARD_CACHE_LINKED_PROJECTS") || return 1
    elif ((linked_count == 0)); then
        return 2
    else
        return 5
    fi

    repo_owner=${repository%%/*}
    BOARD_CACHE_DISCOVERED_NUMBER=$(jq -r '.number // empty' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_ID=$(jq -r '.id // empty' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_TITLE=$(jq -r '.title // "(untitled)"' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_OWNER=$(jq -r '.owner.login // empty' <<< "$project") || return 1
    [[ -n $BOARD_CACHE_DISCOVERED_NUMBER && -n $BOARD_CACHE_DISCOVERED_ID ]] || {
        printf 'board-cache: selected project is missing its number or id\n' >&2
        return 1
    }
    [[ -n $BOARD_CACHE_DISCOVERED_OWNER ]] || BOARD_CACHE_DISCOVERED_OWNER=$repo_owner

    fields_json=$(gh project field-list "$BOARD_CACHE_DISCOVERED_NUMBER" \
        --owner "$BOARD_CACHE_DISCOVERED_OWNER" --limit 100 --format json 2>/dev/null) || {
        printf 'board-cache: could not list fields for project #%s\n' \
            "$BOARD_CACHE_DISCOVERED_NUMBER" >&2
        return 1
    }
    # shellcheck disable=SC2034 # public result consumed by the sourcing command
    BOARD_CACHE_WRITE_STATE=written
    write_rc=0
    board_cache_write "$repo_root" "$repository" "$BOARD_CACHE_DISCOVERED_OWNER" \
        "$BOARD_CACHE_DISCOVERED_NUMBER" "$BOARD_CACHE_DISCOVERED_ID" \
        "$BOARD_CACHE_DISCOVERED_TITLE" "$fields_json" || write_rc=$?
    # shellcheck disable=SC2034 # every assignment is a public caller result
    case $write_rc in
        0) ;;
        2) BOARD_CACHE_WRITE_STATE=uncacheable ;;
        4) BOARD_CACHE_WRITE_STATE=unavailable ;;
        3)
            printf 'board-cache: unsafe .agent cache path in %s\n' "${repo_root:-<no checkout>}" >&2
            return 3
            ;;
        *)
            printf 'board-cache: could not write %s/.agent/board.json\n' "$repo_root" >&2
            return 1
            ;;
    esac
    # shellcheck disable=SC2034 # public result consumed by the sourcing command
    BOARD_CACHE_DISCOVERED_FIELDS=$fields_json
}

# Enumerate every repository-linked project page, then select using optional
# issue membership evidence. No organization-wide fallback is allowed.
board_cache_discover() {
    local repo_root=$1 repository=$2 memberships=${3:-'[]'}
    local repo_owner repo_name query response

    [[ $repository =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
        printf 'board-cache: repository must have the form OWNER/REPO\n' >&2
        return 1
    }
    for tool in gh jq; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'board-cache: %s is not installed\n' "$tool" >&2
            return 1
        }
    done

    repo_owner=${repository%%/*}
    repo_name=${repository#*/}
    # shellcheck disable=SC2016
    query='query($owner:String!,$name:String!,$endCursor:String){
      repository(owner:$owner,name:$name){
        projectsV2(first:20,after:$endCursor){
          nodes{id number title closed owner{... on Organization{login} ... on User{login}}}
          pageInfo{hasNextPage endCursor}
        }
      }
    }'
    response=$(gh api graphql --paginate -f "owner=$repo_owner" -f "name=$repo_name" \
        -f "query=$query" 2>/dev/null) || {
        printf 'board-cache: could not list projects linked to %s\n' "$repository" >&2
        return 1
    }
    BOARD_CACHE_LINKED_PROJECTS=$(jq -s -c \
        '[.[].data.repository.projectsV2.nodes[]? | select(.closed != true)] | unique_by(.id)' \
        <<< "$response" 2>/dev/null) || {
        printf 'board-cache: could not parse projects linked to %s\n' "$repository" >&2
        return 1
    }
    board_cache_select "$repo_root" "$repository" "$memberships"
}
