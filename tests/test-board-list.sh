#!/usr/bin/env bash
# Suite: board-list.sh answers about a board that is bigger than one page.
#
# The motivating failure: a 230-item board read through a 200-item window
# reported "157 Done" while the same API response carried totalCount=230. The
# two numbers cannot both be right, nothing said which was, and the session that
# noticed spent six further calls hand-writing jq filters trying to settle it.
#
# So the cases here are about the boundary, not the happy path: what the script
# says when it did not read the whole board, and whether "where is issue N" can
# be answered without reconstructing the board each time.
#
# gh is stubbed. A real board large enough to truncate is not something a test
# can rely on existing, and the interesting case is precisely the large one.
set -uo pipefail

TEST_NAME='board-list'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/board-list.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/.agent"
printf '{"schemaVersion":1,"owner":"example-org","project":{"id":"PVT_x","number":7,"title":"example-board"}}\n' \
    > "$repo/.agent/board.json"
printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$repo/.agent/config.env"

# A stub board of TOTAL items that honours --limit the way the real API does:
# it reports the true totalCount and returns at most --limit items. Getting
# this asymmetry right is the entire point -- a stub that returned everything
# regardless of --limit could not reproduce the defect.
make_gh() {
    local dir="$tmp/bin.$1" total=$2
    mkdir -p "$dir"
    cat > "$dir/gh" << EOF
#!/usr/bin/env bash
limit=1000
prev=
for a in "\$@"; do
    [[ \$prev == --limit ]] && limit=\$a
    prev=\$a
done
jq -n --argjson total $total --argjson limit "\$limit" '
  { totalCount: \$total,
    items: [ range(\$total)
             | { status: (if . == 0 then "Ready" else "Done" end),
                 title: "item \(.)",
                 content: { number: (100 + .), type: "Issue", title: "item \(.)",
                            repository: "example-org/example-repo" } } ]
           [0:\$limit] }'
EOF
    chmod +x "$dir/gh"
    printf '%s' "$dir"
}

run_board() {
    local bin=$1
    shift
    env PATH="$bin:$PATH" "$script" --repo-root "$repo" "$@" 2>&1
}

# --- the whole board fits: no warning, and none deserved --------------------
bin=$(make_gh small 12)
out=$(run_board "$bin")
assert_contains "$out" 'board=example-board project=7 owner=example-org' \
    'a complete listing identifies the board by title'
assert_contains "$out" 'items=12 of=12' 'a complete read reports both counts agreeing'
assert_not_contains "$out" 'TRUNCATED' 'and does not warn about a board it read fully'

# --- the case this exists for ----------------------------------------------
# 230 items, a 200-item window. Every count printed is a count of the window.
bin=$(make_gh big 230)
out=$(run_board "$bin" --limit 200)
assert_contains "$out" 'items=200 of=230' 'a partial read reports what it read AND what exists'
assert_contains "$out" 'TRUNCATED' 'and says so in a word that cannot be skimmed past'
assert_contains "$out" '--limit 330' 'and gives the limit that would fix it'

# The default must be large enough that the common board never truncates --
# the warning is a backstop, not the normal experience.
out=$(run_board "$bin")
assert_contains "$out" 'items=230 of=230' 'the default limit reads a 230-item board whole'
assert_not_contains "$out" 'TRUNCATED' 'so the backstop stays quiet on an ordinary board'

# --- "where is issue N" is one call with one shape --------------------------
# Re-deriving this from the full board means writing a jq filter, and each
# hand-written filter differs from the last. Answers that look like they
# disagree are what turned a check into a loop.
out=$(run_board "$bin" --issue 100)
assert_contains "$out" 'board=example-board project=7 owner=example-org' \
    'an issue hit identifies the board by title'
assert_contains "$out" '#100  Ready' 'a single issue is answered directly'
assert_not_contains "$out" 'Done  (' 'without printing the board around it'

out=$(run_board "$bin" --issue 101)
assert_contains "$out" '#101  Done' 'and reports the column it is actually in'

# Absence is stated, not implied by empty output -- an empty answer reads as a
# failed command, which invites running it again.
out=$(run_board "$bin" --issue 999)
assert_contains "$out" 'board=example-board project=7 owner=example-org' \
    'an issue miss identifies the board by title'
assert_contains "$out" 'not on this board' 'an issue that is absent is said to be absent'

# An issue lookup over a truncated read cannot distinguish absent from unread,
# and must not present a miss as absence.
out=$(run_board "$bin" --issue 999 --limit 50)
assert_contains "$out" 'truncation, not absence' 'a miss in a partial read is qualified'

# A leading # is what a human types and what an issue reference looks like.
out=$(run_board "$bin" --issue '#100')
assert_contains "$out" '#100  Ready' 'a leading # is accepted'

# Same-number issues from different repositories must not be confused. The
# lookup is bound to the repository declared by the target checkout.
dupe_bin="$tmp/dupe-bin"
mkdir -p "$dupe_bin"
cat > "$dupe_bin/gh" << 'EOF'
#!/usr/bin/env bash
jq -n '{totalCount: 2, items: [
  {status: "Done", title: "wrong repo", content: {number: 42, type: "Issue", repository: "example-org/other-repo"}},
  {status: "Ready", title: "requested repo", content: {number: 42, type: "Issue", repository: "example-org/example-repo"}}
]}'
EOF
chmod +x "$dupe_bin/gh"
out=$(run_board "$dupe_bin" --issue 42)
assert_contains "$out" '#42  Ready  requested repo' 'same-number issues are matched by repository'
assert_not_contains "$out" 'wrong repo' 'a same-number issue from another repository is ignored'

# Older board metadata may not have a title. The title is descriptive only, so
# that metadata remains usable and leaves the existing field empty.
jq 'del(.project.title)' "$repo/.agent/board.json" > "$tmp/legacy-board.json"
mv "$tmp/legacy-board.json" "$repo/.agent/board.json"
out=$(run_board "$bin")
assert_contains "$out" 'board= project=7 owner=example-org' \
    'legacy metadata keeps an empty board title fallback'

assert_rc 2 'a non-numeric issue is a usage error' -- \
    env PATH="$bin:$PATH" "$script" --repo-root "$repo" --issue main

# --- Done is collapsed unless it is what was asked for -----------------------
# 184 of 230 items were Done on the board this was measured against. Printing
# them buries the four columns that answer "what should I pick up next".
out=$(run_board "$bin")
assert_contains "$out" 'Done  (229)' 'Done is still counted'
assert_contains "$out" 'not listed' 'but not enumerated by default'
assert_not_contains "$out" '#101  item 1' 'so a Done item does not appear in the default listing'

out=$(run_board "$bin" --status Done)
assert_contains "$out" '#101  item 1' 'asking for Done lists Done'

out=$(run_board "$bin" --all)
assert_contains "$out" '#101  item 1' '--all lists it too'

# A plain listing already has every fact it needs in board.json and its one
# project-item query. It must not spend a second request discovering the repo.
rm "$repo/.agent/config.env"
listing_bin="$tmp/listing-bin"
mkdir -p "$listing_bin"
cat > "$listing_bin/gh" <<EOF
#!/usr/bin/env bash
if [[ \${1:-} == repo ]]; then
    touch "$tmp/repo-view-called"
    exit 1
fi
jq -n '{totalCount: 1, items: [
  {status: "Ready", title: "listed item", content: {number: 300, type: "Issue"}}
]}'
EOF
chmod +x "$listing_bin/gh"
out=$(run_board "$listing_bin")
assert_contains "$out" 'items=1 of=1' 'a plain listing needs no repository lookup'
if [[ -e $tmp/repo-view-called ]]; then
    listing_repo_view=called
else
    listing_repo_view=not-called
fi
assert_eq not-called "$listing_repo_view" 'a plain listing makes only its project-item call'

# --- the environment cannot support the query -------------------------------
bare="$tmp/norepo"
mkdir -p "$bare"
assert_rc 3 'no board declared is exit 3, not a crash' -- \
    env PATH="$bin:$PATH" "$script" --repo-root "$bare"

finish
