#!/usr/bin/env bash
# Suite: move-github-project-item.sh optimistic fast path and self-healing.
#
# Exit codes follow this script's own long-standing contract (0 move-or-no-op,
# 1 bad arguments or API error), not the tree-wide "2 = usage" convention. It
# predates that convention and its usage block documents 1; changing it would
# break callers for no benefit.
set -uo pipefail

TEST_NAME='move-project-item'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

mv_sh="$root/agentkit/skills/parallel-issues/scripts/move-github-project-item.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/stub"
cat > "$tmp/stub/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "\$*" >> "\${GH_STUB_LOG:-/dev/null}"
case "\$*" in
  *"item-edit"*)          [[ -n \${FAIL_EDIT:-} ]] && exit 1; exit 0 ;;
  *"project field-list"*) cat "$here/fixtures/gh-field-list.json" ;;
  *"project item-list"*)  cat "$here/fixtures/gh-item-list.json" ;;
  *"project list"*)       cat "$here/fixtures/gh-project-list.json" ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub/gh"

seed_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    cat > "$dir/.agent/board.json" << 'EOF'
{"schemaVersion":1,"owner":"example-org",
 "project":{"number":7,"id":"PVT_kwDOAexample1","title":"Example Board"},
 "statusField":{"id":"PVTSSF_lADOAexampleB","name":"Status",
   "options":{"Backlog":"opt-backlog","Ready":"opt-ready",
              "In progress":"opt-inprog","In review":"opt-inrev","Done":"opt-done"}},
 "fingerprint":"sha256:seed"}
EOF
    cat > "$dir/.agent/cache/board-items.json" << 'EOF'
{"schemaVersion":1,"project":"PVT_kwDOAexample1","items":{"57":"PVTI_example57"}}
EOF
    printf '%s' "$dir"
}

bare_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    printf '%s' "$dir"
}

run_mv() {
    local repo=$1
    shift
    GH_STUB_LOG="$tmp/gh.log" PATH="$tmp/stub:$PATH" \
        "$mv_sh" --repo-root "$repo" --repository example-org/example-repo "$@"
}

# --- fast path: exactly one gh call ---------------------------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --status 'In progress' 2>&1)
assert_eq '1' "$(wc -l < "$tmp/gh.log")" 'a warm cache costs exactly one gh call'
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'item-edit' 'the one call is item-edit'
assert_contains "$log" 'PVTI_example57' 'uses the cached item id'
assert_contains "$log" 'opt-inprog' 'uses the cached option id'
assert_not_contains "$log" 'field-list' 'does not re-resolve the Status field'
assert_not_contains "$log" 'item-list' 'does not re-scan the board'
assert_contains "$out" 'moved #57' 'reports the move'

# --- cache miss on the issue falls back -----------------------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 99 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'item-list' 'an uncached issue falls back to discovery'

# --- discovery warms the cache for next time -------------------------------
cache="$repo/.agent/cache/board-items.json"
assert_eq 'PVTI_example99' "$(jq -r '.items["99"] // "absent"' < "$cache")" \
    'a discovered item id is written back to the cache'
assert_eq 'PVTI_example57' "$(jq -r '.items["57"] // "absent"' < "$cache")" \
    'existing cache entries survive the write-back'

# --- fresh clone: board.json committed, item cache absent -----------------
# The discovery path is O(boards owned by the org), so an org with a dozen
# boards would pay a dozen item-list calls to move one card. board.json names
# the board, so go straight to it.
repo=$(seed_repo)
rm -f "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --status Ready 2>&1)
assert_eq '2' "$(wc -l < "$tmp/gh.log")" 'a fresh clone costs two gh calls, not seven'
log=$(cat "$tmp/gh.log")
assert_not_contains "$log" 'project list' 'does not enumerate every board the owner has'
assert_contains "$log" 'item-list 7' 'goes straight to the declared board'
assert_contains "$out" 'board.json, 2 calls' 'reports which path it took'
assert_eq 'PVTI_example57' "$(jq -r '.items["57"]' < "$repo/.agent/cache/board-items.json")" \
    'and warms the cache so the next move costs one'

# --- invalid status never reaches gh (fail closed) ------------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
assert_rc 1 'an unknown status is rejected' -- \
    env GH_STUB_LOG="$tmp/gh.log" PATH="$tmp/stub:$PATH" \
    "$mv_sh" --repo-root "$repo" --repository example-org/example-repo \
    --issue-number 57 --status 'Nonexistent Column'
assert_eq '0' "$(wc -l < "$tmp/gh.log")" 'an invalid status makes no gh call at all'

# --- self-heal on a rejected edit -----------------------------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(FAIL_EDIT=1 GH_STUB_LOG="$tmp/gh.log" PATH="$tmp/stub:$PATH" \
    "$mv_sh" --repo-root "$repo" --repository example-org/example-repo \
    --issue-number 57 --status Done 2>&1 || true)
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'field-list' 'a rejected edit triggers rediscovery'
assert_contains "$out" 'board changed' 'prints the regenerate-and-commit notice'
edits=$(grep -c 'item-edit' "$tmp/gh.log" || true)
assert_eq '2' "$edits" 'retries exactly once, never loops'

# --- no cache at all behaves exactly as before ----------------------------
repo=$(bare_repo)
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'project list' 'with no board.json it discovers as before'

# --- unrecognized schemaVersion is ignored, not fatal ---------------------
repo=$(seed_repo)
jq '.schemaVersion = 99' < "$repo/.agent/board.json" > "$repo/.agent/board.tmp"
mv "$repo/.agent/board.tmp" "$repo/.agent/board.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'project list' 'an unknown schemaVersion falls back to discovery'

# --- corrupt board.json is ignored, not fatal -----------------------------
repo=$(seed_repo)
printf 'not json at all\n' > "$repo/.agent/board.json"
: > "$tmp/gh.log"
assert_rc 0 'a corrupt board.json does not abort the move' -- \
    env GH_STUB_LOG="$tmp/gh.log" PATH="$tmp/stub:$PATH" \
    "$mv_sh" --repo-root "$repo" --repository example-org/example-repo \
    --issue-number 57 --status Ready

# --- cache scoped to its board --------------------------------------------
repo=$(seed_repo)
jq '.project = "PVT_someotherboard"' < "$repo/.agent/cache/board-items.json" \
    > "$repo/.agent/cache/tmp.json"
mv "$repo/.agent/cache/tmp.json" "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'item-list' 'an item cache from another board is not trusted'

# --- a non-canonical board column is accepted when board.json declares it --
repo=$(seed_repo)
jq '.statusField.options = {"Icebox":"opt-ice","Shipped":"opt-ship"}' \
    < "$repo/.agent/board.json" > "$repo/.agent/b.tmp"
mv "$repo/.agent/b.tmp" "$repo/.agent/board.json"
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --status 'Icebox' 2>&1)
assert_contains "$(cat "$tmp/gh.log")" 'opt-ice' 'a board-declared column outside the canonical five works'

finish
