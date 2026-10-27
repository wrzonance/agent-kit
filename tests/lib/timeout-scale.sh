# shellcheck shell=bash
# timeout_scale JOBS: the AGENT_TEST_TIMEOUT_SCALE concurrent suites run under. The operator's own positive integer
# wins; otherwise JOBS, since that many suites compete for the CPU and a bound sized for an idle host would fail.
timeout_scale() {
    if [[ ${AGENT_TEST_TIMEOUT_SCALE:-} =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$AGENT_TEST_TIMEOUT_SCALE"
    else
        printf '%s\n' "$1"
    fi
}
