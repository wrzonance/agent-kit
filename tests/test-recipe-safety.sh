#!/usr/bin/env bash
# Suite: executable skill recipes cannot teach hook/guard bypasses.
# shellcheck disable=SC2016  # $agentkit and Markdown snippets are literal fixtures.
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
guard_lib="$root/agentkit/hooks/lib/guard-lib.sh"
onboard_skill="$root/agentkit/skills/onboard-repo/SKILL.md"
parallel_skill="$root/agentkit/skills/parallel-issues/SKILL.md"
green_skill="$root/agentkit/skills/pr-to-green/SKILL.md"
shell_policy="$root/agentkit/skills/.shared/shell-portability.md"
provider_rules="$root/agentkit/skills/review-remote-pr/references/provider-rules.md"
reference_manifest="$root/agentkit/skills/references.md"
hooks_path='core.''hooksPath'
assert_contains "$(cat "$guard_lib")" 'core\.hooksPath' \
    'the guard library names hook execution configuration as prohibited'
assert_contains "$(cat "$guard_lib")" "$no_verify" \
    'the guard library names hook suppression as prohibited'
assert_contains "$(cat "$review_skill")" "$hooks_path" \
    'review guidance retains the hook execution configuration phrase'
assert_contains "$(cat "$review_skill")" 'merge-inherited paths parked/handed off' \
    'review guidance reports inherited-path churn'
assert_contains "$(cat "$onboard_skill")" 'named-base affordance' \
    'onboarding guidance describes the sanctioned inherited-path handoff'

# Multi-line recipes run in the harness shell, which is not necessarily Bash.
# Keep the portability contract in one shared reference and require every
# recipe-bearing skill to route readers there before they execute a fence.
assert_contains "$(cat "$reference_manifest")" \
    '`$agentkit/.shared/shell-portability.md`' \
    'the reference manifest exposes the shared shell-portability policy'
for skill in "$onboard_skill" "$parallel_skill" "$green_skill" "$review_skill"; do
    assert_contains "$(cat "$skill")" '$agentkit/.shared/shell-portability.md' \
        "$(basename "$(dirname "$skill")") points runnable recipes at the shared shell policy"
done
assert_contains "$(cat "$onboard_skill")" 'bootstrap fence through explicit `bash -c`' \
    'onboarding explicitly Bash-wraps the resolver needed to discover the policy'
assert_contains "$(cat "$onboard_skill")" 'Once it resolves `$agentkit`, read' \
    'onboarding reads the shared policy only after its path is available'

shell_policy_text=$(cat "$shell_policy" 2>/dev/null || true)
for required in mapfile readarray BASH_REMATCH SH_WORD_SPLIT 'array index' \
    'python3 -c' 'pipe and heredoc' 'bash -c' 'nested quoting'; do
    assert_contains "$shell_policy_text" "$required" \
        "the shared shell policy covers $required"
done
assert_contains "$shell_policy_text" 'producer \| python3' \
    'the pipe-plus-heredoc example escapes its GFM table delimiter'
assert_contains "$(cat "$provider_rules")" \
    '$agentkit/.shared/shell-portability.md' \
    'provider pitfalls route shell hazards to the shared policy'
assert_not_contains "$(cat "$provider_rules")" '`python3 -c "..."` fails' \
    'provider rules do not duplicate the moved multi-line Python hazard'
assert_not_contains "$(cat "$provider_rules")" '`cmd | python3`' \
    'provider rules do not duplicate the moved pipe-plus-heredoc hazard'

finish
