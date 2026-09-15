#!/usr/bin/env bash
set -euo pipefail
umask 077
self=$(realpath -- "${BASH_SOURCE[0]}")

prepare() {
    local root=$1 hook
    [[ $root == /* && $root != *[[:cntrl:]]* && ! -e $root && ! -L $root ]] || return 2
    mkdir -m 700 -- "$root" "$root/repo"
    cp -- "$self" "$root/driver.sh"
    printf '#!/bin/bash\nexec /bin/bash %q prefix %q "$@"\n' "$root/driver.sh" "$root" > "$root/prefix.sh"
    chmod 700 -- "$root/prefix.sh"
    printf -v hook '/bin/bash %q hook %q' "$root/driver.sh" "$root"
    jq -nc --arg hook "$hook" '{permissions:{allow:["Bash(printf agentkit-shell-audit)"]},
        hooks:(["PreToolUse","PostToolUse","PostToolUseFailure"] | map({key:.,value:
          [{matcher:"Bash",hooks:[{type:"command",command:$hook,timeout:10}]}]}) | from_entries)}' > "$root/settings.json"
    printf '{"mcpServers":{}}\n' > "$root/mcp.json"
    printf '%s\n' 'Make exactly one Bash call: printf agentkit-shell-audit. Set timeout to 10000. Do not inspect files or use another command. Never retry. Return its observed output.' > "$root/prompt.txt"
    sha256sum "$root"/{driver.sh,prefix.sh,settings.json,mcp.json,prompt.txt} > "$root/sources.sha256"
    printf 'audit-prepared: %s (no provider launched)\n' "$root"
}

prefix() {
    local root=$1 native=$2 record snapshot='' snapshot_sha='' command_sha names pattern
    sha256sum -c --status "$root/sources.sha256"
    record=$(mktemp "$root/prefix-XXXXXXXX")
    printf '%s' "$native" > "$record.command"
    command_sha=$(sha256sum "$record.command" | cut -d' ' -f1)
    pattern='^source (/[-A-Za-z0-9._/]+) 2>/dev/null'
    if [[ $native =~ $pattern ]]; then
        snapshot=${BASH_REMATCH[1]}
        if [[ -f $snapshot && ! -L $snapshot && -O $snapshot && $(stat -c %s "$snapshot") -le 1048576 ]]; then
            cat -- "$snapshot" > "$record.snapshot"
            snapshot_sha=$(sha256sum "$record.snapshot" | cut -d' ' -f1)
        fi
    fi
    names=$(compgen -e | LC_ALL=C sort | jq -Rsc 'split("\n") | map(select(length > 0))')
    jq -nc --arg source "$snapshot" --arg snapshot "$snapshot_sha" --arg command "$command_sha" \
        --arg session "${CLAUDE_CODE_SESSION_ID:-}" --argjson names "$names" \
        '{observationOnly:true,session:$session,nativeCommandSha256:$command,
          snapshotPath:$source,snapshotSha256:$snapshot,environmentNames:$names}' > "$record.json"
    rm -- "$record"
    exec /bin/bash -c "$native"
}

hook() {
    local root=$1 input event command output='{}'
    sha256sum -c --status "$root/sources.sha256"
    input=$(cat)
    event=$(jq -er '.hook_event_name' <<< "$input")
    command=$(jq -r '.tool_input.command // ""' <<< "$input")
    if [[ $event == PreToolUse && $command != 'printf agentkit-shell-audit' &&
        $command != "printf 'agentkit-shell-audit'" ]]; then
        output='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Outside the synthetic shell audit"}}'
    fi
    jq -nc --argjson input "$input" --argjson output "$output" \
        '{event:$input.hook_event_name,id:$input.tool_use_id,session:$input.session_id,
          input:$input.tool_input,response:($input.tool_response // null),output:$output}' >> "$root/events.ndjson"
    printf '%s\n' "$output"
}

run_live() {
    local root=$1 cli=$2 marker=$3 version rc=0
    [[ $marker == --root-authorized-live ]] || return 2
    [[ ! -e $root/provider.jsonl && ! -e $root/events.ndjson ]] || return 2
    version=$("$cli" --version)
    [[ $version == '2.1.272 (Claude Code)' ]] || return 2
    sha256sum -c --status "$root/sources.sha256"
    printf '%s\n' "$version" > "$root/provider-version.txt"
    (cd -- "$root/repo" && CLAUDE_CODE_SHELL=/bin/bash CLAUDE_CODE_SHELL_PREFIX="$root/prefix.sh" \
        timeout -k 5 120 "$cli" --restricted --tools Bash --disable-slash-commands \
        --settings "$root/settings.json" --strict-mcp-config --mcp-config "$root/mcp.json" \
        --permission-mode manual --permission-prompts none --no-chrome --no-session-persistence \
        --model claude-sonnet-5 --effort medium --max-budget-usd 1 \
        --output-format stream-json --include-hook-events --verbose -p "$(cat "$root/prompt.txt")") \
        > "$root/provider.jsonl" 2> "$root/provider.stderr" || rc=$?
    printf '%s\n' "$rc" > "$root/provider-exit"
    ((rc == 0)) || return "$rc"
    jq -es '[.[] | select(.type == "system" and .subtype == "init")]
        | length == 1 and .[0].plugins == []' "$root/provider.jsonl" >/dev/null
    jq -es 'length == 2 and .[0].event == "PreToolUse" and .[1].event == "PostToolUse"
        and .[0].id == .[1].id and .[0].input == .[1].input
        and .[1].response.stdout == "agentkit-shell-audit"' "$root/events.ndjson" >/dev/null
    printf 'audit-observed: native execution once; private artifacts=%s\n' "$root"
}

case ${1:-} in
    prepare) [[ $# == 2 ]] || exit 2; prepare "$2" ;;
    prefix) [[ $# == 3 ]] || exit 2; prefix "$2" "$3" ;;
    hook) [[ $# == 2 ]] || exit 2; hook "$2" ;;
    run) [[ $# == 4 ]] || exit 2; run_live "$2" "$3" "$4" ;;
    *) exit 2 ;;
esac
