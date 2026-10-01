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

# board_ids: item ids per issue and option ids per Status, cached in sandbox.json after one GraphQL read.
board_ids() {
    jq -e '.board.items and .board.options' "$state" >/dev/null 2>&1 && return 0
    local project
    project=$(jq -r '.board.project_id' "$state")
    # shellcheck disable=SC2016 # GraphQL variables, not shell
    gh api graphql -f query='query($p:ID!){node(id:$p){... on ProjectV2{
        items(first:100){nodes{id content{... on Issue{number}}}}
        field(name:"Status"){... on ProjectV2SingleSelectField{options{id name}}}}}}' -f p="$project" |
        jq '{items: ([.data.node.items.nodes[] | select(.content.number) | {key: (.content.number | tostring), value: .id}] | from_entries),
             options: ([.data.node.field.options[] | {key: .name, value: .id}] | from_entries)}' >"$state.ids"
    jq --slurpfile ids "$state.ids" '.board += $ids[0]' "$state" >"$state.tmp" && mv "$state.tmp" "$state"
    rm -f -- "$state.ids"
}

# set_statuses "N:Status N:Status ...": every Status change in one GraphQL mutation.
set_statuses() {
    local pair number status item option body='' i=0 project field
    project=$(jq -r '.board.project_id' "$state")
    field=$(jq -r '.board.status_field' "$state")
    for pair in $1; do
        number=${pair%%:*} status=${pair#*:}
        status=${status//_/ }
        item=$(jq -r --arg n "$number" '.board.items[$n]' "$state")
        option=$(jq -r --arg s "$status" '.board.options[$s]' "$state")
        body+="m$i: updateProjectV2ItemFieldValue(input:{projectId:\"$project\",itemId:\"$item\",fieldId:\"$field\",value:{singleSelectOptionId:\"$option\"}}){clientMutationId} "
        i=$((i + 1))
    done
    [[ -n $body ]] || return 0
    gh api graphql -f query="mutation{ $body}" >/dev/null
}

cmd_reset() {
    [[ -f $state ]] || die "no $state; run: bench/live/sandbox.sh create"
    local wanted=" ${1:-} " work pr ref comment id number statuses=''

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
    for id in $(jq -r '.issues | keys[]' "$state"); do
        number=$(jq -r --arg id "$id" '.issues[$id]' "$state")
        for comment in $(gh api "repos/$REPO/issues/$number/comments?per_page=100" --jq '.[].id'); do
            gh api -X DELETE "repos/$REPO/issues/comments/$comment" >/dev/null
        done
        if [[ $wanted == *" ${id#tally-} "* || $wanted == *" $id "* ]]; then
            gh api -X PATCH "repos/$REPO/issues/$number" -f state=open >/dev/null
            statuses+=" $number:Ready"
        else
            gh api -X PATCH "repos/$REPO/issues/$number" -f state=closed -f state_reason=not_planned >/dev/null
            statuses+=" $number:Backlog"
        fi
    done
    board_ids
    set_statuses "$statuses"
    log "reset $REPO to $TAG; open: ${1:-none}"
}

case ${1:-} in
    create) cmd_create ;;
    reset) shift; cmd_reset "${1:-}" ;;
    *) printf 'usage: sandbox.sh create | reset "01 03 04"\n' >&2; exit 2 ;;
esac
