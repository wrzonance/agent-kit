# shellcheck shell=bash
# Read-only checks for declarations required by the worker workflow.

probe_config() {
    local resolver listing count keys shown extra
    resolver="$SCRIPT_DIR/repo-config.sh"
    listing=""
    if [[ -x "$resolver" && -n "$WORKTREE" ]]; then
        listing="$("$resolver" --repo-root "$WORKTREE" --list 2>/dev/null || true)"
    fi
    if [[ -z "$listing" ]]; then
        emit 'config= present=no keys=0 supplied=none'
        return 0
    fi
    count="$(printf '%s\n' "$listing" | grep -c '=' || true)"
    # Bound the contract's summary; the full listing stays repository-local.
    shown="$(printf '%s\n' "$listing" | cut -d= -f1 | head -n 4 | paste -sd, -)"
    extra=$(( count > 4 ? count - 4 : 0 ))
    keys="$shown"
    if (( extra > 0 )); then keys="$shown,+$extra more"; fi
    emit "config= present=yes keys=$count supplied=\"$keys\""
}

# Only the detector's known native check forms, with simple literal operands.
# Unknown wrappers, quoting or shell syntax require an explicit declaration.
preflight_native_format_fix() {
    local command=$1
    local ruff='^((uv run |python3 -m )?ruff|[A-Za-z0-9_./-]+/ruff) format --check( [A-Za-z0-9_./-]+)*$' # ecosystem-allow: detection
    local dotnet='^dotnet format --verify-no-changes( [A-Za-z0-9_./-]+)*$'
    local cargo='^cargo fmt --check( [A-Za-z0-9_./-]+)*$' # ecosystem-allow: detection
    if [[ $command =~ $ruff || $command =~ $cargo ]]; then
        printf '%s' "${command/ --check/}"
    elif [[ $command =~ $dotnet ]]; then
        printf '%s' "${command/ --verify-no-changes/}"
    else
        return 1
    fi
}

preflight_required_declarations() {
    local listing key value missing=0 proposals='' fix rundir proposal_dir
    local -A declared=() proposed=()
    [[ -e $WORKTREE/.agent/config.env || -L $WORKTREE/.agent/config.env ]] || return 0
    if [[ ! -x $SCRIPT_DIR/repo-config.sh ]]; then
        note "required declaration check unavailable: $SCRIPT_DIR/repo-config.sh"
        return 1
    fi
    listing=$("$SCRIPT_DIR/repo-config.sh" --repo-root "$WORKTREE" --list) || return 1
    while IFS='=' read -r key value; do
        [[ -n $key ]] && declared[$key]=$value
    done <<< "$listing"
    for key in "${!declared[@]}"; do
        [[ $key == AGENT_CMD_FORMAT || $key == AGENT_CMD_*_FORMAT ]] || continue
        [[ -n ${declared[$key]} && -z ${declared[${key}_FIX]:-} ]] || continue
        if ((missing == 0)) && [[ -x $SCRIPT_DIR/detect-toolchains.sh ]]; then
            proposals=$("$SCRIPT_DIR/detect-toolchains.sh" --repo-root "$WORKTREE" --format suggestions) || return 1
            while IFS='=' read -r value fix; do
                [[ $value == '# AGENT_'* ]] || continue
                proposed[${value#\# }]=$fix
            done <<< "$proposals"
        fi
        missing=1
        printf 'agent-preflight: missing %s_FIX; parallel-issues worker workflow requires agent-run.sh --cmd format --fix (or the component equivalent).\n' "$key" >&2
        rundir="AGENT_RUNDIR_${key#AGENT_CMD_}"
        proposal_dir=${proposed[$rundir]:-.}
        fix=''
        if [[ ${proposed[$key]:-} == "${declared[$key]}" && $proposal_dir == "${declared[$rundir]:-.}" ]]; then
            fix=${proposed[${key}_FIX]:-}
        fi
        [[ -n $fix ]] || fix=$(preflight_native_format_fix "${declared[$key]}") || true
        if [[ -n $fix ]]; then
            printf "Proposed command: '%s'\nConfirm in .agent/config.env:\n%s_FIX=%s\n" "$fix" "$key" "$fix" >&2
            [[ -z ${declared[$rundir]:-} ]] || printf 'Also declare %s_FIX=%s\n' "$rundir" "${declared[$rundir]}" >&2
        else
            printf 'No safe FORMAT_FIX proposal: add an explicit format:fix script. Declare %s_FIX after verifying it.\n' "$key" >&2
        fi
    done
    ((missing == 0))
}
