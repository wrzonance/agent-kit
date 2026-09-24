#!/usr/bin/env bash
# Pins issue #897: a suite that imports the hook's Python modules must never
# leave __pycache__/ behind in the shipped tree. test-rewrite-runtime.sh's
# --prefix-fixture reinvocation runs with `-I`, which implies `-E` and so
# ignores PYTHONDONTWRITEBYTECODE; without an explicit -B on that reinvocation
# it re-imports agentkit/hooks/lib/rewrite_runtime.py and writes
# agentkit/hooks/lib/__pycache__/, dirtying an otherwise-clean checkout.
set -uo pipefail

TEST_NAME='clean tree after probe'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

plugin="$root/agentkit"

before=$(find "$plugin" -name '__pycache__' 2>/dev/null | LC_ALL=C sort)
assert_eq '' "$before" 'no __pycache__ under agentkit/ before the suite runs'

unset PYTHONDONTWRITEBYTECODE
(cd -- "$here" && python3 -B fixtures/test_rewrite_runtime.py) > /dev/null 2>&1
rc=$?
assert_eq 0 "$rc" 'test_rewrite_runtime.py exits clean'

after=$(find "$plugin" -name '__pycache__' 2>/dev/null | LC_ALL=C sort)
assert_eq '' "$after" 'no __pycache__ under agentkit/ after running the rewrite-runtime fixture'

finish
