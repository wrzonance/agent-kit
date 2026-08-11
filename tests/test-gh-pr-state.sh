#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='gh-pr-state'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":14,"isDraft":true,"mergeable":"MERGEABLE","headRefName":"feat/test","headRefOid":"abcdef0123456789","statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"coderabbitai","status":"IN_PROGRESS"},{"name":"lint","status":"COMPLETED","conclusion":"FAILURE"}]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[{"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"human quoted <!-- review-remote-pr:agent-doc --> marker","author":{"login":"reviewer"}}]}}]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/gh"

output=$(PATH="$tmp:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 14 --repo owner/repo)
assert_contains "$output" 'pr=14 draft=true mergeable=MERGEABLE head=feat/test sha=abcdef0' \
    'digest reports pull-request metadata'
assert_contains "$output" 'ci=1/3 failing pending=1 failing=1' \
    'digest reports check counts'
assert_contains "$output" 'threads: coderabbit=0 unresolved  code-quality=0 open  human=1' \
    'a marker mentioned mid-body remains human-visible'
assert_not_contains "$output" '{"number"' 'digest does not leak raw API JSON'

finish
