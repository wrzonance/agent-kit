#!/usr/bin/env bash
# Suite: the dispatch-time wait-bound datum (issue #449). The orchestrator
# must read a worker's wait bound off a printed line at dispatch time instead
# of recalling wait-discipline.md's rule from prose, and the printed value can
# never drift from that rule because only the table is ever hand-edited.
set -uo pipefail

TEST_NAME='wait-bound'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

wait_discipline="$root/agentkit/skills/.shared/wait-discipline.md"
skill="$root/agentkit/skills/parallel-issues/SKILL.md"
compose="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"

wait_text=$(<"$wait_discipline")
skill_text=$(<"$skill")
compose_source=$(<"$compose")

# The table remains the single source: the worker-wait row still names a
# positive numeric bound, and capped empty returns remain safe to collect.
assert_contains "$wait_text" 'Worker implementation wait' \
    'wait-discipline.md keeps the worker-wait class row'
worker_wait_bound_seconds=$(grep -m1 'Worker implementation wait' "$wait_discipline" | grep -oE '[0-9]+' | head -n1)
assert_eq yes "$([[ $worker_wait_bound_seconds =~ ^[1-9][0-9]*$ ]] && printf yes || printf no)" \
    'the worker-wait row names a positive numeric bound'
assert_not_contains "$wait_text" 'requests_per_wait_minute' \
    'the model is no longer asked to calculate rollout metrics'
assert_contains "$skill_text" 'Before the threshold elapses, do not call' 'stall checks are threshold-gated'
prompts=$(<"$root/agentkit/skills/parallel-issues/references/worker-prompts.md")
implementation=$(<"$root/agentkit/skills/parallel-issues/references/implementation-worker.md")
assert_contains "$prompts" '## Throwaway waiter prompt' 'fresh waiter template exists'
assert_contains "$prompts" 'Never resume this waiter' 'waiters are never reused'
assert_contains "$prompts" 'resume the same running session' \
    'the generic waiter resumes its existing helper after a runtime yield'
assert_contains "$wait_text" 'Use the largest permitted yield' \
    'shared wait discipline tells every bounded helper to use the largest yield'
assert_contains "$wait_text" 'resume the same running session' \
    'shared wait discipline preserves the same helper session across runtime yields'
assert_not_contains "$implementation" 'read the NAMED LOG when the summary is insufficient' \
    'implementation template defers log-read mechanics to the composed verify line'
combined_worker_lines=$(printf '%s\n%s\n' "$prompts" "$implementation" | wc -l | tr -d ' ')
assert_eq yes "$([[ $combined_worker_lines -lt 868 ]] && printf yes || printf no)" \
    'worker-prompts.md and implementation-worker.md have a net line-count decrease'
waiter=${prompts#*## Throwaway waiter prompt}
waiter=${waiter%%## PR-loop setup worker prompt*}
assert_eq yes "$([[ ${#waiter} -lt 6000 ]] && printf yes || printf no)" \
    'waiter template leaves room for filled paths under the approximate 2K-token prompt budget'
setup=${prompts#*## PR-loop setup worker prompt}
assert_not_contains "$setup" '--wait-ci --rounds 60' 'setup worker does not poll CI'
assert_contains "$(<"$root/agentkit/skills/.shared/spawn-contract.md")" 'live schema and observed session' \
    'spawn contract defers wait limits to runtime'
review=$(<"$root/agentkit/skills/review-remote-pr/SKILL.md")
assert_contains "$review" 'Guards run only in root' 'fresh waiter does not receive root shell guards'
assert_contains "$review" 'Root runs this bounded helper directly' 'root owns the blocking CI call'
assert_not_contains "$review" 'invocation to the fresh waiter' 'CI does not require waiter indirection'
assert_not_contains "$skill_text" 'Use the shared fresh waiter template for CI/review' 'parallel skill does not mandate CI waiters'
assert_not_contains "$wait_text" 'Re-issuing a wait the instant it returns empty is the failure mode' 'empty capped waits are not simultaneously forbidden'
assert_contains "$wait_text" 'Root calls already-blocking bounded helpers directly' 'bounded helper default is direct'
assert_contains "$wait_text" 'genuinely unbounded or long-lived producer' 'waiter exception has a purpose'
assert_not_contains "$wait_text" '3600000 ms' 'the runbook does not promise a runtime cap it did not measure'
assert_contains "$wait_text" 'expiry does not terminate a worker' 'collection expiry is not worker termination'

# wait-discipline.md documents itself as the single source the composer
# reads -- never a second hand-maintained copy of the number.
assert_contains "$wait_text" 'single source for the worker-wait bound' \
    'wait-discipline.md names itself as the single source for the bound'
assert_contains "$wait_text" 'compose-worker-prompt.sh' \
    'wait-discipline.md names the helper that reads its table'

# compose-worker-prompt.sh parses that same row rather than hardcoding a
# duplicate literal, and emits one wait-bound line per composed worker
# prompt -- covering both templates it composes.
assert_contains "$compose_source" 'Worker implementation wait' \
    'the composer greps for the documented row name, not a bare literal'
assert_contains "$compose_source" "printf 'wait-bound= issue=%s seconds=%s class=worker\\n'" \
    'the composer emits a wait-bound line beside each worker'\''s own identifier'
assert_contains "$compose_source" "printf '%s\\n' \"\$yield_cap_line\"" \
    'the composer emits the contract yield-cap beside each worker wait bound'
assert_contains "$compose_source" "verify_command='agent-run.sh --cmd test --summary'" \
    'the composer defaults the verification runbook to the declared test command'
assert_contains "$compose_source" \
    'verify= cmd="%s" shell_yield_hint_ms=%s collect=%s' \
    'the runbook separates a shell hint from collection selection'

# The dispatch step in SKILL.md captures that line from the composer's stdout
# and reprints it beside the same issue's prompt=/issue= digest line, so the
# orchestrator reads the bound back at the exact call site that names the
# worker -- no extra model turn or forge call is spent producing it.
assert_contains "$skill_text" "wait_bound=\$(printf '%s\\n' \"\$compose_output\" | grep -E '^wait-bound= ' || true)" \
    'the dispatch step captures the composer-emitted wait-bound line'
# shellcheck disable=SC2016  # the literal source text this test looks for is single-quoted in SKILL.md
assert_contains "$skill_text" 'printf '\''%s\n'\'' "$wait_bound"' \
    'the dispatch step reprints the captured wait-bound line at composition time'

# The polling-discipline prose points at that printed value instead of
# relying only on the recalled rule, and names each total observation window.
assert_contains "$skill_text" 'Worker collection windows are **900 s**, draft-loop/review/CI observation windows **600 s**' \
    'the skill distinguishes collection windows from per-call limits'
# shellcheck disable=SC2016  # apostrophe-in-prose literal, not an unexpanded variable
assert_contains "$skill_text" 'Dispatch already printed this worker'\''s own bound as a `wait-bound=`' \
    'polling discipline points at the printed dispatch-time value instead of only the recalled rule'

ratchet_repo="$tmp/ratchet-repo"
mkdir -p "$ratchet_repo/agentkit/skills/.shared"
git -C "$ratchet_repo" init -q
cp "$wait_discipline" "$ratchet_repo/agentkit/skills/.shared/wait-discipline.md"
git -C "$ratchet_repo" add agentkit/skills/.shared/wait-discipline.md
git -C "$ratchet_repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
git -C "$ratchet_repo" update-ref refs/remotes/origin/main HEAD
assert_eq "$(git -C "$ratchet_repo" rev-parse HEAD)" "$(git -C "$ratchet_repo" rev-parse origin/main)" \
    'the stable ratchet is exercised when the moving base already equals HEAD'
assert_eq yes "$([[ $(wc -l < "$ratchet_repo/agentkit/skills/.shared/wait-discipline.md") -le 170 ]] && printf yes || printf no)" \
    'shared wait policy stays within its explicit cross-harness line budget'

finish
