#!/usr/bin/env bash
# Suite: board-setup.sh creates and re-columns a board without losing statuses.
#
# The behaviour under test is the one that has already cost a real board its
# assignments. `updateProjectV2Field` with `singleSelectOptions` replaces the
# whole option set and matches nothing by name, so every item in every column --
# including columns whose names did not change -- comes back unassigned.
#
# A virgin-repo onboarding run rediscovered that mutation by introspecting the
# GraphQL schema and fired it, because nothing here offered a safer path. It
# only got away with it because the board was empty. These assertions are what
# make the safe path safe: snapshot before, restore after, by name.
set -uo pipefail

TEST_NAME='board-setup'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/board-setup.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/stub"
new_repo() {
    local d
    d=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$d" init -q
    printf '%s' "$d"
}

# A routing stub. CURRENT_OPTIONS and CURRENT_ITEMS are read at call time from
# files, so a test can describe the board it wants without rewriting the stub.
cat > "$tmp/stub/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "\$*" >> "$tmp/gh.log"
case "\$*" in
  *"repo view"*)          printf 'example-org/example-repo\n' ;;
  *"project create"*)     printf '{"number":42,"title":"example-repo"}\n' ;;
  *"project field-list"*) jq -n --argjson o "\$(cat "$tmp/options.json")" \
                            '{fields:[{id:"F_status",name:"Status",options:\$o}]}' ;;
  *"project item-list"*)  cat "$tmp/items.json" ;;
  *"project view"*)       printf '{"id":"PVT_project"}\n' ;;
  *"api graphql"*)        [[ ${GH_STUB_DRAIN_INPUT:-1} == 1 ]] && cat > /dev/null
                            jq -n --argjson o "\$(cat "$tmp/new-options.json")" \
                            '{data:{updateProjectV2Field:{projectV2Field:{id:"F_status",options:\$o}}}}' ;;
  *"project item-edit"*)  printf '%s\n' "\$*" >> "$tmp/edits.log"; printf '{}\n' ;;
  *"project link"*)       printf '{}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub/gh"

# The five canonical columns, as the mutation would return them: same names,
# NEW ids. That id change is exactly why a restore cannot reuse the snapshot's
# option ids and must match on name instead.
canonical_new='[{"id":"new-backlog","name":"Backlog"},{"id":"new-ready","name":"Ready"},
  {"id":"new-inprog","name":"In progress"},{"id":"new-inrev","name":"In review"},
  {"id":"new-done","name":"Done"}]'

set_board() {
    printf '%s' "$1" > "$tmp/options.json"
    printf '%s' "${2:-{\"items\":[]\}}" > "$tmp/items.json"
    printf '%s' "${3:-$canonical_new}" > "$tmp/new-options.json"
    : > "$tmp/edits.log"
    : > "$tmp/gh.log"
}
run() { PATH="$tmp/stub:$PATH" "$script" "$@" 2>&1; }

# --- creating a board -------------------------------------------------------
set_board '[{"id":"todo","name":"Todo"},{"id":"prog","name":"In Progress"},{"id":"done","name":"Done"}]'
repo=$(new_repo)
out=$(run --repo-root "$repo")
assert_contains "$out" 'created project 42' 'a board with no --project is created'
assert_contains "$out" 'Backlog Ready In progress In review Done' 'and gets the canonical columns'

# GitHub's default board is Todo / In Progress / Done. Onboarding that without
# re-columning it is what makes every later status move guess at a vocabulary.
assert_contains "$(cat "$tmp/gh.log")" 'api graphql' 'the default three columns are replaced'

# --- linking ----------------------------------------------------------------
# The run that prompted this helper created a board and never linked it, so the
# repository still reported "no board": bootstrap asks the REPO what it has,
# gets nothing, and falls back to prompting across every board the owner owns.
assert_contains "$(cat "$tmp/gh.log")" 'project link 42' 'a created board is linked to the repository'

set_board '[{"id":"todo","name":"Todo"}]'
repo=$(new_repo)
run --repo-root "$repo" --no-link > /dev/null
if grep -q 'project link' "$tmp/gh.log"; then
    _fail '--no-link skips the link' 'it linked anyway'
else
    _pass '--no-link skips the link'
fi

# --- the destructive case ---------------------------------------------------
# Four items in three columns, and the columns are being renamed around them.
populated='{"items":[
  {"id":"I1","status":"Todo"},{"id":"I2","status":"In Progress"},
  {"id":"I3","status":"Done"},{"id":"I4","status":"Done"}]}'
# The mutation answers with the same names and NEW ids -- that is the whole
# hazard, so the stub reproduces it rather than handing back the old ids.
renamed='[{"id":"new-todo","name":"Todo"},{"id":"new-inprog","name":"In Progress"},
  {"id":"new-done","name":"Done"},{"id":"new-ready","name":"Ready"}]'
set_board '[{"id":"todo","name":"Todo"},{"id":"prog","name":"In Progress"},{"id":"done","name":"Done"}]' \
    "$populated" "$renamed"
repo=$(new_repo)
out=$(run --repo-root "$repo" --project 9 --vocab 'Todo,In Progress,Done,Ready')

assert_contains "$out" 'replacing the columns clears all of them' \
    'a populated board is warned about before the mutation, not after'

# Read the board BEFORE mutating it. Afterwards there is nothing left to read:
# the assignments are gone and no call can say what they were.
snapshot_pos=$(grep -n 'project item-list' "$tmp/gh.log" | head -1 | cut -d: -f1)
mutate_pos=$(grep -n 'api graphql' "$tmp/gh.log" | head -1 | cut -d: -f1)
if [[ -n $snapshot_pos && -n $mutate_pos ]] && ((snapshot_pos < mutate_pos)); then
    _pass 'the snapshot is taken before the mutation'
else
    _fail 'the snapshot is taken before the mutation' "item-list=$snapshot_pos graphql=$mutate_pos"
fi

edits=$(cat "$tmp/edits.log")
assert_eq '4' "$(grep -c . <<< "$edits")" 'every item that had a status is re-assigned'
assert_contains "$out" 'restored 4 item status(es)' 'and the count is reported'

# By name, and to the NEW ids. Reusing the snapshot's ids would send every
# restore to an option that no longer exists.
assert_contains "$edits" '--id I2 --project-id PVT_project --field-id F_status --single-select-option-id new-inprog' \
    'an item is restored to the new option id for its old column name'
if grep -q 'single-select-option-id prog' <<< "$edits"; then
    _fail 'no restore uses a pre-mutation option id' 'it reused the stale id'
else
    _pass 'no restore uses a pre-mutation option id'
fi

# --- a column that does not survive -----------------------------------------
# "In Progress" is not in the new vocabulary. That item has nowhere to go, and
# saying so is the whole difference between a report and a silent loss.
set_board '[{"id":"todo","name":"Todo"},{"id":"prog","name":"In Progress"}]' \
    '{"items":[{"id":"I1","status":"Todo"},{"id":"I2","status":"In Progress"}]}' \
    '[{"id":"n-todo","name":"Todo"},{"id":"n-done","name":"Done"}]'
repo=$(new_repo)
out=$(run --repo-root "$repo" --project 9 --vocab 'Todo,Done')
assert_contains "$out" 'not one of the new columns; left unset' \
    'an item whose column was dropped is named, not dropped silently'
assert_contains "$out" '1 left unset' 'and counted separately from the restored ones'

# --- a non-draining GraphQL consumer ---------------------------------------
# The real gh CLI consumes --input, but a stub that exits before reading it can
# close the pipe while jq is still serialising a large request body. Keep this
# payload above the pipe buffer so the regression is deterministic rather than
# depending on CI scheduling.
set_board '[{"id":"a","name":"A"}]'
repo=$(new_repo)
large_column=$(printf '%131072s' '' | tr ' ' x)
out=$(GH_STUB_DRAIN_INPUT=0 run --repo-root "$repo" --project 9 --vocab "$large_column")
assert_not_contains "$out" 'Broken pipe' \
    'a non-draining GraphQL consumer does not leak jq Broken pipe output'

# --- already correct --------------------------------------------------------
# The mutation rewrites every option id even when the names are unchanged, so
# running it against a board that is already right is pure downside: a restore
# for no change at all.
set_board "$canonical_new" '{"items":[{"id":"I1","status":"Ready"}]}'
repo=$(new_repo)
out=$(run --repo-root "$repo" --project 9)
assert_contains "$out" 'already has exactly these columns' 'a correct board is left alone'
if grep -q 'api graphql' "$tmp/gh.log"; then
    _fail 'and no mutation is sent' 'it re-columned an already-correct board'
else
    _pass 'and no mutation is sent'
fi

# --- vocabulary parsing -----------------------------------------------------
# Split on commas only. "In progress" has a space in it, so whitespace is
# content here and a word-splitting parser silently invents columns.
set_board '[{"id":"a","name":"A"}]'
repo=$(new_repo)
out=$(run --repo-root "$repo" --project 9 --dry-run --vocab 'One thing,Two thing')
assert_contains "$out" 'to: One thing Two thing' 'a column name may contain spaces'
assert_contains "$out" 'dry run: nothing changed' 'and a dry run says it changed nothing'

# --- dry run is dry ---------------------------------------------------------
set_board '[{"id":"todo","name":"Todo"}]' '{"items":[{"id":"I1","status":"Todo"}]}'
repo=$(new_repo)
run --repo-root "$repo" --project 9 --dry-run > /dev/null
log=$(cat "$tmp/gh.log")
for forbidden in 'api graphql' 'item-edit' 'project link' 'project create'; do
    if grep -q -- "$forbidden" <<< "$log"; then
        _fail "dry run does not run: $forbidden" 'it did'
    else
        _pass "dry run does not run: $forbidden"
    fi
done

# --- discovery is scoped to --repo-root -------------------------------------
# Same defect bootstrap-repo.sh had: resolving the slug from the process working
# directory writes one repository's identity into another's board.
set_board "$canonical_new"
repo=$(new_repo)
out=$(cd "$tmp" && PATH="$tmp/stub:$PATH" "$script" --repo-root "$repo" --project 9 --dry-run 2>&1)
assert_contains "$out" 'example-org/example-repo' 'the slug comes from --repo-root, not the cwd'

# --- a board owned by someone other than the repository ---------------------
# A personal repository tracked on an organization's board. Defaulting the board
# owner to the repo owner is right for the common case and wrong for this one,
# which is exactly the case that made the flag necessary.
set_board '[{"id":"todo","name":"Todo"}]'
repo=$(new_repo)
out=$(run --repo-root "$repo" --owner other-org)
assert_contains "$out" 'created project 42' 'a board can be created under another owner'
assert_contains "$(cat "$tmp/gh.log")" 'project create --owner other-org' \
    'and the create names that owner, not the repository owner'
assert_contains "$(cat "$tmp/gh.log")" 'project link 42 --owner other-org --repo example-org/example-repo' \
    'while the link still names the repository it tracks'

finish
