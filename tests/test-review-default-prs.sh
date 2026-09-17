#!/usr/bin/env bash
# Suite: a bare review invocation rehydrates the newest run's opened PRs.
# shellcheck disable=SC2016  # contract snippets intentionally retain shell variables/backticks
set -uo pipefail

TEST_NAME='review-default-prs'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
text=$(<"$skill")
normalized=$(tr '\n' ' ' <<<"$text" | tr -s '[:space:]' ' ')

assert_contains "$normalized" 'run-state.sh" latest --repo-root "$contract_root" --path opened_prs' \
    'a bare invocation reads opened PRs from the latest durable run'
assert_contains "$normalized" '.value | type == "array"' \
    'the defaulting recipe requires an array value'
assert_contains "$normalized" 'all(.[]; type == "number" and . > 0 and floor == .)' \
    'the defaulting recipe accepts only positive integer PR numbers'
assert_contains "$normalized" 'unique | length' \
    'the defaulting recipe rejects duplicate PR numbers'
assert_contains "$normalized" 'review: defaulting to PRs' \
    'the defaulting recipe prints the required operator-visible message'
assert_contains "$normalized" 'from run' \
    'the defaulting message identifies the selected run'
assert_contains "$normalized" 'exit `11` or a present empty array' \
    'only absent or empty durable state takes the single-question path'
assert_contains "$normalized" 'Evidence errors from `latest` are blocking' \
    'malformed or unavailable evidence fails closed'
assert_not_contains "$normalized" 'PR number** (required) — passed as arg or ask once if missing' \
    'the old unconditional missing-PR question rule is removed'

finish
