# shellcheck shell=bash
# timeout_scale JOBS: the factor a suite applies to a bound sized for an idle host. The operator's own positive
# integer AGENT_TEST_TIMEOUT_SCALE wins; otherwise JOBS, the number of suites run-tests.sh runs at once (they compete
# for the CPU, so a probe that starts in 2 s alone can take longer than its 10 s bound under four); anything else is 1.
timeout_scale() {
    if [[ ${AGENT_TEST_TIMEOUT_SCALE:-} =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$AGENT_TEST_TIMEOUT_SCALE"
    elif [[ ${1:-} =~ ^[1-9][0-9]*$ ]]; then
        printf '%s\n' "$1"
    else
        printf '1\n'
    fi
}
