#!/usr/bin/env bash
# Run the v2 gates and suites. Called from tests/run-tests.sh; runnable alone.
set -uo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
v2=$(cd -- "$here/../../v2" && pwd)
rc=0
"$here/lint-budget.sh" || rc=1
mapfile -t scripts < <(find "$v2/bin" "$v2/lib" -type f; find "$here" -name '*.sh'; find "$here/stub" -type f)
shellcheck -x -P SCRIPTDIR -S style "${scripts[@]}" || rc=1
for suite in "$here"/test-*.sh; do
    bash "$suite" || rc=1
done
exit "$rc"
