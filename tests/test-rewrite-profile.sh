#!/usr/bin/env bash
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
module="$here/../agentkit/hooks/lib/rewrite_profile.py"
[[ -f $module ]] || { printf 'FAIL: production profile boundary missing\n' >&2; exit 1; }
if [[ -n ${AGENT_REWRITE_LINTER:-} ]]; then
    "$AGENT_REWRITE_LINTER" check "$module" "$here/fixtures/test_rewrite_profile.py"
fi
python3 -B "$here/fixtures/test_rewrite_profile.py"
