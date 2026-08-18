#!/usr/bin/env bash
# Suite: move-github-project-item.sh cached fast path and self-healing.
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
  *"item-edit"*)
      [[ -n \${FAIL_EDIT:-} ]] && exit 1
      if [[ -n \${FAIL_STALE_ITEM:-} && "\$*" == *"PVTI_stale57"* ]]; then exit 1; fi
      if [[ -n \${FAIL_CACHED_ITEM:-} && "\$*" == *"PVTI_example57"* ]]; then exit 1; fi
      exit 0
      ;;
  *"project view"*)       printf '{"id":"PVT_kwDOAexample1","number":7}\n' ;;
  *"project field-list"*)
      if [[ -n \${CUSTOM_STATUS:-} ]]; then
          printf '{"fields":[{"id":"PVTSSF_custom","name":"Status","options":[{"id":"opt-ice","name":"Icebox"},{"id":"opt-ship","name":"Shipped"}]}]}\n'
      else
          cat "$here/fixtures/gh-field-list.json"
      fi
      ;;
  *"project item-list"*)
      [[ -n \${FAIL_ITEM_LIST:-} ]] && exit 1
      if [[ -n \${LARGE_BATCH:-} ]]; then
          jq '.items += [range(1; 10) as \$n | {id: ("PVTI_large" + (\$n | tostring)), content: {type: "Issue", number: \$n, repository: "example-org/example-repo", url: ("https://github.com/example-org/example-repo/issues/" + (\$n | tostring))}}]' "$here/fixtures/gh-item-list.json"
      elif [[ -n "\${CURRENT_STATUS:-}" ]]; then
          case \${STATUS_SHAPE:-direct} in
            direct)
              jq --arg status "\${CURRENT_STATUS:-}" '.items |= map(if .id == "PVTI_example57" then .status = \$status else . end)' "$here/fixtures/gh-item-list.json"
              ;;
            nodes)
              jq --arg status "\${CURRENT_STATUS:-}" '.items |= map(if .id == "PVTI_example57" then .fieldValues = {nodes: [{field: {name: "Status"}, name: \$status}]} else . end)' "$here/fixtures/gh-item-list.json"
              ;;
            array)
              jq --arg status "\${CURRENT_STATUS:-}" '.items |= map(if .id == "PVTI_example57" then .fieldValues = [{field: {name: "Status"}, name: \$status}] else . end)' "$here/fixtures/gh-item-list.json"
              ;;
            *) exit 1 ;;
          esac
      else
          cat "$here/fixtures/gh-item-list.json"
      fi
      ;;
  *"project list"*)
      [[ -n \${FAIL_PROJECT_LIST:-} ]] && exit 1
      if [[ -n \${EMPTY_PROJECT_LIST:-} ]]; then
          :
      elif [[ -n \${MULTI_BOARD:-} ]]; then
          printf '%s\\n' '{"projects":[{"number":7,"id":"PVT_kwDOAexample1","title":"Example Board"},{"number":8,"id":"PVT_kwDOAexample2","title":"Second Board"}]}'
      else
          cat "$here/fixtures/gh-project-list.json"
      fi
      ;;
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
{"schemaVersion":1,"repository":"example-org/example-repo","owner":"example-org",
 "project":{"number":7,"id":"PVT_kwDOAexample1","title":"Example Board"},
 "statusField":{"id":"PVTSSF_lADOAexampleB","name":"Status",
   "options":{"Backlog":"opt-backlog","Ready":"opt-ready",
              "In progress":"opt-inprog","In review":"opt-inrev","Done":"opt-done"}},
 "fingerprint":"sha256:seed"}
EOF
    cat > "$dir/.agent/cache/board-items.json" << 'EOF'
{"schemaVersion":1,"repository":"example-org/example-repo","owner":"example-org",
 "projectNumber":7,"project":"PVT_kwDOAexample1","items":{"57":"PVTI_example57"}}
EOF
    chmod 600 "$dir/.agent/board.json" "$dir/.agent/cache/board-items.json"
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

# The board helper parses live evidence with jq; a stripped parser must block
# before it can print a no-op or move result.
mkdir -p "$tmp/no-jq"
cp "$tmp/stub/gh" "$tmp/no-jq/gh"
chmod +x "$tmp/no-jq/gh"
repo=$(bare_repo)
set +e
missing_parser_output=$(PATH="$tmp/no-jq" /bin/bash "$mv_sh" \
    --repo-root "$repo" --repository example-org/example-repo \
    --issue-number 57 --status 'In progress' 2>"$tmp/move-parser.err")
missing_parser_rc=$?
set -e
assert_eq '1' "$missing_parser_rc" 'missing jq blocks board evidence parsing'
assert_eq '' "$missing_parser_output" 'missing jq emits no board move result'
assert_contains "$(cat "$tmp/move-parser.err")" 'jq' 'missing board parser error names jq'
assert_contains "$(cat "$tmp/move-parser.err")" 'evidence unavailable' \
    'missing board parser error says evidence is unavailable'

# --- warm board.json + item cache: exactly one mutation ---------------------
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
assert_contains "$out" 'board.json, 1 call' 'terminal line reports the warm-cache cost'
assert_contains "$out" 'moved #57' 'reports the move'

# The warm path deliberately never reads the card's current status before
# mutating it, so it reports "moved" even when the card is already at the
# target status -- pin this documented tradeoff (see usage's Output section
# and references/grooming.md) rather than letting it drift silently.
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(CURRENT_STATUS='In progress' STATUS_SHAPE=direct \
    run_mv "$repo" --issue-number 57 --status 'In progress' 2>&1)
assert_eq '1' "$(wc -l < "$tmp/gh.log")" \
    'a warm cache with an already-target card still costs exactly one gh call'
assert_contains "$out" 'moved #57 -> "In progress"' \
    'a warm cache reports moved even when the card is already at the target status'
assert_contains "$out" 'board.json, 1 call' \
    'the already-target warm move still reports the one-call cost'

# A fully warm batch -- every requested issue already in the item cache --
# costs one gh call per issue and never falls back to a live item-list read.
repo=$(seed_repo)
jq '.items["58"] = "PVTI_example58"' < "$repo/.agent/cache/board-items.json" \
    > "$repo/.agent/cache/tmp.json"
mv "$repo/.agent/cache/tmp.json" "$repo/.agent/cache/board-items.json"
chmod 600 "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --issue-number 58 --status Ready 2>&1)
assert_eq '2' "$(wc -l < "$tmp/gh.log")" \
    'a fully warm batch costs exactly one gh call per issue'
log=$(cat "$tmp/gh.log")
assert_eq '2' "$(grep -c 'item-edit' <<< "$log" || true)" \
    'a fully warm batch edits every issue'
assert_not_contains "$log" 'item-list' \
    'a fully warm batch never reads the board at all'
assert_contains "$out" 'moved #57' 'fully warm batch reports the first moved issue'
assert_contains "$out" 'moved #58' 'fully warm batch reports the second moved issue'
assert_eq '2' "$(grep -c 'board.json, 1 call' <<< "$out" || true)" \
    'each move in a fully warm batch reports the one-call cost'

# A cache bound to another repository must fail closed before mutation. The
# live board contains the requested repository's card and IDs; foreign cached
# values may not be sent to item-edit.
repo=$(seed_repo)
jq '.repository = "example-org/other-repo" | .project.id = "PVT_attacker" |
    .statusField.id = "PVTSSF_attacker" |
    .statusField.options.Ready = "opt-attacker"' \
    < "$repo/.agent/board.json" > "$repo/.agent/board.tmp"
mv "$repo/.agent/board.tmp" "$repo/.agent/board.json"
jq '.repository = "example-org/other-repo" | .project = "PVT_attacker" |
    .items["57"] = "PVTI_otherrepo57"' \
    < "$repo/.agent/cache/board-items.json" > "$repo/.agent/cache/items.tmp"
mv "$repo/.agent/cache/items.tmp" "$repo/.agent/cache/board-items.json"
chmod 600 "$repo/.agent/board.json" "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" '--project-id PVT_kwDOAexample1' \
    'foreign board cache falls back to the live project'
assert_contains "$log" '--id PVTI_example57' \
    'foreign item cache falls back to the requested-repository card'
assert_not_contains "$log" 'PVT_attacker' \
    'the foreign project never reaches item-edit'
assert_not_contains "$log" 'PVTI_otherrepo57' \
    'the foreign item never reaches item-edit'

# An unsafe board file is never trusted for mutation, even when its contents
# contain attacker-controlled project and field IDs.
repo=$(seed_repo)
jq '.project.id = "PVT_attacker" | .statusField.id = "PVTSSF_attacker" |
    .statusField.options.Ready = "opt-attacker"' \
    < "$repo/.agent/board.json" > "$repo/.agent/board.tmp"
mv "$repo/.agent/board.tmp" "$repo/.agent/board.json"
chmod 666 "$repo/.agent/board.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" '--project-id PVT_kwDOAexample1' \
    'an unsafe board file falls back to the live project'
assert_not_contains "$log" 'PVT_attacker' \
    'an unsafe board project never reaches item-edit'

# An unsafe item cache is not trusted for the mutation either; the one-read
# fallback selects the requested repository's live card before rewriting it.
repo=$(seed_repo)
jq '.items["57"] = "PVTI_attacker"' \
    < "$repo/.agent/cache/board-items.json" > "$repo/.agent/cache/items.tmp"
mv "$repo/.agent/cache/items.tmp" "$repo/.agent/cache/board-items.json"
chmod 666 "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" '--id PVTI_example57' \
    'an unsafe item cache falls back to the requested-repository card'
assert_not_contains "$log" 'PVTI_attacker' \
    'an unsafe item cache never reaches item-edit'

# Permission to replace a file comes from its containing directory, not the
# file: a group/world-writable .agent/cache/ is never trusted, even when
# board-items.json itself is perfectly safe.
repo=$(seed_repo)
chmod 777 "$repo/.agent/cache"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'item-list' \
    'a group/world-writable cache directory is not trusted for the fast path'
assert_contains "$log" '--id PVTI_example57' \
    'a group/world-writable cache directory still falls back to the requested-repository card'
chmod 700 "$repo/.agent/cache"

# The same applies to .agent/ itself: it backs both board.json and the item
# cache, so a writable .agent/ forces a full fallback to live discovery.
repo=$(seed_repo)
chmod 777 "$repo/.agent"
: > "$tmp/gh.log"
run_mv "$repo" --issue-number 57 --status Ready > /dev/null 2>&1
log=$(cat "$tmp/gh.log")
assert_contains "$log" 'project list' \
    'a group/world-writable .agent/ directory falls back to full discovery'
chmod 700 "$repo/.agent"

# A rejected cached mutation invalidates that issue's cache entry before the
# fallback. If project discovery is unavailable, the stale ID cannot remain for
# a second invocation to retry.
repo=$(seed_repo)
: > "$tmp/gh.log"
FAIL_CACHED_ITEM=1 FAIL_PROJECT_LIST=1 run_mv "$repo" --issue-number 57 --status Ready \
    > /dev/null 2>&1 || true
assert_eq 'null' "$(jq -r '.items["57"] // null' < "$repo/.agent/cache/board-items.json")" \
    'a rejected cached item is removed before fallback'
assert_eq '1' "$(grep -c -- '--id PVTI_example57' "$tmp/gh.log" || true)" \
    'the rejected cached item is attempted only once'

# A cache miss uses one live item-list read and still classifies an
# already-target card as a no-op.
for status_shape in direct nodes array; do
    repo=$(seed_repo)
    rm -f "$repo/.agent/cache/board-items.json"
    : > "$tmp/gh.log"
    out=$(CURRENT_STATUS='Ready' STATUS_SHAPE="$status_shape" run_mv "$repo" --issue-number 57 --status Ready 2>&1)
    assert_contains "$out" 'no-op: issue #57 already "Ready"' \
        "$status_shape status reports a redundant no-op"
    assert_eq '0' "$(grep -c 'item-edit' "$tmp/gh.log" || true)" \
        "$status_shape already-target status does not call item-edit"
done
assert_contains "$(<"$mv_sh")" 'no-op: issue #%s already "%s"' \
    'mover retains the exact already-target stdout shape'

# The cache-miss/process_project discovery path must honor the same direct
# Status shape and remain a no-op without issuing an item-edit mutation.
repo=$(bare_repo)
: > "$tmp/gh.log"
out=$(CURRENT_STATUS='Ready' STATUS_SHAPE=direct run_mv "$repo" \
    --issue-number 57 --status Ready 2>&1)
assert_contains "$out" 'no-op: issue #57 already "Ready"' \
    'process_project cache miss reports an already-target no-op'
assert_eq '0' "$(grep -c 'item-edit' "$tmp/gh.log" || true)" \
    'process_project cache miss does not call item-edit for an already-target issue'

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
assert_eq 'example-org/example-repo' "$(jq -r '.repository' < "$cache")" \
    'the item cache records the exact repository provenance'
assert_eq '7' "$(jq -r '.projectNumber' < "$cache")" \
    'the item cache records the project number provenance'
assert_eq '600' "$(stat -c '%a' "$cache")" \
    'the item cache writer applies a private mode'
assert_eq 'example-org/example-repo' "$(jq -r '.repository' < "$repo/.agent/board.json")" \
    'the board writer records the exact repository provenance'
assert_eq '600' "$(stat -c '%a' "$repo/.agent/board.json")" \
    'the board writer applies a private mode'

# --- fresh clone: board.json committed, item cache absent -----------------
# The discovery path is O(boards owned by the org), so an org with a dozen
# boards would pay a dozen item-list calls to move one card. board.json names
# the board, so go straight to it.
repo=$(seed_repo)
rm -f "$repo/.agent/cache/board-items.json"
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --status Ready 2>&1)
assert_eq '2' "$(wc -l < "$tmp/gh.log")" 'a fresh clone reads the declared board once before editing'
log=$(cat "$tmp/gh.log")
assert_not_contains "$log" 'project list' 'does not enumerate every board the owner has'
assert_contains "$log" 'item-list 7' 'goes straight to the declared board'
assert_contains "$out" 'board.json, 2 calls' 'reports which path it took'
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
assert_eq 'example-org/example-repo' "$(jq -r '.repository' < "$repo/.agent/board.json")" \
    'full discovery writes board repository provenance'
assert_eq '600' "$(stat -c '%a' "$repo/.agent/board.json")" \
    'full discovery writes a private board mode'

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

# --- batch moves share the one cache-miss read -----------------------------
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --issue-number 99 --status Ready 2>&1)
assert_contains "$out" 'moved #57' 'batch reports the first moved issue'
assert_contains "$out" 'moved #99' 'batch reports the second moved issue'
assert_eq '2' "$(grep -c 'board.json, 2 calls' <<< "$out" || true)" \
    'batch keeps the measured cache-miss suffix on each move'
assert_eq '2' "$(grep -c 'item-edit' "$tmp/gh.log" || true)" \
    'batch edits each issue'
assert_eq '1' "$(grep -c 'item-list' "$tmp/gh.log" || true)" \
    'batch shares item lookup'
assert_eq '0' "$(grep -c 'project view' "$tmp/gh.log" || true)" \
    'batch avoids project validation reads'
assert_eq '0' "$(grep -c 'field-list' "$tmp/gh.log" || true)" \
    'batch avoids Status validation reads'

# A large batch must preserve every terminal evidence line when stdout is
# captured through a pipe, and the summary makes any short capture visible.
repo=$(seed_repo)
: > "$tmp/large-batch.out"
LARGE_BATCH=1 run_mv "$repo" --issue-numbers 1,2,3,4,5,6,7,8,9 --status Ready 2>&1 |
    tee "$tmp/large-batch.out" > /dev/null
pipe_lines=$(awk 'END { print NR + 0 }' "$tmp/large-batch.out")
assert_eq '10' "$pipe_lines" 'a 9-issue batch emits nine evidence lines plus its summary through a pipe'
assert_eq '9' "$(grep -c '^moved #' "$tmp/large-batch.out" || true)" \
    'a piped large batch emits one moved line per issue'
assert_eq 'moved=9 no-op=0 of=9' "$(tail -n 1 "$tmp/large-batch.out")" \
    'a piped large batch ends with a completeness summary'

# A moved/no-op mixture terminates the moved issue and emits one terminal
# no-op for the issue absent from every board.
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-number 57 --issue-number 58 --status Ready 2>&1)
assert_contains "$out" 'moved #57' 'mixed batch keeps the moved outcome'
assert_contains "$out" 'no-op: issue #58 is not on any project board' \
    'mixed batch emits the absent issue no-op'
assert_eq '1' "$(grep -c -- '--id PVTI_example57' "$tmp/gh.log" || true)" \
    'mixed batch does not repeat the moved issue'

# Same-number cards on a shared board remain repository-scoped in a batch.
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(run_mv "$repo" --issue-numbers 57 --status Ready 2>&1)
assert_contains "$out" 'moved #57' 'CSV batch accepts one issue'
assert_contains "$(cat "$tmp/gh.log")" '--id PVTI_example57' \
    'CSV batch selects the requested repository card'
assert_not_contains "$(cat "$tmp/gh.log")" 'PVTI_otherrepo57' \
    'CSV batch never edits the same-number card from another repository'

# API failures are errors, not successful no-ops.
repo=$(bare_repo)
assert_rc 1 'project-list API failure exits 1' -- env FAIL_PROJECT_LIST=1 \
    GH_STUB_LOG="$tmp/gh.log" PATH="$tmp/stub:$PATH" \
    "$mv_sh" --repo-root "$repo" --repository example-org/example-repo \
    --issue-number 57 --status Ready

# --all-boards must bypass the single-board cache and update every matching card.
repo=$(seed_repo)
: > "$tmp/gh.log"
out=$(MULTI_BOARD=1 run_mv "$repo" --issue-number 57 --status Ready --all-boards 2>&1)
assert_eq '2' "$(grep -c 'item-edit' "$tmp/gh.log" || true)" \
    'all-boards updates the requested card on every board'
assert_contains "$out" 'project #7 "Example Board"' \
    'all-boards reports the first board move'
assert_contains "$out" 'project #8 "Second Board"' \
    'all-boards reports the second board move'

# An unreadable board is skipped so an unrelated board cannot abort dispatch.
repo=$(bare_repo)
: > "$tmp/gh.log"
out=$(FAIL_ITEM_LIST=1 run_mv "$repo" --issue-number 57 --status Ready 2>&1)
assert_contains "$out" 'Warning: could not list items for project #7; skipping it.' \
    'an unreadable board is reported and skipped'
assert_contains "$out" 'no-op: issue #57 is not on any project board' \
    'a skipped board leaves the issue with its terminal no-op'

# Empty project-list responses still emit one terminal result per requested issue.
repo=$(bare_repo)
out=$(EMPTY_PROJECT_LIST=1 run_mv "$repo" --issue-number 57 --issue-number 58 --status Ready 2>&1)
assert_contains "$out" 'no-op: issue #57 is not on any project board' \
    'an empty project response reports the first issue'
assert_contains "$out" 'no-op: issue #58 is not on any project board' \
    'an empty project response reports the second issue'

finish
