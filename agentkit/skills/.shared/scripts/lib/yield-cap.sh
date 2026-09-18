#!/usr/bin/env bash
# Legacy shell-yield hint. This record has no tool identity and must not be
# treated as proof of a native-agent or later session-collection timeout limit.
yield_cap_default_ms() {
    [[ ${1:-unknown} == claude ]] && printf '60000\n' || printf '30000\n'
}
yield_cap_line() {
    local harness=${1:-unknown} milliseconds source=default
    if [[ ${AGENT_YIELD_CAP_MS:-} =~ ^[1-9][0-9]*$ ]]; then
        milliseconds=$AGENT_YIELD_CAP_MS
        source=measured
    else
        milliseconds=$(yield_cap_default_ms "$harness")
    fi
    printf 'yield-cap= ms=%s source=%s harness=%s\n' "$milliseconds" "$source" "$harness"
}
