#!/usr/bin/env bash
# Suite: move-github-project-item.sh live rebinding and self-healing.
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
  *"project view"*)       printf '{"id":"PVT_kwDOAexample1","number":7}\n' ;;
  *"project field-list"*)
      if [[ -n \${CUSTOM_STATUS:-} ]]; then
          printf '{"fields":[{"id":"PVTSSF_custom","name":"Status","options":[{"id":"opt-ice","name":"Icebox"},{"id":"opt-ship","name":"Shipped"}]}]}\n'
      else
          cat "$here/fixtures/gh-field-list.json"
      fi
      ;;
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

# --- committed IDs are rebound against live board data ---------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --status 'In progress' 2>&1)
assert_eq '4' "$(wc -l < "$tmp/gh.log")" 'a warm cache still validates all live IDs'
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'item-edit' 'the final call is item-edit'
assert_contains "$log" 'PVTI_example57' 'uses the live requested-repo item id'
assert_contains "$log" 'opt-inprog' 'uses the live option id'
assert_contains "$log" 'field-list' 're-resolves the Status field'
assert_contains "$log" 'item-list' 're-scans the board'
assert_contains "$out" 'moved #57' 'reports the move'

# An identical second move must not rewrite board.json just because generatedAt
# is fresh. Commit the first move so the second invocation can prove it leaves
# the repository clean as well as preserving the file byte-for-byte.
repo=$(seed_repo)
run_mv "$repo" --issue-number 57 --status 'In progress' > /dev/null 2>&1
git -C "$repo" add .agent
git -C "$repo" -c user.name='test' -c user.email='test@example.invalid' \
    commit -qm 'seed refreshed board metadata'
before=$(sha256sum "$repo/.agent/board.json")
sleep 1
run_mv "$repo" --issue-number 57 --status 'In progress' > /dev/null 2>&1
after=$(sha256sum "$repo/.agent/board.json")
assert_eq "$before" "$after" 'an identical second move preserves board.json bytes'
assert_eq '' "$(git -C "$repo" status --short)" \
    'an identical second move leaves the repository clean'

# The known-board path validates against live metadata; after its successful
# move, it must persist that data rather than retaining stale mutation hints.
repo=$(seed_repo)
jq '.statusField.id = "PVTSSF_stale" | .statusField.options.Ready = "opt-stale"' \
    < "$repo/.agent/board.json" > "$repo/.agent/board.tmp"
mv "$repo/.agent/board.tmp" "$repo/.agent/board.json"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
assert_eq 'PVTSSF_lADOAexampleB' "$(jq -r '.statusField.id' < "$repo/.agent/board.json")" \
    'a known-board move refreshes the live Status field id'
assert_eq 'opt-ready' "$(jq -r '.statusField.options.Ready' < "$repo/.agent/board.json")" \
    'and refreshes the live Status option id'

# A forged cache item must never be sent to item-edit. The live board contains
# both repositories at #57; only the requested repository's item is valid.
repo=$(seed_repo)
jq '.items["57"] = "PVTI_otherrepo57"' < "$repo/.agent/cache/board-items.json" \
    > "$repo/.agent/cache/items.tmp"
mv "$repo/.agent/cache/items.tmp" "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" '--id PVTI_example57' 'rebinds a forged cache entry to the live requested-repo item'
assert_not_contains "$log" 'PVTI_otherrepo57' 'never edits the forged unrelated item'

# Forged project, field, and option IDs are likewise hints only. A mismatched
# project forces the normal live project-list path, which still edits only the
# real project and its live Status field.
repo=$(seed_repo)
jq '.project.id = "PVT_attacker" | .statusField.id = "PVTSSF_attacker" |
    .statusField.options.Ready = "opt-attacker"' \
    < "$repo/.agent/board.json" > "$repo/.agent/board.tmp"
mv "$repo/.agent/board.tmp" "$repo/.agent/board.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" '--project-id PVT_kwDOAexample1' 'rebinds a forged project ID to the live project'
assert_contains "$log" '--field-id PVTSSF_lADOAexampleB' 'rebinds a forged Status field ID'
assert_contains "$log" '--single-select-option-id opt-ready' 'rebinds a forged option ID'
assert_not_contains "$log" 'PVT_attacker' 'never mutates the forged project'
assert_eq 'PVT_kwDOAexample1' "$(jq -r '.project.id' < "$repo/.agent/board.json")" \
    'a discovery move refreshes the live project id'
assert_eq 'PVTSSF_lADOAexampleB' "$(jq -r '.statusField.id' < "$repo/.agent/board.json")" \
    'and refreshes the live Status metadata'

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
assert_eq '4' "$(wc -l < "$tmp/gh.log")" 'a fresh clone validates the declared board in four calls'
log=$(cat "$tmp/gh.log")
assert_not_contains "$log" 'project list' 'does not enumerate every board the owner has'
assert_contains "$log" 'item-list 7' 'goes straight to the declared board'
assert_contains "$out" 'board.json, 4 calls' 'reports which path it took'
assert_eq 'PVTI_example57' "$(jq -r '.items["57"]' < "$repo/.agent/cache/board-items.json")" \
    'and refreshes the cache with the live item id'

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
out=$(CUSTOM_STATUS=1 run_mv "$repo" --issue-number 57 --status 'Icebox' 2>&1)
assert_contains "$(cat "$tmp/gh.log")" 'opt-ice' 'a board-declared column outside the canonical five works'

finish
