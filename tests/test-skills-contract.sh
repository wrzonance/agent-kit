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

onboard="$skills/onboard-repo/SKILL.md"
onboard_text=$(<"$onboard")
assert_contains "$onboard_text" 'AGENTS.md' \
    'onboarding reviews the repository instruction files'
assert_contains "$onboard_text" 'CLAUDE.md' \
    'onboarding includes the other common instruction file'
assert_contains "$onboard_text" 'untrusted data' \
    'instruction-file content is treated as repository data'
assert_contains "$onboard_text" 'Conflicting' \
    'onboarding classifies conflicting guidance'
assert_contains "$onboard_text" 'Duplicated' \
    'onboarding classifies duplicated guidance'
assert_contains "$onboard_text" 'Repo-specific' \
    'onboarding preserves repository-specific guidance'
assert_contains "$onboard_text" 'discover equivalents' \
    'onboarding discovers equivalent instruction files beyond the examples'
assert_contains "$onboard_text" 'proposed diff' \
    'onboarding emits a proposed diff'
assert_contains "$onboard_text" 'must not delete, rewrite' \
    'onboarding prohibits deleting or rewriting instruction files'
assert_contains "$onboard_text" 'explicitly retained' \
    'onboarding retains repository-specific guidance'

assert_line_order() {
    local label=$1 first=$2 second=$3
    if [[ -n $first && -n $second && $first -lt $second ]]; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n' "$label" >&2
        exit 1
    fi
}

step_two_line=$(grep -m1 -n '^## Step 2 ' "$onboard" | cut -d: -f1)
review_line=$(grep -m1 -in 'review existing instructions' "$onboard" | cut -d: -f1)
write_line=$(grep -m1 -n '^"\$shared/bootstrap-repo\.sh"$' "$onboard" | cut -d: -f1)
conflicting_line=$(grep -m1 -n '^- \*\*Conflicting\*\*' "$onboard" | cut -d: -f1)
duplicated_line=$(grep -m1 -n '^- \*\*Duplicated\*\*' "$onboard" | cut -d: -f1)
repo_specific_line=$(grep -m1 -n '^- \*\*Repo-specific\*\*' "$onboard" | cut -d: -f1)

assert_line_order 'instruction review precedes the config write section' \
    "$review_line" "$step_two_line"
assert_line_order 'approval-gated review precedes the non-dry-run bootstrap write' \
    "$review_line" "$write_line"
assert_line_order 'the config write section precedes the non-dry-run bootstrap write' \
    "$step_two_line" "$write_line"
assert_line_order 'Conflicting is classified before Duplicated' \
    "$conflicting_line" "$duplicated_line"
assert_line_order 'Duplicated is classified before Repo-specific' \
    "$duplicated_line" "$repo_specific_line"

finish
