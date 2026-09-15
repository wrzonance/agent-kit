# shellcheck shell=bash
# Test-only previews; no production callers, execution proof, or permissions.

tool_rewrite_capability() {
    jq -nc --arg adapter "${1:-unknown}" --arg version "${2:-unknown}" \
        --arg tool "${3:-unknown}" \
        '{schemaVersion:1,adapter:$adapter,version:$version,tool:$tool,
          status:"unavailable",reason:"live-execution-unproven"}'
}

# Pure preview: supplied helper to proposed tool_input, never a hook response.
tool_rewrite_candidate() {
    local input=$1 helper=$2 quoted
    [[ $helper == /*/agent-run.sh && $helper != *[[:cntrl:]]* &&
        -f $helper && -x $helper && ! -L $helper ]] || return 1
    quoted="'${helper//\'/\'\\\'\'}'"
    jq -sce --arg command "$quoted --cmd test" '
        select(length == 1) | .[0] | select(type == "object")
        | select(.hook_event_name == "PreToolUse" and .tool_name == "Bash")
        | select(.cwd | type == "string" and startswith("/"))
        | .tool_input | select(type == "object")
        | select((keys - ["command", "description", "timeout"] | length) == 0)
        | select(.command == "agent-run.sh --cmd test")
        | select((has("description") | not) or (.description | type == "string"))
        | select((has("timeout") | not) or
            (.timeout | type == "number" and . > 0 and . == floor))
        | .command = $command
    ' <<< "$input" 2>/dev/null || return 1
}
