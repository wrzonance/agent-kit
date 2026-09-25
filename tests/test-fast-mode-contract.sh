#!/usr/bin/env bash
# Boundary contract for issue #491's fast-mode review accounting.
# shellcheck disable=SC2016
set -uo pipefail

TEST_NAME='fast-mode-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

parallel="$root/agentkit/skills/parallel-issues/SKILL.md"
review="$root/agentkit/skills/review-remote-pr/SKILL.md"
body_policy="$root/agentkit/skills/.shared/github-body-policy.md"
comment_composer="$root/agentkit/skills/review-remote-pr/scripts/compose-comment-body.sh"
worker_prompts="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
fast_reference="$root/agentkit/skills/parallel-issues/references/worker-prompts.md"
triage_reference="$root/agentkit/skills/parallel-issues/references/triage-and-selection.md"
named_active_helper="$root/agentkit/skills/parallel-issues/scripts/named-active-state.sh"

parallel_text=$(<"$parallel")
review_text=$(<"$review")
policy_text=$(<"$body_policy")
worker_text=$(<"$worker_prompts")
fast_text=$(<"$fast_reference")
triage_text=$(<"$triage_reference")
named_active_text=$(<"$named_active_helper")

# Fast mode must make one pushed diff and one combined finding batch observable.
assert_contains "$parallel_text$review_text$fast_text" 'same first pushed diff' \
    'fast mode binds root and adversarial review to the first pushed diff'
assert_contains "$parallel_text$review_text$fast_text" 'one combined fix batch' \
    'fast mode combines confirmed findings into one fix batch'
assert_contains "$parallel_text$review_text$fast_text" 'focused verification' \
    'fast mode uses focused verification during fix rounds'
assert_contains "$parallel_text$review_text$fast_text" 'full suite' \
    'fast mode requires one final full suite'
assert_contains "$parallel_text$review_text$fast_text" 'code-bearing fixes step effort down' \
    'code-bearing fix rounds reduce worker effort'
assert_contains "$parallel_text$review_text$fast_text" 'Initial work retains the declared worker tier' \
    'initial work keeps the declared worker tier'
assert_contains "$parallel_text$review_text$fast_text" 'tiny docs-only fixes' \
    'tiny docs-only fixes use the fastest tier'
assert_contains "$parallel_text$review_text$fast_text" 'mechanical fix batch' \
    'mechanical batches may compress design stages'
assert_contains "$parallel_text$review_text$fast_text" '28 full runs, 18 commits, 13 rounds, 2h42m' \
    'fast-mode accounting records the baseline comparison'

# Canonical helper argv belongs in a single reference and names all three helpers.
assert_contains "$fast_text" 'gh-pr-state.sh --full' \
    'fast-mode reference documents canonical full PR-state argv'
assert_contains "$fast_text" 'review-transition.sh' \
    'fast-mode reference documents canonical review-transition argv'
assert_contains "$fast_text" 'merge-pr.sh' \
    'fast-mode reference documents canonical merge argv'

# Trigger-only comments have no agent-authorship banner; composed comments are file-backed.
assert_contains "$parallel_text$review_text$fast_text" 'trigger/command comments' \
    'trigger-only comments skip attribution banners'
assert_contains "$policy_text$parallel_text$review_text$fast_text" 'compose-comment-body.sh' \
    'comment composition is centralized in the safe composer'
assert_contains "$policy_text$parallel_text$review_text$fast_text" 'forbid hand-rolled shell heredocs' \
    'comment policy forbids hand-rolled heredoc composition'
assert_eq 'yes' "$([[ -x "$comment_composer" ]] && printf yes || printf no)" \
    'safe comment composer is executable'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
part_one="$tmp/one.md"
part_two="$tmp/two.md"
plain="$tmp/plain.md"
printf '%s' 'trigger `literal` $(not-run)' >"$part_one"
printf '%s\n' 'command body' >"$part_two"
assert_rc 0 'composer writes a plain trigger/command comment from files' -- bash "$comment_composer" \
    --output "$plain" --body-file "$part_one" --body-file "$part_two"
plain_text=$(<"$plain")
assert_eq 'trigger `literal` $(not-run)command body' "$plain_text" \
    'plain comment content survives byte-for-byte without attribution'
assert_not_contains "$plain_text" 'This was written agentically' \
    'plain trigger/command comments omit the attribution banner'

identity="$tmp/identity.txt"
agent="$tmp/agent.md"
printf '%s' 'Codex gpt-5.6-luna' >"$identity"
assert_rc 0 'composer adds attribution only when explicitly requested' -- bash "$comment_composer" \
    --output "$agent" --body-file "$part_one" --agent-identity-file "$identity"
agent_text=$(<"$agent")
assert_contains "$agent_text" 'This was written agentically; verify its assertions:' \
    'agent comments receive the canonical front banner'
assert_contains "$agent_text" '🤖 Co-authored by Codex gpt-5.6-luna.' \
    'agent comments receive the canonical signature'
assert_eq '600' "$(stat -c '%a' "$agent")" 'composed comment is private on disk'

# The worker prompt contract must carry the fast-mode behavior as dispatch data,
# not leave it to a worker to infer from the invocation name.
assert_contains "$worker_text" 'fast-mode' \
    'worker prompt reference carries fast-mode context'

# Named active issues are re-adjudicated with local liveness evidence rather
# than silently dropped by the fast-mode selection funnel.
assert_contains "$parallel_text$fast_text$triage_text" 'stale-active' \
    'fast mode names stale active candidates'
assert_contains "$parallel_text$fast_text$triage_text" 'held-active' \
    'fast mode names genuinely active candidates'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=pr' \
    'held active output identifies an open PR'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=worktree' \
    'held active output identifies a live worktree'
assert_contains "$parallel_text$fast_text$triage_text" 'reason=heartbeat' \
    'held active output identifies a fresh worker heartbeat'
assert_contains "$parallel_text$fast_text$triage_text" \
    'requested = dispatched + queued + tracker + duplicate + held-active + sum(exclusions)' \
    'fast mode funnel accounts for every named issue and exclusions'
assert_contains "$triage_text" 'stale-active is a disclosure sub-count' \
    'stale-active is not double-counted in the funnel invariant'
assert_contains "$triage_text" \
    'requested=<requested-count> eligible=<eligible-count> dispatched=<dispatch-count> queued=<queue-count>' \
    'funnel declares one canonical field order'
assert_contains "$triage_text" 'Legacy forms are compatibility-only and are not emitted' \
    'legacy funnel forms are explicitly demoted'
assert_contains "$parallel_text$fast_text$triage_text" 'stale-active=1[#' \
    'fast mode example prints stale-active issue identity'
assert_contains "$parallel_text$fast_text$triage_text" 'held-active:#' \
    'fast mode example prints held-active issue identity'
assert_contains "$triage_text" 'worker_ledger' \
    'named active adjudication consumes the repository-wide ledger restored by run binding'
assert_contains "$triage_text" 'confirmed terminal evidence releases ownership' \
    'named active ledger releases only confirmed terminal workers'
assert_contains "$triage_text" 'Neither interruption requests nor parking' \
    'interruption requests and parking do not release ownership'
assert_contains "$triage_text" 'named-active-state.sh' \
    'named active adjudication invokes the executable boundary helper'
assert_contains "$named_active_text" 'git -C "$repo_root" worktree list --porcelain' \
    'worktree liveness is proven from exact Git registration'
assert_not_contains "$named_active_text" 'pgrep' \
    'named active adjudication does not infer liveness from process archaeology'

# Parse every currently emitted canonical example and verify the accounting
# invariant, including exclusion groups. Compatibility-only legacy strings do
# not match this shape and are intentionally excluded from the parse.
canonical_funnels=$(printf '%s\n' "$triage_text" | grep -E \
    '^Selection funnel: requested=[0-9]+ eligible=[0-9]+ dispatched=[0-9]+ queued=[0-9]+(\[[^]]*\])?[[:space:]]tracker=[0-9]+ duplicate=[0-9]+ held-active=[0-9]+ stale-active=[0-9]+(\[[^]]*\])?[[:space:]]exclusions=')
canonical_count=$(printf '%s\n' "$canonical_funnels" | sed '/^$/d' | wc -l | tr -d '[:space:]')
assert_eq '8' "$canonical_count" 'all canonical funnel examples are discoverable'
canonical_mismatches=0
while IFS= read -r funnel; do
    [[ -n $funnel ]] || continue
    requested=$(grep -oE 'requested=[0-9]+' <<< "$funnel" | cut -d= -f2)
    dispatched=$(grep -oE 'dispatched=[0-9]+' <<< "$funnel" | cut -d= -f2)
    queued=$(grep -oE 'queued=[0-9]+' <<< "$funnel" | cut -d= -f2)
    tracker=$(grep -oE 'tracker=[0-9]+' <<< "$funnel" | cut -d= -f2)
    duplicate=$(grep -oE 'duplicate=[0-9]+' <<< "$funnel" | cut -d= -f2)
    held=$(grep -oE 'held-active=[0-9]+' <<< "$funnel" | cut -d= -f2)
    exclusions=${funnel#* exclusions=}
    exclusion_total=0
    if [[ $exclusions != none ]]; then
        while IFS= read -r group; do
            count=${group#*:}
            count=${count%%\[*}
            exclusion_total=$((exclusion_total + count))
        done < <(tr ',' '\n' <<< "$exclusions")
    fi
    expected=$((dispatched + queued + tracker + duplicate + held + exclusion_total))
    [[ $requested == "$expected" ]] || canonical_mismatches=$((canonical_mismatches + 1))
done <<< "$canonical_funnels"
assert_eq '0' "$canonical_mismatches" \
    'every canonical funnel example satisfies the accounting invariant'

# #784 parent integration: exact size after retaining the body-free picker boundary
# alongside #782's provenance-bound installed issue-path helper recipe.
# #909: record the PR publication target once in the dispatch-plan producer.
assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/parallel-issues/references/triage-and-selection.md") -le 39224 ]] && printf yes || printf no)" \
    'triage-and-selection reference stays at or under 39224 bytes'

# Companion acknowledgement is derived from the active skill's declared map.
assert_rc 0 'delegated skills preserve the governing active receipt' -- python3 - "$root" "$tmp" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys
root, tmp = map(Path, sys.argv[1:])
repo = tmp / 'activation-repo'
repo.mkdir()
subprocess.run(['git', 'init', '-q', str(repo)], check=True)
skills = tmp / 'plugin/skills'
(skills.parent / '.claude-plugin').mkdir(parents=True)
(skills.parent / '.claude-plugin/plugin.json').write_text('{"version":"1.0"}')
for name in ('pr-to-green', 'review-remote-pr', 'onboard-repo'):
    (skills / name).mkdir(parents=True)
    (skills / name / 'SKILL.md').write_text('# ' + name)
body = '# Workflow\n## Resident call-site map\n\n| Boundary | Authority |\n|---|---|\n| Review | `../review-remote-pr/SKILL.md` and its lazy references |\n\n## Other\nExample `../onboard-repo/SKILL.md` is not a delegation.\n'
(skills / 'pr-to-green/SKILL.md').write_text(body)
helper = root / 'agentkit/skills/.shared/scripts/lib/workflow-activation.py'
argv = ['python3', str(helper), '--skills', str(skills), '--digest', 'a' * 64]
def run(*args, payload=None):
    return subprocess.run(argv + list(args), input=json.dumps(payload) if payload else None,
                          text=True, capture_output=True)
run('hook', payload={'cwd':str(repo), 'session_id':'session', 'prompt':'/pr-to-green'})
path = repo / '.agent/activation' / (hashlib.sha256(b'session').hexdigest() + '.json')
record = json.loads(path.read_text())
base = ['--repo-root', str(repo), '--session', 'session']
assert run('ack', *base, '--skill', 'review-remote-pr', '--nonce', record['nonce']).returncode == 1
assert run('ack', *base, '--skill', 'pr-to-green', '--nonce', record['nonce']).returncode == 0
before = path.read_bytes()
result = run('ack', *base, '--skill', 'review-remote-pr', '--nonce', record['nonce'])
assert result.returncode == 0, result.stderr
assert path.read_bytes() == before, 'companion must not replace governing receipt'
assert run('check', *base, '--skill', 'review-remote-pr').returncode == 0
assert run('check', *base, '--skill', 'onboard-repo').returncode == 1
delegate_dir = skills / 'review-remote-pr'
external_dir = tmp / 'external-delegate'
delegate_dir.rename(external_dir)
delegate_dir.symlink_to(external_dir, target_is_directory=True)
assert run('check', *base, '--skill', 'review-remote-pr').returncode == 1, 'symlinked delegate directory must not authorize'
assert run('ack', *base, '--skill', 'review-remote-pr', '--nonce', record['nonce']).returncode == 1
assert path.read_bytes() == before, 'refused delegate leaves governing activation intact'
delegate_dir.unlink()
external_dir.rename(delegate_dir)
assert run('check', *base, '--skill', 'review-remote-pr').returncode == 0, 'real delegate directory remains authorized'
for skill, allowed in [('agentkit:review-remote-pr', True), ('agentkit:onboard-repo', False), ('agentkit:', False), (None, False)]:
    result = run('hook', payload={'cwd':str(repo), 'session_id':'session', 'hook_event_name':'PreToolUse',
                                 'tool_name':'Skill', 'tool_input':{'skill':skill}})
    denied = json.loads(result.stdout).get('hookSpecificOutput', {}).get('permissionDecision') == 'deny'
    assert denied != allowed, result.stdout
assert json.loads(path.read_text())['workflow'] == 'pr-to-green'
# Replacing the declaration replaces the allowance, proving it is not a pair list.
(skills / 'pr-to-green/SKILL.md').write_text(body.replace('review-remote-pr/SKILL.md', 'onboard-repo/SKILL.md'))
assert run('check', *base, '--skill', 'review-remote-pr').returncode == 1
run('hook', payload={'cwd':str(repo), 'session_id':'session', 'prompt':'/pr-to-green'})
record = json.loads(path.read_text())
assert run('ack', *base, '--skill', 'pr-to-green', '--nonce', record['nonce']).returncode == 0
assert run('check', *base, '--skill', 'onboard-repo').returncode == 0
assert run('check', *base, '--skill', 'review-remote-pr').returncode == 1
PY

finish
