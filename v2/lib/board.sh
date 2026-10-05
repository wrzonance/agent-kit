# shellcheck shell=bash
# ak board --issue N --status S: move the issue's Projects v2 Status. Never fails the caller over a board.

# One query reads the project id, the Status field with its options, and the items still in play. The porcelain
# (`gh project item-list`, then field-list and view) took 9.2 s on a 349-item field board, 312 of them Done, before a
# plan could choose anything, and again inside every worker's ship; this read took 1.6 s there.
# shellcheck disable=SC2016 # GraphQL variables, not shell
BOARD_QUERY='query($owner:String!,$number:Int!,$cursor:String,$filter:String){repositoryOwner(login:$owner){... on ProjectV2Owner{projectV2(number:$number){id field(name:"Status"){... on ProjectV2SingleSelectField{id options{id name}}} items(first:100,after:$cursor,query:$filter){pageInfo{hasNextPage endCursor} nodes{id fieldValueByName(name:"Status"){... on ProjectV2ItemFieldSingleSelectValue{name}} content{__typename ... on Issue{number repository{nameWithOwner} labels(first:30){nodes{name}}}}}}}}}}'

# board_fail OUTPUT: the no-op reason for a failed gh call; returns 1.
board_fail() {
    local text=$1
    # gh prints the response body, then its own `gh: <message>` line; the message is the readable part.
    [[ $text != *'gh: '* ]] || text=${text##*gh: }
    if [[ $1 == *scope* ]]; then
        printf 'no project scope\n'
    else
        printf 'board call failed: %s\n' "$(head -n 1 <<<"$text" | cut -c1-160)"
    fi
    return 1
}

# board_items: `{project, field: {id, options}, items: [{id, status, labels, content: {type, number, repository}}]}`,
# without the Done items unless AK_BOARD_FILTER says otherwise. One read; plan reuses it through BOARD_ITEMS.
board_items() {
    local owner number query=$BOARD_QUERY filter=${AK_BOARD_FILTER--status:Done} cursor='' page pages='' i
    owner=$(cfg AGENT_PROJECT_OWNER)
    number=$(cfg AGENT_PROJECT_NUMBER)
    for ((i = 0; i < 20; i++)); do
        if ! page=$(gh api graphql -f "query=$query" -f "owner=$owner" -F "number=$number" -f "filter=$filter" ${cursor:+-f "cursor=$cursor"} 2>&1); then
            # A server whose items take no search query gets the whole board instead.
            [[ $i == 0 && $page == *"'query'"* && $query == *',query:$filter'* ]] || { board_fail "$page"; return 1; }
            query=${query//',query:$filter'/}
            query=${query//',$filter:String'/}
            i=-1
            continue
        fi
        pages+=$(jq -c '.data.repositoryOwner.projectV2 | {project: .id, field: (.field // {}), items: [.items.nodes[] | {id,
            status: (.fieldValueByName.name // ""), labels: [.content.labels.nodes[]?.name],
            content: {type: .content.__typename, number: .content.number, repository: .content.repository.nameWithOwner}}]}' <<<"$page" 2>/dev/null)$'\n' ||
            { board_fail "the response holds no project $number for $owner"; return 1; }
        [[ $(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.hasNextPage' <<<"$page") == true ]] || { cursor=''; break; }
        cursor=$(jq -r '.data.repositoryOwner.projectV2.items.pageInfo.endCursor' <<<"$page")
    done
    # A board longer than the cap is an error, never a short list that reads as the whole board.
    [[ -z $cursor ]] || { board_fail "the board has more than $((i * 100)) items in play"; return 1; }
    jq -cs '{project: .[0].project, field: .[0].field, items: (map(.items) | add)}' <<<"$pages"
}

# board_fix ERROR: the one command that fixes a failed board read. A missing scope needs the operator's browser,
# so it is named as an operator step the root must not run; throttling only needs time.
board_fix() {
    case $1 in
        'no project scope'*) printf 'operator: gh auth refresh -h github.com -s project (interactive; do not run it from an agent)\n' ;;
        *[Rr]ate\ limit* | *secondary* | *abuse*) printf 'wait for the GitHub rate limit, then rerun ak plan: gh api rate_limit --jq .resources.graphql\n' ;;
        *) printf 'gh project item-list %s --owner %s --format json\n' "$(cfg AGENT_PROJECT_NUMBER)" "$(cfg AGENT_PROJECT_OWNER)" ;;
    esac
}

# board_item_id N ITEMS_JSON: the item id of this repository's issue N.
board_item_id() {
    jq -r --argjson n "$1" --arg slug "$(slug)" '
        [.items[]? | select(.content.type == "Issue" and .content.number == $n and
            ((.content.repository // "") as $r | $r == $slug or ($r | endswith("/" + $slug))))][0].id // empty' <<<"$2"
}

# board_move N STATUS: print one `board #N -> S` or `board #N: no-op (reason)` line; always returns 0.
board_move() {
    local n=$1 status=$2 reason field option item
    [[ -n $(cfg AGENT_PROJECT_OWNER) && -n $(cfg AGENT_PROJECT_NUMBER) ]] || { board_noop "$n" 'no board configured'; return 0; }
    if [[ -z ${BOARD_ITEMS:-} ]]; then
        BOARD_ITEMS=$(board_items) || { board_noop "$n" "$BOARD_ITEMS"; BOARD_ITEMS=''; return 0; }
    fi
    field=$(jq -r '.field.id // empty' <<<"$BOARD_ITEMS")
    [[ -n $field ]] || { board_noop "$n" 'no Status field'; return 0; }
    option=$(jq -r --arg s "$status" '[.field.options[]? |
        select((.name | ascii_downcase) == ($s | ascii_downcase))][0] // empty | "\(.id)\t\(.name)"' <<<"$BOARD_ITEMS")
    [[ -n $option ]] || { board_noop "$n" "no Status option \"$status\""; return 0; }
    item=$(board_item_id "$n" "$BOARD_ITEMS")
    # An issue reopened from Done is outside the filtered read; look once at the whole board before giving up.
    if [[ -z $item ]]; then
        reason=$(AK_BOARD_FILTER='' board_items) || { board_noop "$n" "$reason"; return 0; }
        item=$(board_item_id "$n" "$reason")
    fi
    [[ -n $item ]] || { board_noop "$n" 'not on the board'; return 0; }
    reason=$(gh project item-edit --id "$item" --project-id "$(jq -r .project <<<"$BOARD_ITEMS")" --field-id "$field" \
        --single-select-option-id "${option%%$'\t'*}" 2>&1) || { board_noop "$n" "$(board_fail "$reason")"; return 0; }
    printf 'board #%s -> %s\n' "$n" "${option#*$'\t'}"
}

board_noop() {
    printf 'board #%s: no-op (%s)\n' "$1" "$2"
}

cmd_main() {
    local n='' status=''
    while (($#)); do
        case $1 in
            --issue) n=${2:-}; shift 2 || usage_die 'ak board: --issue needs a number' ;;
            --status) status=${2:-}; shift 2 || usage_die 'ak board: --status needs a value' ;;
            *) usage_die "ak board: unknown argument: $1" ;;
        esac
    done
    [[ $n =~ ^[0-9]+$ && -n $status ]] || usage_die 'usage: ak board --issue N --status "In progress|In review|Done"'
    board_move "$n" "$status"
}
