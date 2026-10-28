#!/usr/bin/env bash
# A suite that bounds a probe for an idle host scales the bound by the suites sharing the CPU (run-tests.sh exports the
# job count), so the opencode-plugin probe no longer dies at its 10 s watchdog under four jobs on a busy host.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='runner-timeout-scale'
# shellcheck source=lib/timeout-scale.sh
source "$here/lib/timeout-scale.sh"

unset AGENT_TEST_TIMEOUT_SCALE
assert_eq 1 "$(timeout_scale 1)" 'one job at a time keeps the idle-host bound'
assert_eq 4 "$(timeout_scale 4)" 'four concurrent suites scale every bound by four'
assert_eq 7 "$(AGENT_TEST_TIMEOUT_SCALE=7 timeout_scale 4)" 'an operator scale wins over the job count'
assert_eq 4 "$(AGENT_TEST_TIMEOUT_SCALE=0 timeout_scale 4)" 'a scale that is not a positive integer is ignored'
assert_eq 4 "$(AGENT_TEST_TIMEOUT_SCALE=fast timeout_scale 4)" 'a non-numeric scale is ignored'
assert_eq 1 "$(timeout_scale)" 'no job count means a suite run alone'
assert_eq 1 "$(timeout_scale many)" 'a job count that is not a positive integer means a suite run alone'

finish
