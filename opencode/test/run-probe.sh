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

echo "Running probe smoke test..."

# Resolve the bound the same way opencode/index.js's resolveTimeoutBinary()
# does: `timeout` (Linux, most package managers), then `gtimeout` (Homebrew
# coreutils on macOS, where the BSD tool that ships by default exists under
# neither name). A hardcoded call to the first name breaks this smoke test on
# stock macOS with exit 127 before the probe ever runs.
timeout_bin=$(command -v timeout 2> /dev/null || command -v gtimeout 2> /dev/null || true)

if [[ -n $timeout_bin ]]; then
    echo "bound: $timeout_bin -k 2 10 (kill after a 2s grace period)"
    output=$(printf '{"cwd":"%s","source":"startup"}' "$root" |
        "$timeout_bin" -k 2 10 bash "$root/agentkit/hooks/session-start.sh")
else
    # Smallest portable fallback: run without a coreutils kill bound, matching
    # index.js's own fallback (a bare Promise.race) -- an outlived probe is
    # abandoned rather than killed, but this smoke test itself cannot hang.
    echo "bound: none (no timeout/gtimeout on PATH); probe runs without a kill bound"
    output=$(printf '{"cwd":"%s","source":"startup"}' "$root" |
        bash "$root/agentkit/hooks/session-start.sh")
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
