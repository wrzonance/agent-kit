# shellcheck shell=bash
# ak board --issue N --status S: move the issue's Projects v2 Status. Never fails the caller over a board.

# Cached per process so one plan moves several issues with one field and one project read.
BOARD_FIELDS=''
BOARD_PROJECT_ID=''

# board_gh ARGS...: run gh project, print its stdout; on failure print the no-op reason and return 1.
board_gh() {
    local out
    if out=$(gh project "$@" 2>&1); then
        printf '%s\n' "$out"
        return 0
    fi
    if [[ $out == *scope* ]]; then
        printf 'no project scope; gh auth refresh -s project\n'
    else
        printf 'gh project %s failed\n' "$1"
    fi
    return 1
}

# board_items: the board's item list JSON (one read; plan reuses it through BOARD_ITEMS).
board_items() {
    local owner number
    owner=$(cfg AGENT_PROJECT_OWNER)
    number=$(cfg AGENT_PROJECT_NUMBER)
    board_gh item-list "$number" --owner "$owner" --format json --limit 500
}

# board_item_id N ITEMS_JSON: the item id of this repository's issue N.
board_item_id() {
    jq -r --argjson n "$1" --arg slug "$(slug)" '
        [.items[]? | select(.content.type == "Issue" and .content.number == $n and
            ((.content.repository // "") as $r | $r == $slug or ($r | endswith("/" + $slug))))][0].id // empty' <<<"$2"
}

# board_move N STATUS: print one `board #N -> S` or `board #N: no-op (reason)` line; always returns 0.
board_move() {
    local n=$1 status=$2 owner number reason field option item
    owner=$(cfg AGENT_PROJECT_OWNER)
    number=$(cfg AGENT_PROJECT_NUMBER)
    [[ -n $owner && -n $number ]] || { board_noop "$n" 'no board configured'; return 0; }
    if [[ -z $BOARD_FIELDS ]]; then
        BOARD_FIELDS=$(board_gh field-list "$number" --owner "$owner" --format json) ||
            { board_noop "$n" "$BOARD_FIELDS"; BOARD_FIELDS=''; return 0; }
    fi
    field=$(jq -r '[.fields[]? | select(.name == "Status")][0].id // empty' <<<"$BOARD_FIELDS")
    [[ -n $field ]] || { board_noop "$n" 'no Status field'; return 0; }
    option=$(jq -r --arg s "$status" '[.fields[] | select(.name == "Status") | .options[]? |
        select((.name | ascii_downcase) == ($s | ascii_downcase))][0] // empty | "\(.id)\t\(.name)"' <<<"$BOARD_FIELDS")
    [[ -n $option ]] || { board_noop "$n" "no Status option \"$status\""; return 0; }
    if [[ -z ${BOARD_ITEMS:-} ]]; then
        BOARD_ITEMS=$(board_items) || { board_noop "$n" "$BOARD_ITEMS"; BOARD_ITEMS=''; return 0; }
    fi
    item=$(board_item_id "$n" "$BOARD_ITEMS")
    [[ -n $item ]] || { board_noop "$n" 'not on the board'; return 0; }
    if [[ -z $BOARD_PROJECT_ID ]]; then
        reason=$(board_gh view "$number" --owner "$owner" --format json) || { board_noop "$n" "$reason"; return 0; }
        BOARD_PROJECT_ID=$(jq -r '.id // empty' <<<"$reason")
    fi
    reason=$(board_gh item-edit --id "$item" --project-id "$BOARD_PROJECT_ID" --field-id "$field" \
        --single-select-option-id "${option%%$'\t'*}") || { board_noop "$n" "$reason"; return 0; }
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
