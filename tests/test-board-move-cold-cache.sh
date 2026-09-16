#!/usr/bin/env bash
# Regression: the public board-move command must discover and persist the
# repository-linked board when .agent/board.json is absent.
set -uo pipefail

TEST_NAME='board-move-cold-cache'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

mover="$root/agentkit/skills/parallel-issues/scripts/move-github-project-item.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
bin="$tmp/bin"
log="$tmp/gh.log"
mkdir -p "$repo/.agent" "$bin"
git -C "$repo" init -q

cat > "$bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${GH_STUB_LOG:?}"
case "$*" in
  *'api graphql'*)
    printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[{"id":"PVT_repo_board","number":7,"title":"Repository Board","closed":false,"owner":{"login":"example-org"}}]}}}}'
    ;;
  *'project field-list 7'*)
    printf '%s\n' '{"fields":[{"id":"PVTSSF_status","name":"Status","options":[{"id":"opt-ready","name":"Ready"},{"id":"opt-inprog","name":"In progress"}]}]}'
    ;;
  *'project item-list 7'*)
    printf '%s\n' '{"totalCount":1,"items":[{"id":"PVTI_781","status":"Ready","content":{"type":"Issue","number":781,"repository":"example-org/example-repo","url":"https://github.com/example-org/example-repo/issues/781"}}]}'
    ;;
  *'project item-edit'*)
    exit 0
    ;;
  *'project list'*)
    printf '%s\n' '{"projects":[{"id":"PVT_repo_board","number":7,"title":"Repository Board"}]}'
    ;;
  *)
    printf '%s\n' '{}'
    ;;
esac
EOF

chmod +x -- "$bin/gh"
: > "$log"
SECONDS=0
out=$(GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
rc=$?
elapsed=$SECONDS

assert_eq 0 "$rc" 'one cold-cache public invocation succeeds'
assert_contains "$out" 'board: cache cold, discovered project #7 "Repository Board" (written .agent/board.json)' \
    'cold discovery reports the project and cache write'
assert_contains "$out" 'moved #781 -> "In progress"' \
    'the same invocation completes the requested move'
assert_not_contains "$(cat -- "$log")" 'project list' \
    'cold discovery never enumerates unrelated organization boards'
assert_contains "$(cat -- "$log")" 'api graphql' \
    'cold discovery asks the repository for its linked board'
assert_eq true "$([[ $elapsed -le 15 ]] && printf true || printf false)" \
    'the cold move completes within fifteen seconds'

board="$repo/.agent/board.json"
assert_eq true "$([[ -f $board ]] && printf true || printf false)" \
    'cold discovery writes .agent/board.json'
if [[ -f $board ]]; then
    assert_eq example-org/example-repo "$(jq -r '.repository' < "$board")" \
        'the cache records exact repository provenance'
    assert_eq example-org "$(jq -r '.owner' < "$board")" \
        'the cache records the linked project owner'
    assert_eq 7 "$(jq -r '.project.number' < "$board")" \
        'the cache records the discovered project number'
    assert_eq PVT_repo_board "$(jq -r '.project.id' < "$board")" \
        'the cache records the discovered project id'
    assert_eq opt-inprog "$(jq -r '.statusField.options["In progress"]' < "$board")" \
        'the cache records the discovered Status option ids'
    assert_eq 600 "$(stat -c '%a' -- "$board")" \
        'the cache is private'
fi

# A cold-cache write must stay inside the requested repository. A symlinked
# .agent directory cannot redirect the atomic writer to another location.
symlink_repo="$tmp/symlink-repo"
outside_agent="$tmp/outside-agent"
mkdir -p "$symlink_repo" "$outside_agent"
git -C "$symlink_repo" init -q
ln -s "$outside_agent" "$symlink_repo/.agent"
: > "$log"
set +e
symlink_out=$(GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$symlink_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
symlink_rc=$?
set -e
assert_eq 1 "$symlink_rc" 'a symlinked .agent directory blocks cold-cache discovery'
assert_contains "$symlink_out" 'Could not discover the project linked to example-org/example-repo' \
    'the blocked cache write returns a terminal discovery error'
assert_eq false "$([[ -e $outside_agent/board.json ]] && printf true || printf false)" \
    'a symlink cannot redirect board.json outside the repository'
assert_not_contains "$(cat -- "$log")" 'project item-edit' \
    'a blocked cache write performs no mutation'

finish
