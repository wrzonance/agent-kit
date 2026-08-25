#!/usr/bin/env bash
# Suite: pick-issues.sh selects only what is actually startable.
#
# This is the script an autonomous `--fast-mode` run trusts instead of asking.
# The failure that matters is not a crash -- it is calling one blocked issue
# eligible, because nobody is watching when it dispatches a worker onto work
# that cannot land. Every assertion below is about refusing to say "start this".
set -uo pipefail

TEST_NAME='pick-issues'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/pick-issues.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/.agent"
git -C "$repo" init -q 2> /dev/null
printf '{"schemaVersion":1,"owner":"example-org","project":{"id":"PVT_x","number":7}}\n' \
    > "$repo/.agent/board.json"
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "\$*" >> "$tmp/gh.log"
case "\$*" in
  *"project item-list"*) cat "$tmp/items.json" ;;
  *"api graphql"*)       cat "$tmp/deps.json" ;;
  *) printf '{}\n' ;;
esac
EOF
chmod +x "$tmp/bin/gh"

run() { PATH="$tmp/bin:$PATH" "$script" --repo-root "$repo" "$@" 2>&1; }

set_board() {
    printf '%s' "$1" > "$tmp/items.json"
    printf '%s' "$2" > "$tmp/deps.json"
    : > "$tmp/gh.log"
}

# Four issues on a board this repository shares with another one. #10 is Ready
# and free; #11 is Ready but blocked by an OPEN issue; #12 is Backlog and free;
# #13 belongs to a different repository entirely.
items='{"totalCount":4,"items":[
  {"status":"Ready","content":{"number":10,"type":"Issue","title":"free and ready",
   "repository":"example-org/example-repo"}},
  {"status":"Ready","content":{"number":11,"type":"Issue","title":"blocked",
   "repository":"https://github.com/example-org/example-repo"}},
  {"status":"Backlog","content":{"number":12,"type":"Issue","title":"groomable",
   "repository":"example-org/example-repo"}},
  {"status":"Ready","content":{"number":13,"type":"Issue","title":"other repo",
   "repository":"example-org/other-repo"}},
  {"status":"In progress","content":{"number":14,"type":"Issue","title":"already running",
   "repository":"example-org/example-repo"}}]}'
deps='{"data":{"repository":{
  "i10":{"number":10,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}},
  "i11":{"number":11,"state":"OPEN","blockedBy":{"totalCount":1,"nodes":[{"number":99,"state":"OPEN"}]}},
  "i12":{"number":12,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'

# --- the default is Ready only ----------------------------------------------
set_board "$items" "$deps"
out=$(run)
assert_contains "$out" '#10  Ready  free and ready' 'an unblocked Ready issue is selectable'
assert_not_contains "$out" '#12' 'Backlog is not pulled from unless asked'
assert_contains "$out" 'selectable=1' 'and the count says how many'
assert_contains "$out" 'scanned=5 of=4' \
    'the terminal line names scanned and board-total as two distinct fields'

# --- a blocked issue is named, not silently dropped -------------------------
assert_contains "$out" 'SKIP #11' 'a blocked issue is not selectable'
assert_contains "$out" 'blocked by #99' 'and the reason names the blocker'

# --- another repository's issue is not ours ---------------------------------
# Organisation boards routinely hold several repositories. Starting work on a
# card that belongs to a different repository is the same defect the board
# reader had, and it costs a whole dispatched worker here.
assert_not_contains "$out" '#13' "another repository's card is excluded"

# --- work already in flight is not restarted --------------------------------
assert_not_contains "$out" '#14' 'an In progress issue is not offered again'

# --- grooming Backlog -------------------------------------------------------
set_board "$items" "$deps"
out=$(run --include-backlog)
assert_contains "$out" '#12  Backlog  groomable' 'Backlog is offered when asked for'
assert_contains "$out" 'selectable=2' 'and counted with the Ready ones'
# Ready before Backlog: an autonomous run should exhaust vetted work before it
# starts promoting unvetted work.
ready_pos=$(grep -n '#10' <<< "$out" | head -1 | cut -d: -f1)
backlog_pos=$(grep -n '#12' <<< "$out" | head -1 | cut -d: -f1)
if [[ -n $ready_pos && -n $backlog_pos ]] && ((ready_pos < backlog_pos)); then
    _pass 'Ready is offered before Backlog'
else
    _fail 'Ready is offered before Backlog' "ready=$ready_pos backlog=$backlog_pos"
fi

# --- a closed blocker does not block ----------------------------------------
set_board "$items" \
    '{"data":{"repository":{
      "i10":{"number":10,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}},
      "i11":{"number":11,"state":"OPEN","blockedBy":{"totalCount":1,"nodes":[{"number":99,"state":"CLOSED"}]}},
      "i12":{"number":12,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'
out=$(run)
assert_contains "$out" '#11  Ready  blocked' 'a blocker that closed no longer blocks'
assert_contains "$out" 'selectable=2' 'and the issue becomes selectable'

# --- a closed issue is never selectable -------------------------------------
set_board "$items" \
    '{"data":{"repository":{
      "i10":{"number":10,"state":"CLOSED","blockedBy":{"totalCount":0,"nodes":[]}},
      "i11":{"number":11,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}},
      "i12":{"number":12,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'
out=$(run)
assert_not_contains "$out" '#10' 'a closed issue still on the board is dropped'

# --- a truncated dependency read is treated as blocked ----------------------
# Reporting "no open blockers" from a page that did not contain them all is the
# same class of error as reporting a miss from a truncated board read.
set_board "$items" \
    '{"data":{"repository":{
      "i10":{"number":10,"state":"OPEN","blockedBy":{"totalCount":25,"nodes":[{"number":98,"state":"CLOSED"}]}},
      "i11":{"number":11,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}},
      "i12":{"number":12,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'
out=$(run)
assert_contains "$out" 'SKIP #10' 'a partially read dependency list is not called unblocked'
assert_contains "$out" 'treat as blocked' 'and says why it refused'

# --- a rejected query fails, it does not select -----------------------------
set_board "$items" '{"errors":[{"message":"Field blockedBy does not exist"}]}'
out=$(run)
assert_contains "$out" 'dependency query was rejected' 'a GraphQL error surfaces as an error'
assert_not_contains "$out" 'selectable=' 'and nothing is offered from a failed read'

# --- two calls, whatever the candidate count --------------------------------
set_board "$items" "$deps"
run --include-backlog > /dev/null
assert_eq '2' "$(grep -c . < "$tmp/gh.log")" 'the whole selection costs two calls'
assert_contains "$(cat "$tmp/gh.log")" 'i10: issue(number: 10)' 'dependencies are batched by alias'

# --- an empty board is an answer, not a failure -----------------------------
set_board '{"totalCount":0,"items":[]}' '{}'
rc=0
out=$(run) || rc=$?
assert_eq '0' "$rc" 'an empty board exits 0'
assert_contains "$out" 'nothing is eligible to start' 'and says so plainly'
assert_eq '1' "$(grep -c . < "$tmp/gh.log")" 'and does not pay for a dependency call'

# --- JSON is the same selection -------------------------------------------
set_board "$items" "$deps"
out=$(run --include-backlog --json)
assert_eq '10' "$(jq -r '.[0].number' <<< "$out")" 'JSON leads with the Ready issue'
assert_eq 'false' "$(jq -r '.[] | select(.number == 11) | .eligible' <<< "$out")" \
    'JSON marks the blocked issue ineligible'

# --- a truncated board read refuses to select -------------------------------
# The regression this issue exists for: a board bigger than --limit must never
# produce a plausible-looking subset. "candidates=3 of=123" reads as a
# whole-board scan when it is not -- the fix refuses to answer at all instead.
trunc_deps='{"data":{"repository":{}}}'

# limit-1: the read captured fewer cards than the board declares -- truncated.
set_board '{"totalCount":3,"items":[
  {"status":"Ready","content":{"number":20,"type":"Issue","title":"seen",
   "repository":"example-org/example-repo"}}]}' "$trunc_deps"
rc=0
out=$(run --limit 1) || rc=$?
assert_eq '1' "$rc" 'a truncated read exits nonzero'
assert_contains "$out" 'TRUNCATED: read 1 of 3 items' 'and names both counts'
assert_contains "$out" 'scanned=1 of=3' 'and the pre-selection line agrees'
assert_not_contains "$out" 'candidates=' 'no candidate line is printed'
assert_not_contains "$out" 'selectable=' 'no selectable line is printed'
assert_not_contains "$out" '#20' 'and no candidate/SKIP line for the seen card'
assert_eq '1' "$(grep -c . < "$tmp/gh.log")" 'a truncated read never pays for the dependency call'

# limit: the read captured exactly as many cards as the board declares -- not
# truncated; behaviour is unchanged from before this fix.
set_board '{"totalCount":1,"items":[
  {"status":"Ready","content":{"number":23,"type":"Issue","title":"exactly one",
   "repository":"example-org/example-repo"}}]}' \
  '{"data":{"repository":{
    "i23":{"number":23,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'
rc=0
out=$(run --limit 1) || rc=$?
assert_eq '0' "$rc" 'a full read at the declared total is not truncated'
assert_contains "$out" 'scanned=1 of=1' 'and reports the same distinct fields as before'
assert_contains "$out" '#23  Ready  exactly one' 'selection still runs normally'

# limit+1: the read captured more cards than the board declares (a stale or
# undercounted totalCount) -- not truncated; more data than promised is not a
# partial read.
set_board '{"totalCount":1,"items":[
  {"status":"Ready","content":{"number":21,"type":"Issue","title":"extra one",
   "repository":"example-org/example-repo"}},
  {"status":"Ready","content":{"number":22,"type":"Issue","title":"extra two",
   "repository":"example-org/example-repo"}}]}' \
  '{"data":{"repository":{
    "i21":{"number":21,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}},
    "i22":{"number":22,"state":"OPEN","blockedBy":{"totalCount":0,"nodes":[]}}}}}'
rc=0
out=$(run) || rc=$?
assert_eq '0' "$rc" 'more items than the declared total is not treated as truncation'
assert_contains "$out" 'scanned=2 of=1' 'and both counts are reported as read'

# --- cross-helper: pick-issues and board-list agree on the board total ------
# Both helpers read the identical `gh project item-list` response for the same
# board; they must not disagree about what it declared as the total.
board_list="$root/agentkit/skills/.shared/scripts/board-list.sh"
if [[ -x $board_list ]]; then
    set_board "$items" "$deps"
    pick_of=$(run | grep -o 'of=[0-9]*' | head -1 | cut -d= -f2)
    bl_out=$(PATH="$tmp/bin:$PATH" "$board_list" --repo-root "$repo" 2>&1)
    bl_of=$(grep -o 'of=[0-9]*' <<< "$bl_out" | head -1 | cut -d= -f2)
    assert_eq "$bl_of" "$pick_of" \
        'pick-issues and board-list report the same declared board total'
fi

# --- usage and environment -------------------------------------------------
assert_rc 2 'an unknown flag is a usage error' -- \
    env PATH="$tmp/bin:$PATH" "$script" --repo-root "$repo" --wat
bare="$tmp/norepo"
mkdir -p "$bare"
assert_rc 3 'a repository with no board is environment-blocked, not an error' -- \
    env PATH="$tmp/bin:$PATH" "$script" --repo-root "$bare"

finish
