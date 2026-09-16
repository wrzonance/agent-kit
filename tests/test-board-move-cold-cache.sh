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
  *'projectsV2(first:20'*)
    case ${LINKED_MODE:-single} in
      multiple)
        printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[{"id":"PVT_repo_board","number":7,"title":"Repository Board","closed":false,"owner":{"login":"example-org"}},{"id":"PVT_second","number":8,"title":"Second Board","closed":false,"owner":{"login":"example-org"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
        ;;
      none)
        printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
        ;;
      paged)
        printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[{"id":"PVT_closed","number":1,"title":"Closed","closed":true,"owner":{"login":"example-org"}}],"pageInfo":{"hasNextPage":true,"endCursor":"page-1"}}}}}'
        printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[{"id":"PVT_page_two","number":21,"title":"Page Two Board","closed":false,"owner":{"login":"example-org"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
        ;;
      *)
        printf '%s\n' '{"data":{"repository":{"projectsV2":{"nodes":[{"id":"PVT_repo_board","number":7,"title":"Repository Board","closed":false,"owner":{"login":"example-org"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
        ;;
    esac
    ;;
  *'api graphql'*)
    membership=${MEMBERSHIP_PROJECT:-none}
    if [[ $membership == none ]]; then
        printf '%s\n' '{"data":{"repository":{"issue":{"projectItems":{"nodes":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'
    else
        case $membership in
          8) pid=PVT_second; title='Second Board' ;;
          9) pid=PVT_unlinked; title='Unlinked Board' ;;
          *) pid=PVT_repo_board; title='Repository Board' ;;
        esac
        issue_id=781
        [[ -z ${MIXED_BATCH:-} || $* != *'number=782'* ]] || issue_id=782
        jq -n --argjson number "$membership" --arg id "$pid" --arg title "$title" \
          --arg item_id "PVTI_$issue_id" \
          '{data:{repository:{issue:{projectItems:{nodes:[{id:$item_id,project:{id:$id,number:$number,title:$title,owner:{login:"example-org"}},fieldValueByName:{name:"Ready",optionId:"opt-ready"}}],pageInfo:{hasNextPage:false,endCursor:null}}}}}}'
    fi
    ;;
  *'project field-list'*)
    if [[ -n ${NO_STATUS:-} ]]; then
        printf '%s\n' '{"fields":[{"id":"PVTF_title","name":"Title"}]}'
    else
        printf '%s\n' '{"fields":[{"id":"PVTSSF_status","name":"Status","options":[{"id":"opt-ready","name":"Ready"},{"id":"opt-inprog","name":"In progress"}]}]}'
    fi
    ;;
  *'project item-list'*)
    if [[ -n ${LINKED_PROJECT_MISS:-} && $* == *'project item-list 7 '* ]]; then
        printf '%s\n' '{"totalCount":0,"items":[]}'
    elif [[ -n ${MIXED_BATCH:-} && $* == *'project item-list 9 '* ]]; then
        printf '%s\n' '{"totalCount":1,"items":[{"id":"PVTI_782","status":"Ready","content":{"type":"Issue","number":782,"repository":"example-org/example-repo","url":"https://github.com/example-org/example-repo/issues/782"}}]}'
    else
        printf '%s\n' '{"totalCount":1,"items":[{"id":"PVTI_781","status":"Ready","content":{"type":"Issue","number":781,"repository":"example-org/example-repo","url":"https://github.com/example-org/example-repo/issues/781"}}]}'
    fi
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
set +e
assert_eq 1 "$symlink_rc" 'a symlinked .agent directory blocks cold-cache discovery'
assert_contains "$symlink_out" 'Could not discover the project linked to example-org/example-repo' \
    'the blocked cache write returns a terminal discovery error'
assert_eq false "$([[ -e $outside_agent/board.json ]] && printf true || printf false)" \
    'a symlink cannot redirect board.json outside the repository'
assert_not_contains "$(cat -- "$log")" 'project item-edit' \
    'a blocked cache write performs no mutation'

# Multiple linked boards are selected by the issue's actual membership.
multi_repo="$tmp/multi-repo"
mkdir -p "$multi_repo/.agent"
git -C "$multi_repo" init -q
: > "$log"
multi_out=$(LINKED_MODE=multiple MEMBERSHIP_PROJECT=8 GH_STUB_LOG="$log" PATH="$bin:$PATH" \
    "$mover" --repo-root "$multi_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
multi_rc=$?
assert_eq 0 "$multi_rc" 'issue membership resolves multiple linked projects'
assert_contains "$multi_out" 'moved #781 -> "In progress" on project #8 "Second Board"' \
    'the membership-selected linked project is moved'
assert_eq 8 "$(jq -r '.project.number // empty' "$multi_repo/.agent/board.json" 2>/dev/null)" \
    'the membership-selected project is cached'

# A board holding the issue remains discoverable even when it is not linked to
# the repository; no organization-wide project enumeration is needed.
unlinked_repo="$tmp/unlinked-repo"
mkdir -p "$unlinked_repo/.agent"
git -C "$unlinked_repo" init -q
: > "$log"
unlinked_out=$(LINKED_MODE=none MEMBERSHIP_PROJECT=9 GH_STUB_LOG="$log" PATH="$bin:$PATH" \
    "$mover" --repo-root "$unlinked_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
unlinked_rc=$?
assert_eq 0 "$unlinked_rc" 'issue membership discovers an unlinked project'
assert_contains "$unlinked_out" 'moved #781 -> "In progress" on project #9 "Unlinked Board"' \
    'the unlinked membership board is moved'
assert_not_contains "$(cat -- "$log")" 'project list' \
    'unlinked discovery never enumerates organization projects'

# Missing Status metadata is an existing terminal no-op, not a discovery error.
no_status_repo="$tmp/no-status-repo"
mkdir -p "$no_status_repo/.agent"
git -C "$no_status_repo" init -q
no_status_out=$(NO_STATUS=1 GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$no_status_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
no_status_rc=$?
assert_eq 0 "$no_status_rc" 'a cold board without Status is a successful no-op'
assert_contains "$no_status_out" 'has no Status field' \
    'the cold board preserves the existing no-Status evidence'

# Cache persistence is optional outside a checkout and in a read-only cache;
# the live board move still completes and an empty root never becomes /.agent.
outside_repo="$tmp/outside-repo"
mkdir -p "$outside_repo"
: > "$log"
outside_out=$(cd -- "$outside_repo" && GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo example-org/example-repo --issue-number 781 --status 'In progress' 2>&1)
outside_rc=$?
assert_eq 0 "$outside_rc" 'a cacheless move outside a checkout succeeds'
assert_contains "$outside_out" 'moved #781 -> "In progress"' \
    'the cacheless invocation still moves the issue'
assert_eq false "$([[ -e /.agent/board.json ]] && printf true || printf false)" \
    'an empty repository root never targets /.agent'

readonly_repo="$tmp/readonly-repo"
mkdir -p "$readonly_repo/.agent"
git -C "$readonly_repo" init -q
chmod 500 "$readonly_repo/.agent"
readonly_out=$(GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$readonly_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
readonly_rc=$?
chmod 700 "$readonly_repo/.agent"
assert_eq 0 "$readonly_rc" 'a read-only board cache does not block the move'
assert_contains "$readonly_out" 'moved #781 -> "In progress"' \
    'the read-only cache path preserves live mutation behavior'

# Repository-linked projects are paginated before uniqueness is decided.
paged_repo="$tmp/paged-repo"
mkdir -p "$paged_repo/.agent"
git -C "$paged_repo" init -q
: > "$log"
paged_out=$(LINKED_MODE=paged GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$paged_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
paged_rc=$?
assert_eq 0 "$paged_rc" 'linked-board discovery consumes every page'
assert_contains "$paged_out" 'project #21 "Page Two Board"' \
    'the open project on the second page is selected'
assert_contains "$(cat -- "$log")" 'api graphql --paginate' \
    'repository project discovery requests GraphQL pagination'

# Project discovery depends only on gh and jq. Cache persistence tools may be
# unavailable, but selecting the live project and moving its issue still work.
missing_cache_tools_env="$tmp/missing-cache-tools.bash"
cat > "$missing_cache_tools_env" <<'EOF'
command() {
    if [[ ${1:-} == -v && ${2:-} =~ ^(sha256sum|date|mktemp)$ ]]; then
        return 1
    fi
    builtin command "$@"
}
EOF
cacheless_tools_repo="$tmp/cacheless-tools-repo"
mkdir -p "$cacheless_tools_repo/.agent"
git -C "$cacheless_tools_repo" init -q
: > "$log"
cacheless_tools_out=$(BASH_ENV="$missing_cache_tools_env" GH_STUB_LOG="$log" \
    PATH="$bin:$PATH" "$mover" --repo-root "$cacheless_tools_repo" \
    --repo example-org/example-repo --issue-number 781 --status 'In progress' 2>&1)
cacheless_tools_rc=$?
assert_eq 0 "$cacheless_tools_rc" 'missing cache-only tools do not block discovery'
assert_contains "$cacheless_tools_out" 'moved #781 -> "In progress"' \
    'missing cache-only tools preserve the live move'
assert_contains "$cacheless_tools_out" '(cache unavailable)' \
    'missing cache-only tools report optional persistence as unavailable'
assert_contains "$(cat -- "$log")" 'project item-edit' \
    'missing cache-only tools still reach the requested mutation'

# A unique linked project is only an initial candidate. When the issue is not
# on it, the issue's actual unlinked project membership must be selected.
linked_miss_repo="$tmp/linked-miss-repo"
mkdir -p "$linked_miss_repo/.agent"
git -C "$linked_miss_repo" init -q
: > "$log"
linked_miss_out=$(LINKED_PROJECT_MISS=1 MEMBERSHIP_PROJECT=9 \
    GH_STUB_LOG="$log" PATH="$bin:$PATH" "$mover" \
    --repo-root "$linked_miss_repo" --repo example-org/example-repo \
    --issue-number 781 --status 'In progress' 2>&1)
linked_miss_rc=$?
assert_eq 0 "$linked_miss_rc" 'a linked-project miss falls back to issue memberships'
assert_contains "$linked_miss_out" \
    'moved #781 -> "In progress" on project #9 "Unlinked Board"' \
    'the issue is moved on its actual unlinked membership project'
assert_contains "$(cat -- "$log")" 'projectItems' \
    'a linked-project miss reads the issue-owned memberships'

# A linked-board match for one issue must not hide another requested issue's
# unlinked membership in the same batch.
mixed_repo="$tmp/mixed-repo"
mkdir -p "$mixed_repo/.agent"
git -C "$mixed_repo" init -q
: > "$log"
mixed_out=$(MIXED_BATCH=1 MEMBERSHIP_PROJECT=9 GH_STUB_LOG="$log" PATH="$bin:$PATH" \
    "$mover" --repo-root "$mixed_repo" --repo example-org/example-repo \
    --issue-number 781 --issue-number 782 --status 'In progress' 2>&1)
mixed_rc=$?
assert_eq 0 "$mixed_rc" 'mixed linked and unlinked memberships succeed'
assert_contains "$mixed_out" 'moved #781 -> "In progress" on project #7 "Repository Board"' \
    'the linked-board issue keeps its completed move'
assert_contains "$mixed_out" 'moved #782 -> "In progress" on project #9 "Unlinked Board"' \
    'the unresolved issue moves on its actual unlinked project'
assert_not_contains "$mixed_out" 'no-op: issue #782 is not on any project board' \
    'the mixed batch never drops the unresolved issue as unboarded'
assert_eq 2 "$(grep -c 'project item-edit' "$log" || true)" \
    'the mixed batch mutates each issue exactly once'

finish
