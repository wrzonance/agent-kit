#!/usr/bin/env bash
set -euo pipefail
self=$(realpath -- "${BASH_SOURCE[0]}")

prepare() {
    local target=$1 audit=$2 compatibility=$3 cli=$4 kit snapshot native metadata mode arm helper python
    local -a modes=(control rewrite)
    [[ ${5:-} != boundaries ]] || modes=(smoke denied timeout)
    [[ $target == /* && ! -e $target && ! -L $target ]] || return 2
    umask 077
    mkdir -m 700 -- "$target"
    cp -- "$self" "$target/driver.sh"
    kit=$(realpath -- "${self%/*}/../../agentkit")
    cp -a -- "$kit" "$target/kit"
    snapshot=$(printf '%s\n' "$audit"/prefix-*.snapshot)
    [[ -f $snapshot ]] || return 2
    native=${snapshot%.snapshot}.command
    metadata=${snapshot%.snapshot}.json
    helper="$target/kit/skills/.shared/scripts/agent-run.sh"
    python=$(readlink -f /usr/bin/python3)
    cli=$(realpath -m -- "$cli")
    printf '%s\n' "${modes[@]}" > "$target/arms"
    for mode in "${modes[@]}"; do
        arm="$target/$mode"
        mkdir -m 700 -- "$arm" "$arm/repo" "$arm/repo/.agent"
        git -C "$arm/repo" init -q
        printf 'AGENT_CMD_TEST=./verify.sh\n' > "$arm/repo/.agent/config.env"
        printf '#!/usr/bin/env bash\nexec bash %q target %q "$@"\n' "$target/driver.sh" "$arm" > "$arm/repo/verify.sh"
        chmod 700 -- "$arm/repo/verify.sh"
        jq -nc --arg kit "$target/kit" --arg cwd "$arm/repo" --arg snapshot "$snapshot" \
            --arg native "$native" --arg snapshotHash "$(sha256sum "$snapshot" | cut -d ' ' -f 1)" \
            --arg nativeHash "$(sha256sum "$native" | cut -d ' ' -f 1)" \
            --arg compatibility "$compatibility" --arg sources "${compatibility%/*}/sources.sha256" --arg cli "$cli" --arg python "$python" \
            --arg arm "$arm" --arg mode "$mode" --arg helper "$helper" --arg snapshotRoot "$(dirname -- "$(jq -er .snapshotPath "$metadata")")" '
            {kit:$kit,cwd:$cwd,auditSnapshot:$snapshot,auditNative:$native,
             reviewedHashes:{snapshot:$snapshotHash,native:$nativeHash},
             provider:($compatibility+"/provider.jsonl"),events:($compatibility+"/events.ndjson"),
             execution:($compatibility+"/execution.json"),manifest:($compatibility+"/manifest.json"),
             sources:$sources,cli:$cli,python:$python,
             prefix:($arm+"/prefix.sh"),settings:($arm+"/settings.json"),snapshotRoot:$snapshotRoot,
             allow:(if $mode=="denied" then ["Bash(pwd)","Bash(printf:*)"]
                    else ["Bash(pwd)",("Bash("+$helper+" --cmd test)")] end)}' > "$arm/spec.json"
        printf '{"mcpServers":{}}\n' > "$arm/mcp.json"
        printf '%s\n' "First run exactly pwd with Bash timeout 10000 and wait for its result. Then run exactly agent-run.sh --cmd test with Bash timeout 10000. If denied, execute exactly $helper --cmd test once with the same timeout. Do not inspect files, combine commands, use other tools, or retry otherwise. Report the observed result." > "$arm/prompt.txt"
        if [[ $mode == denied ]]; then
            printf '%s\n' "First run exactly pwd with Bash timeout 10000. Next run exactly: printf '%s\\n' 'agent-run.sh --cmd test'. Then run exactly agent-run.sh --cmd test with Bash timeout 10000. Wait for each result. Never retry a denial, inspect files, combine commands, or use other tools. Report observed results." > "$arm/prompt.txt"
        elif [[ $mode == timeout ]]; then
            printf '%s\n' 'First run exactly pwd with Bash timeout 10000. Then run exactly agent-run.sh --cmd test with Bash timeout 1000. Wait for each result. Never retry, inspect files, combine commands, or use other tools. Report the observed result, including any timeout or background status.' > "$arm/prompt.txt"
        fi
    done
    find "$target" -type f ! -name sources.sha256 -print0 | sort -z | xargs -0 sha256sum > "$target/sources.sha256"
    printf 'production-probe-prepared: %s (no provider launched or profile attested)\n' "$target"
}

target() {
    local arm=$1
    shift
    [[ $# == 0 && $PWD == "$arm/repo" && ${AGENTKIT_REWRITE_PROBE_ENV:-} == synthetic ]] || return 2
    mkdir -- "$arm/entry-once" || return 78
    if [[ ${arm##*/} == timeout ]]; then
        jq -nc --arg cwd "$PWD" --argjson pid "$$" '{cwd:$cwd,argv:[],environment:"synthetic",pid:$pid,exitCode:null}' > "$arm/execution.json"
        exec /bin/sleep 30
    fi
    jq -nc --arg cwd "$PWD" '{cwd:$cwd,argv:[],environment:"synthetic",exitCode:0}' > "$arm/execution.json"
    printf 'PRODUCTION-REWRITE-TARGET\n'
    printf 'PRODUCTION-REWRITE-STDERR\n' >&2
}

inspect() {
    local target=$1 mode arm profile session record
    while IFS= read -r mode; do
        arm="$target/$mode"
        [[ $(cat "$arm/provider-exit") == 0 ]] || return 1
        jq -es '[.[]|select(.type=="system" and .subtype=="init")]
            | length==1 and .[0].plugins==[] and .[0].claude_code_version=="2.1.272"' "$arm/provider.jsonl" > /dev/null
        if [[ $mode == denied ]]; then
            [[ ! -e $arm/execution.json && ! -e $arm/entry-once ]] || return 1
        elif [[ $mode == timeout ]]; then
            jq -e --arg cwd "$arm/repo" '.cwd==$cwd and .argv==[] and .environment=="synthetic"
                and .exitCode==null and (.pid|type=="number")' "$arm/execution.json" > /dev/null
        elif [[ $mode != timeout ]]; then
            jq -e --arg cwd "$arm/repo" '.=={cwd:$cwd,argv:[],environment:"synthetic",exitCode:0}' "$arm/execution.json" > /dev/null
        fi
        profile=$(cat "$arm/profile-path")
        session=$(jq -sr '[.[]|select(.type=="system" and .subtype=="init")][0].session_id' "$arm/provider.jsonl")
        record="${profile%/profiles/*}/sessions/$(basename "$profile" .json)/$(printf '%s' "$session" | sha256sum | cut -d ' ' -f 1)/records.json"
        [[ -f $record ]] || return 1
        cp -- "$record" "$arm/runtime-record.json"
        jq -en --slurpfile state "$arm/runtime-record.json" --arg mode "$mode" '
            if $mode=="control" then ($state[0].results|length)==0
            elif $mode=="denied" then
              ($state[0].pending.consumed==false or
               (($state[0].results|length)==1 and $state[0].results[0].executionClaimed==false))
            elif $mode=="timeout" then
              ($state[0].pending.consumed==true or
               (($state[0].results|length)==1 and $state[0].results[0].executionClaimed==true))
            else ($state[0].results|length)==1 and $state[0].results[0].executionClaimed==true
              and $state[0].results[0].original=="agent-run.sh --cmd test"
            end' > /dev/null
        jq -sc --arg mode "$mode" '[.[]|select(.type=="result")][0]
            | {mode:$mode,turns:.num_turns,costUsd:.total_cost_usd,usage:.usage}' "$arm/provider.jsonl" > "$arm/result.json"
    done < "$target/arms"
    if [[ -d $target/denied ]]; then
        jq -n --slurpfile smoke "$target/smoke/result.json" --slurpfile denied "$target/denied/result.json" \
            --slurpfile timed "$target/timeout/result.json" '{smoke:$smoke[0],denied:$denied[0],timeout:$timed[0],
              nativeSemantics:"requires-event-and-process-inspection"}'
        return
    fi
    jq -n --slurpfile control "$target/control/result.json" --slurpfile rewrite "$target/rewrite/result.json" \
        '{control:$control[0],rewrite:$rewrite[0],targetEntriesPerArm:1,
          observedTurnDifference:($control[0].turns-$rewrite[0].turns),
          permissionTimeoutAndNegativeAcceptance:"requires-native-event-inspection"}'
}

run_live() {
    local target=$1 marker=$2 mode arm profile cli rc
    [[ $marker == --root-authorized-live ]] || return 2
    sha256sum -c --status "$target/sources.sha256"
    umask 077
    while IFS= read -r mode; do
        arm="$target/$mode"
        [[ ! -e $arm/provider.jsonl && ! -e $arm/profile-path ]] || return 2
        AGENTKIT_REWRITE_PROBE_ENV=synthetic /usr/bin/python3 -I "$target/kit/skills/.shared/scripts/rewrite-profile.py" \
            attest "$arm/spec.json" "$(sha256sum "$arm/spec.json" | cut -d ' ' -f 1)" > "$arm/profile-path"
        shellcheck "$arm/prefix.sh"
        profile=$(cat "$arm/profile-path")
        cli=$(jq -r .cli "$arm/spec.json")
        [[ $mode != control ]] || profile=''
        printf 'production-probe-running: %s\n' "$mode"
        rc=0
        (cd -- "$arm/repo" && AGENTKIT_REWRITE_PROFILE="$profile" AGENTKIT_REWRITE_PROBE_ENV=synthetic \
            CLAUDE_CODE_SHELL=/bin/bash CLAUDE_CODE_SHELL_PREFIX="$arm/prefix.sh" \
            timeout -k 5 120 "$cli" --restricted --tools Bash --disable-slash-commands \
            --settings "$arm/settings.json" --strict-mcp-config --mcp-config "$arm/mcp.json" \
            --permission-mode manual --permission-prompts none --no-chrome --no-session-persistence \
            --model claude-sonnet-5 --effort medium --max-budget-usd 1 \
            --output-format stream-json --include-hook-events --verbose -p "$(cat "$arm/prompt.txt")") \
            > "$arm/provider.jsonl" 2> "$arm/provider.stderr" || rc=$?
        printf '%s\n' "$rc" > "$arm/provider-exit"
        ((rc == 0)) || return "$rc"
    done < "$target/arms"
    inspect "$target"
}

case ${1:-} in
    prepare) [[ $# == 5 ]] || exit 2; prepare "$2" "$3" "$4" "$5" ;;
    prepare-boundaries) [[ $# == 5 ]] || exit 2; prepare "$2" "$3" "$4" "$5" boundaries ;;
    target) shift; target "$@" ;;
    inspect) [[ $# == 2 ]] || exit 2; inspect "$2" ;;
    run) [[ $# == 3 ]] || exit 2; run_live "$2" "$3" ;;
    *) exit 2 ;;
esac
