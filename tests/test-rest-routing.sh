#!/usr/bin/env bash
# Suite: REST-first routing contract scan.
set -uo pipefail

TEST_NAME='REST routing'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

scanner="$here/lint-rest-routing.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/compliant" "$tmp/violating"
cat >"$tmp/compliant/routes.sh" <<'EOF'
#!/usr/bin/env bash
gh api "repos/$REPO/issues/$NUMBER"
# routing-allow: projects-v2 -- board membership and Status are GraphQL-only
gh api graphql -f query="$PROJECT_QUERY"
# routing-allow: review-threads -- resolving a pull-request review thread
gh api graphql -f query="$THREAD_QUERY"
EOF
chmod +x "$tmp/compliant/routes.sh"
assert_rc 0 'REST and the two named GraphQL surfaces pass' -- "$scanner" "$tmp/compliant"

cat >"$tmp/violating/routes.sh" <<'EOF'
#!/usr/bin/env bash
gh issue view "$NUMBER" --json body,labels
gh api graphql -f query="$UNNAMED_QUERY"
EOF
chmod +x "$tmp/violating/routes.sh"
set +e
violations=$([ -x "$scanner" ] && "$scanner" "$tmp/violating" 2>&1)
violating_rc=$?
set -e
assert_eq '1' "$violating_rc" 'REST-able porcelain and unnamed GraphQL fail the scan'
assert_contains "$violations" 'REST-able data must use gh api repos/...' \
    'scan names the REST routing violation'
assert_contains "$violations" 'routing-allow: projects-v2' \
    'scan names the only accepted GraphQL reasons'

cat >"$tmp/violating/too-broad.sh" <<'EOF'
#!/usr/bin/env bash
# routing-allow: graphql -- this broad marker is not accepted
gh api graphql -f query="$QUERY"
EOF
set +e
"$scanner" "$tmp/violating" >/dev/null 2>&1
broad_rc=$?
set -e
assert_eq '1' "$broad_rc" 'a broad GraphQL allowlist marker is rejected'

finish
