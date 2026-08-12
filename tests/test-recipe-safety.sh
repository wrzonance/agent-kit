#!/usr/bin/env bash
# Suite: executable skill recipes cannot teach hook/guard bypasses.
set -uo pipefail

TEST_NAME='recipe-safety'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fixture="$tmp/bypass.md"
no_verify='--no-''verify'
printf '%s\n' \
    'The prose may discuss the hook-suppression flag, core.hooksPath, aliases, and config.' \
    '```bash' \
    "git commit $no_verify -m \"skip\"" \
    'git -c core.hooksPath=/dev/null commit -m "skip"' \
    "git config alias.commit \"commit $no_verify\"" \
    "printf \"%s\\n\" \"git commit $no_verify\"" \
    '```' > "$fixture"

findings=$(scan_skill_recipes "$fixture")
assert_eq '1' "$(grep -c 'hook bypass' <<< "$findings" || true)" \
    'recipe scan rejects the hook-suppression flag'
assert_eq '1' "$(grep -c 'hook execution config bypass' <<< "$findings" || true)" \
    'recipe scan rejects core.hooksPath execution changes'
assert_eq '1' "$(grep -c 'git alias bypass' <<< "$findings" || true)" \
    'recipe scan rejects git alias execution changes'
assert_not_contains "$findings" 'printf' \
    'recipe scan ignores bypass text in non-executable commands'

review_skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
onboard_skill="$root/agentkit/skills/onboard-repo/SKILL.md"
assert_contains "$(cat "$review_skill")" 'core.hooksPath' \
    'review guidance names hook execution configuration as prohibited'
assert_contains "$(cat "$review_skill")" 'merge-inherited paths parked/handed off' \
    'review guidance reports inherited-path churn'
assert_contains "$(cat "$onboard_skill")" 'named-base affordance' \
    'onboarding guidance describes the sanctioned inherited-path handoff'

finish
