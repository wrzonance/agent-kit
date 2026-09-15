#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
module="$here/../agentkit/hooks/lib/tool_input_rewrite.py"
[[ -f $module ]] || { printf 'FAIL: production rewrite engine missing\n' >&2; exit 1; }
if [[ -n ${AGENT_REWRITE_LINTER:-} ]]; then
    "$AGENT_REWRITE_LINTER" check "$module" "$here/fixtures/test_tool_rewrite_engine.py"
fi
python3 -B "$here/fixtures/test_tool_rewrite_engine.py"
