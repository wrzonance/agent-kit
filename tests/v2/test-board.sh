#!/usr/bin/env bash
# ak board: move an issue's Projects v2 Status, never failing the caller.
TEST_NAME=v2-board
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
cd "$repo" || exit 1

out=$("$AK" board --issue 5 --status Done 2>&1); rc=$?
assert_eq 0 "$rc" 'no board config is a no-op, not a failure'
assert_eq 'board #5: no-op (no board configured)' "$out" 'no-op names the reason'

out=$("$AK" board --issue x --status Done 2>&1); rc=$?
assert_eq 2 "$rc" 'a non-numeric issue is a usage error'

printf 'AGENT_PROJECT_OWNER=acme\nAGENT_PROJECT_NUMBER=4\n' >>.agent/config.env
items='{"items":[{"id":"I_5","content":{"type":"Issue","number":5,"repository":"acme/widget"},"status":"Ready"},{"id":"I_X","content":{"type":"Issue","number":6,"repository":"other/repo"}}]}'
board_route 4 "$items"
route 'project item-edit*' ''

out=$("$AK" board --issue 5 --status 'in progress' 2>&1); rc=$?
assert_eq 0 "$rc" 'a move exits 0'
assert_eq 'board #5 -> In progress' "$out" 'a move prints one line with the board option name'
assert_contains "$(cat "$FAKE_GH_LOG")" 'project item-edit --id I_5 --project-id PVT_4 --field-id F_S --single-select-option-id O_P' 'item-edit gets the resolved ids'

out=$("$AK" board --issue 6 --status Done 2>&1)
assert_eq 'board #6: no-op (not on the board)' "$out" 'an item from another repository does not match'

out=$("$AK" board --issue 5 --status Shipped 2>&1)
assert_eq 'board #5: no-op (no Status option "Shipped")' "$out" 'an unknown option is a no-op'

: >"$FAKE_GH_ROUTES"
: >"$FAKE_GH_LOG"
route 'api graphql*' '{"errors":[]}gh: Your token has not been granted the required scopes to execute this query' 1
out=$("$AK" board --issue 5 --status Done 2>&1); rc=$?
assert_eq 0 "$rc" 'a scope error never fails the caller'
assert_eq 'board #5: no-op (no project scope)' "$out" 'a scope error is a no-op with its reason'

: >"$FAKE_GH_ROUTES"
board_route 4 "$items" '[]'
route 'api graphql*' '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_4","field":{},"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
out=$("$AK" board --issue 5 --status Done 2>&1)
assert_eq 'board #5: no-op (no Status option "Done")' "$out" 'a Status field without the option is a no-op'
: >"$FAKE_GH_ROUTES"
route 'api graphql*' '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_4","field":{},"items":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
out=$("$AK" board --issue 5 --status Done 2>&1)
assert_eq 'board #5: no-op (no Status field)' "$out" 'a board without Status is a no-op'

# One query per move: the porcelain's item-list, field-list and view cost 9.2 s on a field board, in every worker's ship.
: >"$FAKE_GH_ROUTES"
: >"$FAKE_GH_LOG"
board_route 4 "$items"
route 'project item-edit*' ''
"$AK" board --issue 5 --status Ready >/dev/null 2>&1
assert_eq 2 "$(wc -l <"$FAKE_GH_LOG")" 'a move is one board read and one edit'
assert_contains "$(head -n 1 "$FAKE_GH_LOG")" 'filter=-status:Done' 'the read leaves the Done items on the server'

# A board that spans pages is read to the end.
: >"$FAKE_GH_ROUTES"
page() { printf '{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_4","field":{"id":"F_S","options":[{"id":"O_R","name":"Ready"}]},"items":{"pageInfo":{"hasNextPage":%s,"endCursor":"C1"},"nodes":[{"id":"I_%s","fieldValueByName":{"name":"Ready"},"content":{"__typename":"Issue","number":%s,"repository":{"nameWithOwner":"acme/widget"},"labels":{"nodes":[]}}}]}}}}}' "$1" "$2" "$2"; }
route 'api graphql*cursor=C1' "$(page false 8)"
route 'api graphql*' "$(page true 7)"
route 'project item-edit*' ''
out=$("$AK" board --issue 8 --status Ready 2>&1)
assert_eq 'board #8 -> Ready' "$out" 'an item on the second page is found'

# A board that never ends is an error, and a failed second look reports its own cause.
: >"$FAKE_GH_ROUTES"
route 'api graphql*' "$(page true 7)"
out=$("$AK" board --issue 7 --status Ready 2>&1)
assert_eq 'board #7: no-op (board call failed: the board has more than 2000 items in play)' "$out" 'a board past the page cap is not read as complete'
: >"$FAKE_GH_ROUTES"
route 'api graphql*filter=-status:Done*' "$(page false 7)"
route 'api graphql*' 'gh: API rate limit already exceeded' 1
out=$("$AK" board --issue 9 --status Ready 2>&1)
assert_eq 'board #9: no-op (board call failed: API rate limit already exceeded)' "$out" 'a failed look at the whole board names its cause'

# A server whose items field takes no search query still gets its board.
: >"$FAKE_GH_ROUTES"
: >"$FAKE_GH_LOG"
# shellcheck disable=SC2016 # the literal GraphQL variable
route 'api graphql*query:$filter*' "gh: Field 'items' doesn't accept argument 'query'" 1
route 'api graphql*' "$(page false 7)"
route 'project item-edit*' ''
out=$("$AK" board --issue 7 --status Ready 2>&1)
assert_eq 'board #7 -> Ready' "$out" 'the read falls back to the whole board'

finish
