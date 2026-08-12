#!/usr/bin/env bash
# Contract fixtures for forge-author classification and the three routing lanes.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='review author classification'

helper="$root/agentkit/skills/review-remote-pr/scripts/classify-author.sh"
fixture="$here/fixtures/review-author-classification.json"
skill="$root/agentkit/skills/review-remote-pr/SKILL.md"

assert_eq yes "$(test -x "$helper" && printf yes || printf no)" \
    'classifier helper is executable'
skill_text=$(<"$skill")
assert_contains "$skill_text" 'generic automated finding is an automated B-item' \
    'generic findings use the B namespace'
assert_contains "$skill_text" 'H labels are human-only' \
    'human labels remain separate from bot findings'
assert_contains "$skill_text" 'author.__typename == "Bot"' \
    'routing requires an authoritative forge type signal'

while IFS=$'\t' read -r name author; do
    expected=$(jq -c --arg n "$name" '.[] | select(.name == $n) | .want' "$fixture")
    got=$(printf '%s\n' "$author" | "$helper")
    for field in lane signal automated provider; do
        want=$(jq -r --arg f "$field" '.[$f] // ""' <<< "$expected")
        actual=$(jq -r --arg f "$field" '.[$f] // ""' <<< "$got")
        assert_eq "$want" "$actual" "$name classification field $field"
    done
done < <(jq -r '.[] | [.name, (.author | tojson)] | @tsv' "$fixture")

finish
