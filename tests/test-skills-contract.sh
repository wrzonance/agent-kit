#!/usr/bin/env bash
# Suite: the preflight skills-path contract and its single fallback resolver.
# shellcheck disable=SC2016  # resolver text is intentionally literal
set -uo pipefail

TEST_NAME='skills-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
preflight="$skills/.shared/scripts/agent-preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
out=$("$preflight" --worktree "$repo" --no-write 2>/dev/null)
skills_line=$(grep '^skills=' <<< "$out")
assert_eq '1' "$(grep -c '^skills=' <<< "$out")" \
    'preflight emits exactly one skills contract line'
assert_eq "$skills" "${skills_line#skills= path=}" \
    'the contract path is the installed skills tree'
path_is_absolute=no
if [[ ${skills_line#skills= path=} == /* ]]; then
    path_is_absolute=yes
fi
assert_eq 'yes' "$path_is_absolute" \
    'the contract path is absolute'

packaged="$tmp/plugin/agentkit/skills"
mkdir -p "$packaged/.shared/scripts"
cp -- "$preflight" "$packaged/.shared/scripts/agent-preflight.sh"
chmod +x "$packaged/.shared/scripts/agent-preflight.sh"
packaged_out=$("$packaged/.shared/scripts/agent-preflight.sh" --worktree "$repo" --no-write 2>/dev/null)
assert_contains "$packaged_out" "skills= path=$packaged" \
    'a packaged preflight reports its packaged skills tree'

resolver_matches=$(find "$skills" -type f -name SKILL.md -exec grep -Hn 'agentkit=\$(find ' {} + || true)
resolver_lines=$(printf '%s\n' "$resolver_matches" | grep -c . || true)
assert_eq '1' "$resolver_lines" \
    'the skill tree keeps exactly one literal fallback resolver'

for skill in "$skills"/*/SKILL.md; do
    name=$(basename "$(dirname "$skill")")
    assert_contains "$(<"$skill")" 'skills= path=' \
        "$name documents the contract field"
    if [[ $name == onboard-repo ]]; then
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '1' "$resolver_count" \
            "$name owns the sole fallback resolver"
    else
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '0' "$resolver_count" \
            "$name does not repeat the fallback resolver"
    fi
done

finish
