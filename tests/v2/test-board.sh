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
route 'project field-list 4 --owner acme*' '{"fields":[{"id":"F_S","name":"Status","options":[{"id":"O_R","name":"Ready"},{"id":"O_P","name":"In progress"},{"id":"O_D","name":"Done"}]}]}'
route 'project view 4 --owner acme*' '{"id":"PVT_4","number":4}'
route 'project item-list 4 --owner acme*' '{"items":[{"id":"I_5","content":{"type":"Issue","number":5,"repository":"acme/widget"},"status":"Ready"},{"id":"I_X","content":{"type":"Issue","number":6,"repository":"other/repo"}}]}'
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
route 'project field-list*' 'error: your authentication token is missing required scopes [read:project]' 1
out=$("$AK" board --issue 5 --status Done 2>&1); rc=$?
assert_eq 0 "$rc" 'a scope error never fails the caller'
assert_eq 'board #5: no-op (no project scope; gh auth refresh -s project)' "$out" 'a scope error names the fix'

: >"$FAKE_GH_ROUTES"
route 'project field-list*' '{"fields":[{"id":"F_T","name":"Title"}]}'
out=$("$AK" board --issue 5 --status Done 2>&1)
assert_eq 'board #5: no-op (no Status field)' "$out" 'a board without Status is a no-op'

finish
