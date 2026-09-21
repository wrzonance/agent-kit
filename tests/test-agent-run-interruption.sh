#!/usr/bin/env bash
# Catchable signals are terminal incomplete evidence, never argument failures.
set -uo pipefail
TEST_NAME=agent-run-interruption
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
run="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

controller="$tmp/interrupt.py"
cat > "$controller" <<'PY'
import os
import pathlib
import signal
import subprocess
import sys
import time

ready = pathlib.Path(sys.argv[1])
signum = getattr(signal, sys.argv[2])
command = sys.argv[4:]
env = os.environ.copy()
env["INTERRUPT_READY"] = str(ready)
def reset_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True,
                           start_new_session=True, preexec_fn=reset_signals)
deadline = time.monotonic() + 10
while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
    time.sleep(0.01)
if not ready.exists():
    os.killpg(process.pid, signal.SIGKILL)
    output, _ = process.communicate()
    print(output, end="")
    sys.exit(124)
os.killpg(process.pid, signum)
try:
    output, _ = process.communicate(timeout=10)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    output, _ = process.communicate()
    print(output, end="")
    sys.exit(124)
print(output, end="")
code = process.returncode
sys.exit(code if code >= 0 else 128 - code)
PY

make_repo() {
    local repo="$tmp/$1"
    mkdir -p "$repo/.agent"
    git init -q "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    cat > "$repo/hold" <<'SH'
#!/bin/sh
trap 'exit 130' INT
trap 'exit 143' TERM
printf '%s\n' "$$" > "$INTERRUPT_READY"
while :; do sleep 1; done
SH
    chmod +x "$repo/hold"
    cat > "$repo/.agent/config.env" <<'CFG'
AGENT_CMD_TEST=./hold
AGENT_VERIFY_TEST_MODE=local
AGENT_VERIFY_TEST_TOOLCHAIN=sh,bash
CFG
    printf '.agent/logs/\n.agent/verification-cache*\n.agent/verification-records/\n' > "$repo/.gitignore"
    git -C "$repo" add .
    git -C "$repo" commit -qm base
    printf '%s\n' "$repo"
}

for signal_name in SIGINT SIGTERM; do
    for summary in off on; do
        repo=$(make_repo "${signal_name}-${summary}")
        ready="$tmp/${signal_name}-${summary}.ready"
        args=("$run" --dir "$repo" --cmd test)
        [[ $summary == off ]] || args+=(--summary)
        rc=0
        out=$(python3 "$controller" "$ready" "$signal_name" -- "${args[@]}" 2>&1) || rc=$?
        context="$signal_name summary=$summary"
        assert_eq 130 "$rc" "$context preserves interruption exit compatibility"
        assert_contains "$out" 'failure-v1 class=cancelled' "$context is typed as cancellation"
        assert_eq 1 "$(grep -c '^failure-v1 ' <<< "$out")" "$context emits one typed result"
        assert_contains "$out" 'command=./hold' "$context retains command identity"
        assert_contains "$out" "state=interrupted-$signal_name" "$context names the observed signal"
        assert_contains "$out" 'next_action=inspect-retained-log-then-retry-declared-command-if-still-required' \
            "$context gives bounded recovery"
        assert_not_contains "$out" 'state=arguments' "$context is not a usage failure"
        assert_not_contains "$out" 'PASS:' "$context cannot become green evidence"
        record=$(printf '%s\n' "$out" | grep '^failure-v1 ' | tail -n1)
        log=$(sed -n 's/.* evidence=\([^ ]*\) state=.*/\1/p' <<< "$record")
        assert_contains "$(<"$log")" "interrupted by $signal_name -- the command did not finish" \
            "$context retains an explicit interruption marker"
        assert_not_contains "$(<"$log")" '=== agent-run exited' \
            "$context log cannot look complete"
        summary_count=$(grep -c '^agent-run-summary ' <<< "$out")
        if [[ $summary == on ]]; then
            assert_eq 1 "$summary_count" "$context emits exactly one terminal summary"
            assert_contains "$(tail -n1 <<< "$out")" 'agent-run-summary status=incomplete rc=130' \
                "$context summary agrees with the typed record"
            assert_contains "$(tail -n1 <<< "$out")" "log=$log log-sha256=unavailable receipt=unavailable" \
                "$context summary retains the same incomplete log without invented digest evidence"
        else
            assert_eq 0 "$summary_count" "$context does not add an unrequested summary"
        fi
        retry_rc=0
        retry=$(${args[0]} --dir "$repo" --cmd test 2>&1) || retry_rc=$?
        assert_eq 75 "$retry_rc" "$context leaves bounded abandoned-work recovery"
        assert_contains "$retry" 'verification unknown:' "$context cannot start a duplicate verification"
    done
done

# SIGKILL cannot produce a terminal record; its durable lease remains explicitly unknown.
repo=$(make_repo SIGKILL)
ready="$tmp/SIGKILL.ready"
rc=0
out=$(python3 "$controller" "$ready" SIGKILL -- "$run" --dir "$repo" --cmd test --summary 2>&1) || rc=$?
assert_eq 137 "$rc" 'SIGKILL remains untrapped'
assert_eq 0 "$(grep -c '^agent-run-summary ' <<< "$out")" 'SIGKILL cannot invent a terminal summary'
retry_rc=0
retry=$($run --dir "$repo" --cmd test 2>&1) || retry_rc=$?
assert_eq 75 "$retry_rc" 'SIGKILL abandoned record requires explicit recovery'
assert_contains "$retry" 'state=verification-unknown' 'SIGKILL recovery remains explicit'

# Neighboring failure classes stay distinct from interruption.
repo="$tmp/control"
mkdir -p "$repo/.agent"
git init -q "$repo"
printf 'AGENT_CMD_TEST=false\n' > "$repo/.agent/config.env"
ordinary_rc=0
ordinary=$($run --dir "$repo" --cmd test --summary 2>&1) || ordinary_rc=$?
assert_eq 1 "$ordinary_rc" 'ordinary command failure preserves its exit code'
assert_contains "$ordinary" 'failure-v1 class=test-failure' 'ordinary command failure stays a test failure'
assert_contains "$ordinary" 'state=exit=1' 'ordinary command failure keeps execution state'
assert_contains "$(tail -n1 <<< "$ordinary")" 'agent-run-summary status=fail rc=1' \
    'ordinary command failure keeps its completed summary'

usage_rc=0
usage=$($run --dir "$repo" --cmd 2>&1) || usage_rc=$?
assert_eq 1 "$usage_rc" 'pre-execution usage failure preserves its exit code'
assert_contains "$usage" 'failure-v1 class=usage' 'pre-execution failure stays usage'
assert_not_contains "$usage" 'class=cancelled' 'usage failure cannot look interrupted'

finish
