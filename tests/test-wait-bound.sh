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

wait_discipline="$root/agentkit/skills/.shared/wait-discipline.md"
skill="$root/agentkit/skills/parallel-issues/SKILL.md"
compose="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"

wait_text=$(<"$wait_discipline")
skill_text=$(<"$skill")
compose_source=$(<"$compose")

# The table remains the single source: the worker-wait row still names a
# positive numeric bound, and the never-re-issue-a-timed-out-wait rule this
# issue must not remove is still stated.
assert_contains "$wait_text" 'Worker implementation wait' \
    'wait-discipline.md keeps the worker-wait class row'
worker_wait_bound_seconds=$(grep -m1 'Worker implementation wait' "$wait_discipline" | grep -oE '[0-9]+' | head -n1)
assert_eq yes "$([[ $worker_wait_bound_seconds =~ ^[1-9][0-9]*$ ]] && printf yes || printf no)" \
    'the worker-wait row names a positive numeric bound'
assert_contains "$wait_text" 'At the effective cap, repeat that capped wait' \
    'timeouts at the runtime cap do not force premature stall checks'
assert_contains "$wait_text" 'requests_per_wait_minute' 'handoff defines wait cost metric'
assert_contains "$wait_text" 'synthetic' 'synthetic evidence is labelled'
assert_contains "$skill_text" 'Before the threshold elapses, do not call' 'stall checks are threshold-gated'
prompts=$(<"$root/agentkit/skills/parallel-issues/references/worker-prompts.md")
assert_contains "$prompts" '## Throwaway waiter prompt' 'fresh waiter template exists'
assert_contains "$prompts" 'Never resume this waiter' 'waiters are never reused'
waiter=${prompts#*## Throwaway waiter prompt}
waiter=${waiter%%## PR-loop setup worker prompt*}
assert_eq yes "$([[ ${#waiter} -lt 6000 ]] && printf yes || printf no)" \
    'waiter template leaves room for filled paths under the approximate 2K-token prompt budget'
setup=${prompts#*## PR-loop setup worker prompt}
assert_not_contains "$setup" '--wait-ci --rounds 60' 'setup worker does not poll CI'
assert_contains "$(<"$root/agentkit/skills/.shared/spawn-contract.md")" 'effective cap' 'spawn contract defers wait limits to runtime'

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
# relying only on the recalled rule, and the pinned class-default sentence
# other suites assert on survives verbatim.
assert_contains "$skill_text" '**900 s** minimum, draft-loop/review/CI waits **600 s**' \
    'the pinned wait-class-default sentence is unchanged'
# shellcheck disable=SC2016  # apostrophe-in-prose literal, not an unexpanded variable
assert_contains "$skill_text" 'Dispatch already printed this worker'\''s own bound as a `wait-bound=`' \
    'polling discipline points at the printed dispatch-time value instead of only the recalled rule'

assert_eq yes "$([[ $(wc -c < "$root/agentkit/skills/.shared/wait-discipline.md") -le 10700 ]] && printf yes || printf no)" \
    'wait-discipline policy stays at or under 10700 bytes (fresh waiter and metrics contract)'

finish
