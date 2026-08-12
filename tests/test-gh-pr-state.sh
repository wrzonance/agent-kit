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
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"advanced security","author":{"login":"github-advanced-security[bot]","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"scanner","author":{"login":"security-scanner","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"known provider","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"<!-- review-remote-pr:agent-reply -->\nagent bookkeeping","author":{"login":"agent-account","__typename":"User"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"human quoted <!-- review-remote-pr:agent-doc --> marker","author":{"login":"botond","__typename":"User"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"human missing author","author":null}]}}
        ]}}}}}'
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
assert_contains "$output" 'threads: coderabbit=1 unresolved  code-quality=0 open  human=2  generic=2' \
    'known and generic bot lanes stay separate from human threads'
assert_contains "$output" 'classification: known-provider=1 type=Bot=1 login-suffix=1 human=2' \
    'state dump excludes agent-marked-only replies from the human signal'
assert_not_contains "$output" '{"number"' 'digest does not leak raw API JSON'

# A missing parser is a blocked evidence check, never an empty digest.
mkdir -p "$tmp/no-jq"
cp "$tmp/gh" "$tmp/no-jq/gh"
chmod +x "$tmp/no-jq/gh"
set +e
missing_parser_output=$(PATH="$tmp/no-jq" /bin/bash \
    "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 14 --repo owner/repo 2>"$tmp/missing-parser.err")
missing_parser_rc=$?
set -e
assert_eq '1' "$missing_parser_rc" 'missing jq blocks PR evidence parsing'
assert_eq '' "$missing_parser_output" 'missing jq emits no empty digest'
assert_contains "$(cat "$tmp/missing-parser.err")" 'jq' 'missing parser error names jq'
assert_contains "$(cat "$tmp/missing-parser.err")" 'evidence unavailable' \
    'missing parser error says evidence is unavailable'

finish
