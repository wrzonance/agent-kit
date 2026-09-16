#!/usr/bin/env bash
# Virtual-time benchmark: no network, paid model calls, or wall-clock sleeps.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 - "$here/../bench/fixtures/waiter.json" <<'PY'
import json
import math
import sys
from pathlib import Path

with open(sys.argv[1], encoding='utf-8') as stream:
    fixture = json.load(stream)
assert fixture['evidence'] == 'synthetic'

def simulate(duration, root_cap, waiter_cap, initial_context, growth, implementation=False):
    # Count launch and terminal requests as well as every empty yield.
    root_times = [0, *range(root_cap, duration, root_cap), duration]
    waiter_times = [0, *range(waiter_cap, duration, waiter_cap), duration]
    contexts = [initial_context + i * growth for i in range(len(waiter_times))]
    # First eligible sample seeds stall-check state; subsequent samples remain
    # separated by the threshold. External CI expiry is not a worker stall.
    stall_times = []
    next_check = fixture['stall_threshold_seconds']
    for timestamp in root_times[1:-1]:
        if implementation and timestamp >= next_check:
            stall_times.append(timestamp)
            next_check = timestamp + fixture['stall_threshold_seconds']
    return dict(root_requests=len(root_times), waiter_requests=len(waiter_times),
                max_waiter_context=max(contexts), stall_times=stall_times,
                requests_per_wait_minute=(len(root_times) + len(waiter_times)) / (duration / 60))

for duration in fixture['durations_seconds']:
    result = simulate(duration, fixture['root_cap_seconds'], fixture['waiter_cap_seconds'],
                      fixture['initial_context_tokens'], fixture['growth_tokens_per_request'])
    assert result['root_requests'] == math.ceil(duration / fixture['root_cap_seconds']) + 1
    assert result['root_requests'] < 10
    assert result['max_waiter_context'] < 10000
    assert result['stall_times'] == []  # CI waits never sample implementation stalls.
    assert result['requests_per_wait_minute'] > 0
    print(json.dumps(dict(evidence='synthetic', wait_seconds=duration, **result)))

# Counterfactual controls: small caps and reused large context must fail the
# acceptance budget. A stricter runtime/communication cap is reported honestly.
short = simulate(1800, 60, 30, 1800, 80)
assert short['root_requests'] >= 10
assert short['max_waiter_context'] < 10000
worker = simulate(1800, 60, 30, 1800, 80, implementation=True)
assert worker['stall_times'] == [720, 1440]
assert simulate(720, 60, 30, 1800, 80, implementation=True)['stall_times'] == []
reused = simulate(1200, 600, 30, 163000, 80)
assert reused['max_waiter_context'] >= 10000
assert simulate(1, 600, 30, 1800, 80)['root_requests'] == 2

# Count explicit synthetic tool events, not model requests. No real CI or
# harness session is launched; the issue's reported live trace is not replayed.
def ci_cost(events):
    return dict(root_tool_calls=len(events), spawns=events.count('spawn'),
                extra_model_sessions=events.count('spawn'))

before = ci_cost(['spawn', 'collect', 'collect', 'collect'])
policy = (Path(sys.argv[1]).parents[2] /
          'agentkit/skills/.shared/wait-discipline.md').read_text(encoding='utf-8')
assert 'Root calls already-blocking bounded helpers directly' in policy
after = ci_cost(['blocking_helper'])
assert before == dict(root_tool_calls=4, spawns=1, extra_model_sessions=1)
assert after == dict(root_tool_calls=1, spawns=0, extra_model_sessions=0)
print(json.dumps(dict(evidence='synthetic', scenario='bounded-ci-no-runtime-yield',
                     before=before, after=after,
                     live_measurement='unavailable', model_requests='unavailable')))
print('waiter-bench: PASS (synthetic only; live acceptance unmeasured)')
PY
