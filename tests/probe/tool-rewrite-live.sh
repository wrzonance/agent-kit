#!/usr/bin/env bash
# Standalone synthetic hooks. Only `run ... --root-authorized-live` calls Claude.
set -euo pipefail
self=$(realpath -- "${BASH_SOURCE[0]}")
here=${self%/*}

prepare() {
    local target=$1 mode case_dir helper command hook_command nonce
    [[ $target == /* && $target != *[[:cntrl:]]* && ! -e $target && ! -L $target ]] || return 2
    mkdir -m 700 -- "$target"
    cp -- "$self" "$target/driver.sh"
    cp -- "$here/tool-input-rewrite.sh" "$target/candidate.sh"
    for mode in control rewrite; do
        case_dir="$target/$mode"
        mkdir -m 700 -- "$case_dir" "$case_dir/repo"
        helper="$case_dir/agent-run.sh"
        printf '#!/usr/bin/env bash\nexec bash %q target %q "$@"\n' \
            "$target/driver.sh" "$case_dir" > "$helper"
        chmod +x -- "$helper"
        command="'${helper//\'/\'\\\'\'}' --cmd test"
        printf -v hook_command 'bash %q hook %q' "$target/driver.sh" "$case_dir"
        nonce=$(openssl rand -hex 16)
        jq -nc --arg mode "$mode" --arg cwd "$case_dir/repo" --arg helper "$helper" \
            --arg transformed "$command" --arg nonce "$nonce" \
            '{schemaVersion:1,adapter:"claude",version:"2.1.272",mode:$mode,cwd:$cwd,
              helper:$helper,original:"agent-run.sh --cmd test",transformed:$transformed,nonce:$nonce}' \
            > "$case_dir/manifest.json"
        jq -nc --arg command "$hook_command" --arg helper "$helper" '
            {permissions:{allow:[("Bash(" + $helper + " --cmd test)")]},
             hooks:(["PreToolUse","PostToolUse","PostToolUseFailure"] | map({key:.,value:
               [{matcher:"Bash",hooks:[{type:"command",command:$command,timeout:10}]}]}) | from_entries)}' \
            > "$case_dir/settings.json"
        printf '{"mcpServers":{}}\n' > "$case_dir/mcp.json"
        printf '%s\n' 'Execute exactly this Bash command: agent-run.sh --cmd test. Set timeout to 10000. If the hook denies it with a correction, execute precisely that corrected command once with the same timeout. Otherwise never retry. Do not inspect files or use other tools. Return the observed REWRITE-PROBE line.' > "$case_dir/prompt.txt"
    done
    sha256sum "$target/driver.sh" "$target/candidate.sh" \
        "$target"/{control,rewrite}/{agent-run.sh,manifest.json,settings.json,mcp.json,prompt.txt} \
        > "$target/sources.sha256"
    printf 'probe-prepared: %s (no provider launched)\n' "$target"
}

probe_hook() {
    local case_dir=$1 input event mode original transformed command output started elapsed helper
    started=${EPOCHREALTIME/./}
    input=$(cat) || return 1
    sha256sum -c --status "$case_dir/../sources.sha256" || return 1
    event=$(jq -er '.hook_event_name' <<< "$input") || return 1
    mode=$(jq -r '.mode' "$case_dir/manifest.json") || return 1
    original=$(jq -r '.original' "$case_dir/manifest.json") || return 1
    transformed=$(jq -r '.transformed' "$case_dir/manifest.json") || return 1
    helper=$(jq -r '.helper' "$case_dir/manifest.json") || return 1
    command=$(jq -r '.tool_input.command // ""' <<< "$input") || return 1
    output='{}'
    if [[ $event == PreToolUse ]]; then
        if [[ $command == "$original" && $mode == rewrite ]]; then
            local candidate
            # shellcheck source=tool-input-rewrite.sh
            source "$case_dir/../candidate.sh" || return 1
            candidate=$(tool_rewrite_candidate "$input" "$helper") || return 1
            output=$(jq -nc --argjson candidate "$candidate" \
                '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:$candidate}}') || return 1
        elif [[ $command == "$original" && $mode == control ]]; then
            output=$(jq -nc --arg command "$transformed" \
                '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
                  permissionDecisionReason:("Resolve the helper, then retry exactly once: " + $command)}}') || return 1
        elif [[ $mode == control && ( $command == "$transformed" ||
            ( $helper =~ ^/[A-Za-z0-9._/-]+$ && $command == "$helper --cmd test" ) ) ]]; then
            :
        else
            output='{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Outside the synthetic probe command set"}}'
        fi
    fi
    elapsed=$(( ${EPOCHREALTIME/./} - started ))
    jq -nc --argjson input "$input" --argjson output "$output" --argjson elapsed "$elapsed" \
        '{event:$input.hook_event_name,id:$input.tool_use_id,session:$input.session_id,
          input:$input.tool_input,response:($input.tool_response // null),error:($input.error // null),
          output:$output,decisionUs:$elapsed}' >> "$case_dir/events.ndjson" || return 1
    printf '%s\n' "$output"
}

target() {
    local case_dir=$1 nonce
    shift
    [[ ! -e $case_dir/execution-once ]] || return 78
    [[ $# == 2 && $1 == --cmd && $2 == test && $PWD == "$case_dir/repo" ]] || return 2
    sha256sum -c --status "$case_dir/../sources.sha256" || return 1
    mkdir -- "$case_dir/execution-once" || return 78
    nonce=$(jq -r '.nonce' "$case_dir/manifest.json")
    jq -nc --arg nonce "$nonce" --arg cwd "$PWD" --arg environment "${AGENTKIT_REWRITE_PROBE_ENV:-}" \
        '{nonce:$nonce,cwd:$cwd,argv:["--cmd","test"],environment:$environment,exitCode:0}' \
        > "$case_dir/execution.json"
    printf 'REWRITE-PROBE:%s\n' "$nonce"
    printf 'REWRITE-PROBE-STDERR\n' >&2
}

case_report() {
    local case_dir=$1
    sha256sum -c --status "$case_dir/../sources.sha256" || return 1
    jq -en --slurpfile events "$case_dir/events.ndjson" \
        --slurpfile execution "$case_dir/execution.json" --slurpfile manifests "$case_dir/manifest.json" '
        $manifests[0] as $m | $execution[0] as $x
        | [$events[] | select(.event == "PreToolUse")] as $pre
        | [$events[] | select(.event == "PostToolUse")] as $post
        | ($m.mode == "control") as $control
        | ($pre | if $control then .[1] else .[0] end) as $running
        | if (($pre | length) == (if $control then 2 else 1 end)
          and ($post | length) == 1 and ($events | length) == (($pre | length) + 1)
          and ($events | map(.session) | unique | length) == 1
          and ($running.id | type == "string" and length > 0) and $running.id == $post[0].id
          and $pre[0].input.command == $m.original
          and ($post[0].input.command == $m.transformed or ($control
            and ($m.helper | test("^/[A-Za-z0-9._/-]+$"))
            and $post[0].input.command == ($m.helper + " --cmd test")))
          and ($running.input | del(.command)) == ($post[0].input | del(.command))
          and $x.nonce == $m.nonce and $x.cwd == $m.cwd and $x.argv == ["--cmd","test"]
          and $x.environment == "synthetic" and $x.exitCode == 0
          and (($post[0].response.stdout + "\n" + $post[0].response.stderr)
            | contains("REWRITE-PROBE:" + $m.nonce) and contains("REWRITE-PROBE-STDERR"))
          and (if $control then
             $pre[0].output.hookSpecificOutput.permissionDecision == "deny"
             and $running.input.command == $post[0].input.command and $running.output == {}
          else $running.output.hookSpecificOutput.updatedInput == $post[0].input
             and ($running.output.hookSpecificOutput | has("permissionDecision") | not) end))
        then {mode:$m.mode,preCalls:($pre | length),executions:1,
              hookDecisionUs:($events | map(.decisionUs) | add)}
        else error("missing, extra, or mismatched probe evidence") end'
}

inspect() {
    local root=$1 control rewrite runtime=false
    control=$(case_report "$root/control") || return 1
    rewrite=$(case_report "$root/rewrite") || return 1
    if [[ -f $root/control/provider.jsonl && -f $root/rewrite/provider.jsonl ]]; then
        local mode
        for mode in control rewrite; do
            jq -es '[.[] | select(.type == "system" and .subtype == "init")]
                | length == 1 and .[0].plugins == []' "$root/$mode/provider.jsonl" > /dev/null || return 1
            [[ $(cat "$root/$mode/provider-exit") == 0 ]] || return 1
        done
        runtime=true
    fi
    jq -nc --argjson control "$control" --argjson rewrite "$rewrite" --argjson runtime "$runtime" \
        '{schemaVersion:1,correlated:true,runtimeObserved:$runtime,control:$control,rewrite:$rewrite,
          avoidedCorrectionCalls:($control.preCalls - $rewrite.preCalls),
          productionCapability:"unavailable-pending-negative-and-trust-probes"}'
}

run_live() {
    local root=$1 cli=$2 marker=${3:-} mode version rc
    [[ $marker == --root-authorized-live ]] || return 2
    version=$("$cli" --version)
    [[ $version == '2.1.272 (Claude Code)' ]] || { printf 'unexpected runtime: %s\n' "$version" >&2; return 2; }
    sha256sum -c --status "$root/sources.sha256" || return 1
    printf '%s\n' "$version" > "$root/provider-version.txt"
    for mode in control rewrite; do
        [[ ! -e $root/$mode/events.ndjson && ! -e $root/$mode/provider.jsonl ]] || return 2
        printf 'probe-running: %s -> %s/%s/provider.jsonl\n' "$mode" "$root" "$mode"
        rc=0
        (cd -- "$root/$mode/repo" && AGENTKIT_REWRITE_PROBE_ENV=synthetic \
            timeout -k 5 120 "$cli" --restricted --tools Bash --disable-slash-commands \
            --settings "$root/$mode/settings.json" --strict-mcp-config --mcp-config "$root/$mode/mcp.json" \
            --permission-mode manual --permission-prompts none --no-chrome --no-session-persistence \
            --model claude-sonnet-5 --effort medium --max-budget-usd 1 \
            --output-format stream-json --include-hook-events --verbose \
            -p "$(cat "$root/$mode/prompt.txt")") \
            > "$root/$mode/provider.jsonl" 2> "$root/$mode/provider.stderr" || rc=$?
        printf '%s\n' "$rc" > "$root/$mode/provider-exit"
        ((rc == 0)) || return "$rc"
    done
    inspect "$root"
}

case ${1:-} in
    prepare) [[ $# == 2 ]] || exit 2; prepare "$2" ;;
    hook) [[ $# == 2 ]] || exit 2; probe_hook "$2" || exit 2 ;;
    target) shift; target "$@" ;;
    inspect) [[ $# == 2 ]] || exit 2; inspect "$2" ;;
    run) [[ $# == 4 ]] || exit 2; run_live "$2" "$3" "$4" ;;
    *) printf 'usage: %s prepare|hook|target|inspect|run PATH [ARGS]\n' "$0" >&2; exit 2 ;;
esac
