#!/usr/bin/env bash
# Map harness-id.sh names to the runtime's native sub-agent tools.
set -uo pipefail

harness_tools_line() {
    local harness=${1:-unknown} spawn wait send list
    case $harness in
        codex)
            spawn=multi_agent_v1__spawn_agent
            wait=multi_agent_v1__wait_agent
            send=multi_agent_v1__send_input
            list='ALL_TOOLS.filter(t=>/multi_agent_v1__/.test(t.name)).map(t=>t.name)'
            ;;
        claude)
            spawn=Agent
            wait=TaskOutput
            send=SendMessage
            list=Agent,TaskOutput,SendMessage
            ;;
        *)
            spawn=unavailable
            wait=unavailable
            send=unavailable
            list=unavailable
            ;;
    esac

    printf "tools= spawn=%s wait=%s send=%s list='%s'\n" "$spawn" "$wait" "$send" "$list"
}

harness_tools_record_valid() {
    local line=${1:-}
    local record_re="^tools= spawn=[A-Za-z0-9_.:-]+ wait=[A-Za-z0-9_.:-]+ send=[A-Za-z0-9_.:-]+ list='[^']+'$"
    [[ $line =~ $record_re ]]
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    harness_tools_line "${1:-unknown}"
fi
