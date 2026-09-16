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

# Write a complete cache from already-discovered project and Status-field data.
# Arguments: repo-root repository board-owner project-number project-id title fields-json
board_cache_write() {
    local repo_root=$1 repository=$2 board_owner=$3 project_number=$4
    local project_id=$5 project_title=$6 fields_json=$7
    local agent_dir board_file status_field field_id options fingerprint_input fingerprint
    local generated_at staged staged_substantive existing_substantive

    agent_dir="$repo_root/.agent"
    board_file="$agent_dir/board.json"
    status_field=$(jq -c \
        'first(.fields[]? | select((.name | ascii_downcase) == "status")) // empty' \
        <<< "$fields_json") || return 1
    field_id=$(jq -r '.id // empty' <<< "$status_field") || return 1
    options=$(jq -c '[.options[]? | {key: .name, value: .id}] | from_entries' \
        <<< "$status_field") || return 1
    [[ -n $field_id && $options != '{}' ]] || return 1

    if [[ ! -e $agent_dir ]]; then
        mkdir -p -- "$agent_dir" || return 1
    fi
    [[ -d $agent_dir && ! -L $agent_dir ]] || return 1
    fingerprint_input=$(jq -S -c -n --arg project "$project_id" --arg field "$field_id" \
        --argjson options "$options" \
        '{p: $project, f: $field, o: ($options | to_entries | sort_by(.key) | map(.value))}') ||
        return 1
    fingerprint="sha256:$(printf '%s' "$fingerprint_input" | sha256sum | cut -d' ' -f1)"
    generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    staged=$(mktemp "$agent_dir/.board.XXXXXX") || return 1

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

# Discover the one open Project linked to REPOSITORY, persist its complete
# cache, and expose the selected live values in BOARD_CACHE_DISCOVERED_*.
# No organization-wide fallback is allowed: ownership alone is not repository
# provenance.
board_cache_discover() {
    local repo_root=$1 repository=$2 repo_owner repo_name query response project
    local projects count fields_json

    [[ $repository =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
        printf 'board-cache: repository must have the form OWNER/REPO\n' >&2
        return 1
    }
    for tool in gh jq sha256sum date mktemp; do
        command -v "$tool" >/dev/null 2>&1 || {
            printf 'board-cache: %s is not installed\n' "$tool" >&2
            return 1
        }
    done

    repo_owner=${repository%%/*}
    repo_name=${repository#*/}
    # shellcheck disable=SC2016
    query='query($owner:String!,$name:String!){
      repository(owner:$owner,name:$name){
        projectsV2(first:20){
          nodes{id number title closed owner{... on Organization{login} ... on User{login}}}
        }
      }
    }'
    response=$(gh api graphql -f "owner=$repo_owner" -f "name=$repo_name" \
        -f "query=$query" 2>/dev/null) || {
        printf 'board-cache: could not list projects linked to %s\n' "$repository" >&2
        return 1
    }
    projects=$(jq -c '[.data.repository.projectsV2.nodes[]? | select(.closed != true)]' \
        <<< "$response" 2>/dev/null) || {
        printf 'board-cache: could not parse projects linked to %s\n' "$repository" >&2
        return 1
    }
    count=$(jq -r 'length' <<< "$projects") || return 1
    if [[ $count == 0 ]]; then
        return 2
    fi
    if [[ $count != 1 ]]; then
        printf 'board-cache: expected one open project linked to %s; found %s\n' \
            "$repository" "$count" >&2
        return 1
    fi
    project=$(jq -c '.[0]' <<< "$projects") || return 1

    BOARD_CACHE_DISCOVERED_NUMBER=$(jq -r '.number // empty' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_ID=$(jq -r '.id // empty' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_TITLE=$(jq -r '.title // "(untitled)"' <<< "$project") || return 1
    BOARD_CACHE_DISCOVERED_OWNER=$(jq -r '.owner.login // empty' <<< "$project") || return 1
    [[ -n $BOARD_CACHE_DISCOVERED_NUMBER && -n $BOARD_CACHE_DISCOVERED_ID ]] || {
        printf 'board-cache: linked project is missing its number or id\n' >&2
        return 1
    }
    [[ -n $BOARD_CACHE_DISCOVERED_OWNER ]] || BOARD_CACHE_DISCOVERED_OWNER=$repo_owner

    fields_json=$(gh project field-list "$BOARD_CACHE_DISCOVERED_NUMBER" \
        --owner "$BOARD_CACHE_DISCOVERED_OWNER" --limit 100 --format json 2>/dev/null) || {
        printf 'board-cache: could not list fields for project #%s\n' \
            "$BOARD_CACHE_DISCOVERED_NUMBER" >&2
        return 1
    }
    board_cache_write "$repo_root" "$repository" "$BOARD_CACHE_DISCOVERED_OWNER" \
        "$BOARD_CACHE_DISCOVERED_NUMBER" "$BOARD_CACHE_DISCOVERED_ID" \
        "$BOARD_CACHE_DISCOVERED_TITLE" "$fields_json" || {
        printf 'board-cache: could not write %s/.agent/board.json\n' "$repo_root" >&2
        return 1
    }
    # shellcheck disable=SC2034 # public result consumed by the sourcing command
    BOARD_CACHE_DISCOVERED_FIELDS=$fields_json
}
