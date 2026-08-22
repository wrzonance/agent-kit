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

output=$(printf '{"cwd":"%s","source":"startup"}' "$root" |
    timeout -k 2 10 bash "$root/agentkit/hooks/session-start.sh")

if echo "$output" | grep -q 'gh=.*authed='; then
    echo "ok: probe output contains the expected gh= line"
    exit 0
else
    echo "FAIL: probe output does not contain the expected gh= line" >&2
    echo "output was:" >&2
    echo "$output" >&2
    exit 1
fi
