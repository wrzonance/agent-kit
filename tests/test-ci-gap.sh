#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='ci-gap'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local repo=$1 config=$2 workflow=$3
    mkdir -p "$repo/.agent" "$repo/.github/workflows"
    [[ -z $config ]] || printf '%s\n' "$config" >"$repo/.agent/config.env"
    [[ -z $workflow ]] || printf '%s\n' "$workflow" >"$repo/.github/workflows/ci.yml"
}

covered_repo="$tmp/covered"
make_repo "$covered_repo" $'AGENT_CMD_TEST=tests/run-tests.sh\nAGENT_CMD_LINT=lint' \
    'name: CI
on:
  pull_request:
jobs:
  checks:
    steps:
      - name: Setup runtime
      - name: Lint checks
      - name: Security scan'

covered_output=$(bash "$root/agentkit/skills/.shared/scripts/ci-gap.sh" \
    --repo-root "$covered_repo")
assert_contains "$covered_output" 'ci-gap= workflows=1 gates=2 covered=1 uncovered=1' \
    'mixed workflow report counts gates and coverage'
assert_contains "$covered_output" 'NOT covered by any declared command' \
    'mixed workflow names the uncovered gate'
assert_contains "$covered_output" 'Security scan' \
    'mixed workflow includes the uncovered gate name'
assert_not_contains "$covered_output" 'Setup runtime' \
    'setup steps are excluded from the gate report'
assert_contains "$covered_output" 'Plausibly covered' \
    'mixed workflow reports the covered gate section'

divergent_repo="$tmp/divergent"
make_repo "$divergent_repo" $'AGENT_CMD_TEST=pytest -q' \
    $'name: CI\non:\n  pull_request:\njobs:\n  checks:\n    steps:\n      - name: Run verifier\n        run: "verify.sh --full"'
divergent_output=$(bash "$root/agentkit/skills/.shared/scripts/ci-gap.sh" \
    --repo-root "$divergent_repo")
assert_contains "$divergent_output" 'CI verifier: verify.sh --full' \
    'CI divergence names the workflow verifier entry point and mode'
assert_contains "$divergent_output" 'Declared TEST proposal: pytest -q' \
    'CI divergence names the raw local proposal'
assert_contains "$divergent_output" 'prefer CI as canonical TEST' \
    'CI divergence prefers the workflow verifier as canonical TEST'

# A block scalar belongs only to its run key. A following step at the parent
# indentation must not be swallowed and reported as a verifier command.
multiline_repo="$tmp/multiline"
make_repo "$multiline_repo" $'AGENT_CMD_TEST=tests/run-tests.sh' $'name: CI\non:\n  pull_request:\njobs:\n  checks:\n    steps:\n      - name: Build package\n        run: |\n          make build\n          echo build complete\n      - name: Run tests\n        run: tests/run-tests.sh'
multiline_output=$(bash "$root/agentkit/skills/.shared/scripts/ci-gap.sh" \
    --repo-root "$multiline_repo")
assert_contains "$multiline_output" 'CI verifier: tests/run-tests.sh' \
    'reports the actual verifier after a multiline build step'
assert_not_contains "$multiline_output" 'CI verifier: -' \
    'does not turn a following named step into a verifier command'
assert_not_contains "$multiline_output" 'inspect - --help' \
    'does not propose help for a swallowed YAML step'

no_contract="$tmp/no-contract"
make_repo "$no_contract" '' \
    'name: CI
on:
  pull_request:
jobs:
  checks:
    steps:
      - name: Security scan'
no_contract_err="$tmp/no-contract.err"
no_contract_rc=0
no_contract_output=$(bash "$root/agentkit/skills/.shared/scripts/ci-gap.sh" \
    --repo-root "$no_contract" 2>"$no_contract_err") || no_contract_rc=$?
assert_eq '3' "$no_contract_rc" 'missing command contract has its documented exit'
assert_contains "$(cat "$no_contract_err")" 'declares no commands' \
    'missing command contract explains the comparison cannot run'
assert_eq '' "$no_contract_output" 'missing command contract has no partial report'

no_workflow="$tmp/no-workflow"
make_repo "$no_workflow" 'AGENT_CMD_TEST=tests/run-tests.sh' ''
no_workflow_err="$tmp/no-workflow.err"
no_workflow_rc=0
no_workflow_output=$(bash "$root/agentkit/skills/.shared/scripts/ci-gap.sh" \
    --repo-root "$no_workflow" 2>"$no_workflow_err") || no_workflow_rc=$?
assert_eq '3' "$no_workflow_rc" 'missing workflow has its documented exit'
assert_contains "$(cat "$no_workflow_err")" 'no CI workflows' \
    'missing workflow explains the absent comparison source'
assert_eq '' "$no_workflow_output" 'missing workflow has no partial report'

finish
