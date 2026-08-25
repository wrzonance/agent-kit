#!/usr/bin/env bash
# Smoke test for the agentkit OpenCode plugin's probe wrapper: runs the SAME
# probe runContractProbe() shells out to (agentkit/hooks/session-start.sh)
# directly, the way SessionStart already runs it for Claude/Codex, and
# asserts the output contains the expected `gh=` line.
#
# Resolves the repository root relative to this script's own location rather
# than hardcoding a path, so it works from any checkout or worktree.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/../.." && pwd)

# Test-only seams (set only by tests/test-opencode-plugin.sh, never in normal
# use): AGENTKIT_PROBE_SCRIPT overrides which script is run as the probe,
# AGENTKIT_PROBE_FORCE_NO_TIMEOUT (non-empty) forces the no-timeout/no-gtimeout
# fallback path even when both are on PATH, and AGENTKIT_PROBE_BOUND_SECONDS
# overrides the bound so the fallback's hung-probe case can be asserted
# without waiting out the real 10s bound.
probe_script=${AGENTKIT_PROBE_SCRIPT:-"$root/agentkit/hooks/session-start.sh"}
bound_seconds=${AGENTKIT_PROBE_BOUND_SECONDS:-10}

echo "Running probe smoke test..."

# Resolve the bound the same way opencode/index.js's resolveTimeoutBinary()
# does: `timeout` (Linux, most package managers), then `gtimeout` (Homebrew
# coreutils on macOS, where the BSD tool that ships by default exists under
# neither name). A hardcoded call to the first name breaks this smoke test on
# stock macOS with exit 127 before the probe ever runs.
timeout_bin=""
if [[ -z ${AGENTKIT_PROBE_FORCE_NO_TIMEOUT:-} ]]; then
    timeout_bin=$(command -v timeout 2> /dev/null || command -v gtimeout 2> /dev/null || true)
fi

if [[ -n $timeout_bin ]]; then
    echo "bound: $timeout_bin -k 2 $bound_seconds (kill after a 2s grace period)"
    output=$(printf '{"cwd":"%s","source":"startup"}' "$root" |
        "$timeout_bin" -k 2 "$bound_seconds" bash "$probe_script")
else
    # Portable fallback with no coreutils timeout on PATH: run the probe in
    # the background -- fed from a temp file rather than a pipe, so the
    # backgrounded reader has a real fd instead of one end of a pipe whose
    # writer (printf) has already exited -- under a watchdog subshell that
    # kills it if it outlives the bound. Unlike the timeout_bin branch there
    # is no SIGTERM grace period: the watchdog kills outright once the bound
    # elapses. This still genuinely bounds and kills the probe, unlike a bare
    # `Promise.race` (index.js's own JS-side fallback), which can only
    # abandon an outlived probe, never kill it.
    #
    # `set -m` (job control) makes bash put this background job in its OWN
    # process group, with probe_pid as that group's id -- so `kill -- -PID`
    # below signals the probe AND every process it spawns (e.g. a hung
    # grandchild the probe script itself forked), not just the immediate
    # `bash "$probe_script"` wrapper. Killing only that wrapper's PID would
    # leave such a grandchild running as an orphan, invisible to `wait`.
    echo "bound: no timeout/gtimeout on PATH; watchdog kill after ${bound_seconds}s"
    probe_input=$(mktemp)
    probe_output=$(mktemp)
    trap 'rm -f "$probe_input" "$probe_output"' EXIT
    printf '{"cwd":"%s","source":"startup"}' "$root" > "$probe_input"

    set -m
    bash "$probe_script" < "$probe_input" > "$probe_output" &
    probe_pid=$!
    set +m
    (
        sleep "$bound_seconds"
        kill -- "-$probe_pid" 2> /dev/null
    ) &
    watchdog_pid=$!

    probe_rc=0
    wait "$probe_pid" || probe_rc=$?
    kill "$watchdog_pid" 2> /dev/null || true
    wait "$watchdog_pid" 2> /dev/null || true

    if [[ $probe_rc -ne 0 ]]; then
        echo "FAIL: probe did not finish within ${bound_seconds}s (watchdog bound killed its process group, rc=$probe_rc)" >&2
        exit 1
    fi

    output=$(cat -- "$probe_output")
fi

if echo "$output" | grep -q 'gh=.*authed='; then
    echo "ok: probe output contains the expected gh= line"
    exit 0
else
    echo "FAIL: probe output does not contain the expected gh= line" >&2
    echo "output was:" >&2
    echo "$output" >&2
    exit 1
fi
