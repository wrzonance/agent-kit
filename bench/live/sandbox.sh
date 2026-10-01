#!/usr/bin/env bash
# bench/live/sandbox.sh create|reset ISSUE_IDS: the GitHub sandbox every live trial runs against.
#
#   create          one time: a private repo seeded from bench/fixtures/tally (tag fixture-v1), the ten
#                   bench/issues as GitHub issues with their blocked_by links, a Projects board with the
#                   canonical Status column, and a one-line Node CI. Writes bench/live/sandbox.json.
#   reset "01 03"   before each trial: main back to fixture-v1, every PR closed, every branch but main
#                   deleted, issue comments removed, the listed issues open and Ready, the rest closed.
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
bench=$(dirname -- "$here")
state="$here/sandbox.json"
OWNER=${AK_BENCH_OWNER:-wrzonance}
NAME=${AK_BENCH_REPO:-ak-bench}
REPO="$OWNER/$NAME"
TAG=fixture-v1

die() { printf 'sandbox: %s\n' "$1" >&2; exit 1; }
log() { printf 'sandbox: %s\n' "$*" >&2; }

# Strip the YAML front matter from a bench issue file; print its H1 title or its body.
issue_title() { sed -n 's/^# //p' "$1" | head -n 1; }
issue_body() { awk 'BEGIN{fm=0} /^---$/ && fm<2 {fm++; next} fm>=2' "$1" | sed '1,/^# /d'; }
issue_field() { sed -n "s/^$2: *//p" "$1" | head -n 1; }

seed_tree() {
    local dir=$1
    cp -R "$bench/fixtures/tally/." "$dir/"
    rm -rf -- "$dir/.agent"
    mkdir -p "$dir/.github/workflows"
    cat >"$dir/.github/workflows/ci.yml" <<'YAML'
name: ci
on: [push, pull_request]
jobs:
  smoke:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - run: node test/smoke.mjs
YAML
    printf '.agent/\n.ak/\n.worktrees/\nnode_modules/\n' >"$dir/.gitignore"
}

create_repo() {
    local work
    gh api "repos/$REPO" >/dev/null 2>&1 && die "$REPO already exists; use reset"
    gh repo create "$REPO" --private --description 'agent-kit live benchmark sandbox (resettable)' >/dev/null
    work=$(mktemp -d)
    seed_tree "$work"
    git -C "$work" init -q -b main
    git -C "$work" add -A
    git -C "$work" -c user.name=ak-bench -c user.email=ak-bench@users.noreply.github.com \
        commit -q -m 'fixture: tally v1'
    git -C "$work" tag "$TAG"
    git -C "$work" remote add origin "https://github.com/$REPO.git"
    git -C "$work" push -q origin main "$TAG"
    rm -rf -- "$work"
}

create_issues() {
    local file id number map='{}'
    for file in "$bench"/issues/[0-9][0-9]-*.md; do
        id=$(issue_field "$file" id)
        number=$(gh api "repos/$REPO/issues" -f title="$(issue_title "$file")" -f body="$(issue_body "$file")" --jq .number)
        map=$(jq --arg id "$id" --argjson n "$number" '. + {($id): $n}' <<<"$map")
        log "issue $id -> #$number"
    done
    for file in "$bench"/issues/[0-9][0-9]-*.md; do
        local blocker
        blocker=$(issue_field "$file" blocked_by)
        [[ -n $blocker ]] || continue
        id=$(issue_field "$file" id)
        local blocked_db
        blocked_db=$(gh api "repos/$REPO/issues/$(jq -r --arg id "$blocker" '.[$id]' <<<"$map")" --jq .id)
        gh api "repos/$REPO/issues/$(jq -r --arg id "$id" '.[$id]' <<<"$map")/dependencies/blocked_by" \
            -F issue_id="$blocked_db" >/dev/null
    done
    printf '%s\n' "$map"
}

create_board() {
    local number project_id field_id
    number=$(gh project create --owner "$OWNER" --title "$NAME" --format json --jq .number)
    gh project link "$number" --owner "$OWNER" --repo "$REPO" >/dev/null
    project_id=$(gh project view "$number" --owner "$OWNER" --format json --jq .id)
    field_id=$(gh project field-list "$number" --owner "$OWNER" --format json --jq '.fields[] | select(.name=="Status") | .id')
    # shellcheck disable=SC2016 # GraphQL variables, not shell
    gh api graphql -f query='mutation($f:ID!){updateProjectV2Field(input:{fieldId:$f,singleSelectOptions:[
        {name:"Backlog",color:GRAY,description:""},{name:"Ready",color:BLUE,description:""},
        {name:"In progress",color:YELLOW,description:""},{name:"In review",color:PURPLE,description:""},
        {name:"Done",color:GREEN,description:""}]}){projectV2Field{... on ProjectV2SingleSelectField{id}}}}' \
        -f f="$field_id" >/dev/null
    jq -n --argjson n "$number" --arg p "$project_id" --arg f "$field_id" '{number:$n, project_id:$p, status_field:$f}'
}

# add_items: every sandbox issue on the board, once, at creation.
add_items() {
    local number
    for number in $(jq -r '.issues[]' "$state"); do
        gh project item-add "$(jq -r .board.number "$state")" --owner "$OWNER" \
            --url "https://github.com/$REPO/issues/$number" >/dev/null
    done
}

cmd_create() {
    command -v gh >/dev/null || die 'gh is required'
    create_repo
    local issues board
    issues=$(create_issues)
    board=$(create_board)
    jq -n --arg repo "$REPO" --arg tag "$TAG" --argjson issues "$issues" --argjson board "$board" \
        '{repo:$repo, tag:$tag, issues:$issues, board:$board}' >"$state"
    add_items
    log "wrote $state"
}

# gql QUERY: one GraphQL call; the query embeds its own literals.
gql() { gh api graphql -f query="$1"; }

# archive_board_items: archive every item on the board, so a trial sees only its own issues.
archive_board_items() {
    local project ids body='' i=0 id
    project=$(jq -r '.board.project_id' "$state")
    ids=$(gql "query{node(id:\"$project\"){... on ProjectV2{items(first:100){nodes{id}}}}}" | jq -r '.data.node.items.nodes[].id')
    for id in $ids; do
        body+="a$i: archiveProjectV2Item(input:{projectId:\"$project\",itemId:\"$id\"}){clientMutationId} "
        i=$((i + 1))
    done
    [[ -z $body ]] || gql "mutation{ $body}" >/dev/null
}

# board_ready NODE_ID...: add each issue to the board and set it Ready, in two GraphQL calls.
board_ready() {
    local project field ready body='' i=0 node items
    project=$(jq -r '.board.project_id' "$state")
    field=$(jq -r '.board.status_field' "$state")
    ready=$(gql "query{node(id:\"$field\"){... on ProjectV2SingleSelectField{options{id name}}}}" |
        jq -r '.data.node.options[] | select(.name == "Ready") | .id')
    for node in "$@"; do
        body+="i$i: addProjectV2ItemById(input:{projectId:\"$project\",contentId:\"$node\"}){item{id}} "
        i=$((i + 1))
    done
    items=$(gql "mutation{ $body}" | jq -r '.data[].item.id')
    body='' i=0
    for node in $items; do
        body+="s$i: updateProjectV2ItemFieldValue(input:{projectId:\"$project\",itemId:\"$node\",fieldId:\"$field\",value:{singleSelectOptionId:\"$ready\"}}){clientMutationId} "
        i=$((i + 1))
    done
    gql "mutation{ $body}" >/dev/null
}

cmd_reset() {
    [[ -f $state ]] || die "no $state; run: bench/live/sandbox.sh create"
    local work pr ref number id file json nodes=() map='{}' blocker
    work=$(mktemp -d)
    git clone -q "https://github.com/$REPO.git" "$work"
    git -C "$work" push -q --force origin "$TAG^{commit}:refs/heads/main"
    rm -rf -- "$work"
    for pr in $(gh api "repos/$REPO/pulls?state=open&per_page=100" --jq '.[].number'); do
        gh api -X PATCH "repos/$REPO/pulls/$pr" -f state=closed >/dev/null
    done
    for ref in $(gh api "repos/$REPO/git/matching-refs/heads/" --jq '.[].ref' | grep -v '^refs/heads/main$' || true); do
        gh api -X DELETE "repos/$REPO/git/$ref" >/dev/null
    done
    # Every trial gets fresh issues: an issue a prior trial touched carries closed PRs and comments that
    # one kit reads as prior art and the other ignores, so reusing issues makes trials incomparable.
    for number in $(gh api "repos/$REPO/issues?state=open&per_page=100" --jq '.[] | select(.pull_request | not) | .number'); do
        gh api -X PATCH "repos/$REPO/issues/$number" -f state=closed -f state_reason=not_planned >/dev/null
    done
    archive_board_items
    for id in ${1:-}; do
        file=$(ls "$bench"/issues/"$id"-*.md)
        json=$(gh api "repos/$REPO/issues" -f title="$(issue_title "$file")" -f body="$(issue_body "$file")")
        map=$(jq --arg id "tally-$id" --argjson n "$(jq .number <<<"$json")" '. + {($id): $n}' <<<"$map")
        nodes+=("$(jq -r .node_id <<<"$json")")
    done
    for id in ${1:-}; do
        file=$(ls "$bench"/issues/"$id"-*.md)
        blocker=$(issue_field "$file" blocked_by)
        [[ -n $blocker && $(jq -r --arg b "$blocker" '.[$b] // empty' <<<"$map") ]] || continue
        gh api "repos/$REPO/issues/$(jq -r --arg id "tally-$id" '.[$id]' <<<"$map")/dependencies/blocked_by" \
            -F issue_id="$(gh api "repos/$REPO/issues/$(jq -r --arg b "$blocker" '.[$b]' <<<"$map")" --jq .id)" >/dev/null
    done
    ((${#nodes[@]} == 0)) || board_ready "${nodes[@]}"
    # Per-trial state lives outside the repository, so a trial never dirties a tracked file.
    mkdir -p "${AK_BENCH_WORK:-$HOME/.cache/ak-bench}"
    printf '%s\n' "$map" >"${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/current-issues.json"
    log "reset $REPO to $TAG; fresh issues: $(jq -c . <<<"$map")"
}

# cmd_seed_prs "01 03 04": one draft PR per issue from bench/fixtures/pr-v1, stacked per its manifest, against
# the fresh issues the last reset created. Prints "issue-id pr-number" lines and saves them outside the repo.
cmd_seed_prs() {
    local work="${AK_BENCH_WORK:-$HOME/.cache/ak-bench}" seed="$bench/fixtures/pr-v1" clone id base_id base number title pr map='{}'
    local issues="$work/current-issues.json"
    [[ -f $issues ]] || die "no $issues; run: sandbox.sh reset \"${1:-}\" first"
    clone=$(mktemp -d)
    git clone -q "https://github.com/$REPO.git" "$clone"
    for id in ${1:-}; do
        base_id=$(awk -v id="$id" '$1 == id {print $2}' "$seed/manifest")
        [[ -n $base_id && -f $seed/$id.patch ]] || die "no seed PR for $id in $seed"
        number=$(jq -r --arg id "tally-$id" '.[$id]' "$issues")
        if [[ $base_id == main ]]; then base=main; else base="feat/issue-$(jq -r --arg id "tally-$base_id" '.[$id]' "$issues")"; fi
        git -C "$clone" checkout -q -B "feat/issue-$number" "origin/$base" 2>/dev/null || git -C "$clone" checkout -q -B "feat/issue-$number" "$base"
        git -C "$clone" apply --index "$seed/$id.patch"
        git -C "$clone" -c user.name=ak-bench -c user.email=ak-bench@users.noreply.github.com commit -q -m "feat: tally-$id"
        git -C "$clone" push -q -u origin "feat/issue-$number"
        title=$(gh api "repos/$REPO/issues/$number" --jq .title)
        pr=$(gh api "repos/$REPO/pulls" -f title="$title" -f head="feat/issue-$number" -f base="$base" \
            -f body="Closes #$number" -F draft=true --jq .number)
        map=$(jq --arg id "$id" --argjson pr "$pr" '. + {($id): $pr}' <<<"$map")
        printf '%s %s\n' "$id" "$pr"
    done
    rm -rf -- "$clone"
    printf '%s\n' "$map" >"$work/current-prs.json"
}

case ${1:-} in
    create) cmd_create ;;
    seed-prs) shift; cmd_seed_prs "${1:-}" ;;
    reset) shift; cmd_reset "${1:-}" ;;
    *) printf 'usage: sandbox.sh create | reset "01 03 04" | seed-prs "01 03 04"\n' >&2; exit 2 ;;
esac
