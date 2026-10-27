#!/usr/bin/env bash
# run-tests.sh: concurrent suites run under a timeout scale, so a probe bounded for an idle host does not fail at its
# fixed bound while the other suites hold the CPU (the opencode-plugin probe hit its 10 s watchdog under four jobs).
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

finish
