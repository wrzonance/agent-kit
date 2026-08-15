#!/usr/bin/env bash
# Report onboarding drift without changing the repository contract.
#
# The detector and CI comparison are intentionally reused here rather than
# reimplemented in the SessionStart hook. This keeps the cheap report and the
# operator's refresh view on one boundary, and keeps the hook to one bounded
# probe.
set -uo pipefail

readonly PROGRAM=${0##*/}

usage() {
    printf 'usage: %s [--repo-root DIR] [--report|--summary|--inventory]\n' "$PROGRAM" >&2
    exit 2
}

repo_root=''
mode=report
while (($#)); do
    case $1 in
        --repo-root)
            (($# >= 2)) || usage
            repo_root=$2
            shift 2
            ;;
        --report) mode=report; shift ;;
        --summary) mode=summary; shift ;;
        --inventory) mode=inventory; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")
fi
[[ -d $repo_root ]] || {
    printf '%s: not a directory: %s\n' "$PROGRAM" "$repo_root" >&2
    exit 3
}
repo_root=$(cd -- "$repo_root" && pwd -P) || exit 3

self_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
detector=$self_dir/detect-toolchains.sh
ci_gap=$self_dir/ci-gap.sh
config=$repo_root/.agent/config.env

declare -A current_components=() old_components=()
declare -A current_binary=() current_state=() current_rundir=()
declare -A old_binary=() old_state=() old_rundir=()
old_component_inventory=0

component_record() {
    local line=$1 payload path rest lang marker
    [[ $line == 'component= path='* ]] || return 1
    payload=${line#component= path=}
    path=${payload%% lang=*}
    rest=${payload#* lang=}
    lang=${rest%% marker=*}
    marker=${rest#* marker=}
    marker=${marker%% runner=*}
    printf '%s|%s|%s' "$path" "$lang" "$marker"
}

legacy_component_record() {
    local line=$1 body path details lang marker
    [[ $line == '# component: '* ]] || return 1
    body=${line#'# component: '}
    path=${body%% (*}
    details=${body#"$path ("}
    lang=${details%%,*}
    marker=${details#*, }
    marker=${marker%)}
    printf '%s|%s|%s' "$path" "$lang" "$marker"
}

first_argv() {
    local value=$1 quote=${1:0:1}
    if [[ $quote == '"' || $quote == "'" ]]; then
        value=${value:1}
        value=${value%%"$quote"*}
    else
        value=${value%% *}
    fi
    printf '%s' "$value"
}

unquote_token() {
    local value=$1
    if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
        printf '%s' "${value:1:${#value}-2}"
    elif [[ ${value:0:1} == "'" && ${value: -1} == "'" ]]; then
        printf '%s' "${value:1:${#value}-2}"
    else
        printf '%s' "$value"
    fi
}

binary_present() {
    local binary=$1 rundir=${2:-} candidate
    if [[ $binary == */* ]]; then
        # Inventory is repository data. Do not let a malformed comment turn a
        # report into a filesystem probe outside the target checkout.
        [[ $binary != /* && $binary != *..* && $rundir != /* && $rundir != *..* ]] || return 1
        candidate=$repo_root
        [[ -z $rundir ]] || candidate=$candidate/$rundir
        [[ -x $candidate/$binary ]]
        return
    fi
    command -v "$binary" > /dev/null 2>&1
}

collect_current() {
    local line key value binary rundir record
    local components='' suggestions=''
    if [[ -x $detector ]]; then
        components=$("$detector" --repo-root "$repo_root" --format components 2> /dev/null || true)
        suggestions=$("$detector" --repo-root "$repo_root" --format suggestions 2> /dev/null || true)
    fi

    while IFS= read -r line; do
        record=$(component_record "$line" 2> /dev/null || true)
        [[ -n $record ]] && current_components[$record]=1
    done <<< "$components"

    while IFS= read -r line; do
        if [[ $line == '# AGENT_RUNDIR_'*=* ]]; then
            key=${line#\# }
            key=${key%%=*}
            value=${line#*=}
            current_rundir[$key]=$(unquote_token "$value")
        elif [[ $line == '# AGENT_CMD_'*=* ]]; then
            key=${line#\# }
            key=${key%%=*}
            value=${line#*=}
            binary=$(first_argv "$value")
            current_binary[$key]=$binary
        fi
    done <<< "$suggestions"

    for key in "${!current_binary[@]}"; do
        rundir=${current_rundir[$key]:-}
        if binary_present "${current_binary[$key]}" "$rundir"; then
            current_state[$key]=present
        else
            current_state[$key]=missing
        fi
    done
}

collect_old() {
    local line record payload key binary state rundir
    [[ -r $config ]] || return 0
    while IFS= read -r line; do
        case $line in
            '# proposal-component|'*)
                payload=${line#'# proposal-component|'}
                old_components[$payload]=1
                old_component_inventory=1
                ;;
            '# proposal-command|'*)
                payload=${line#'# proposal-command|'}
                IFS='|' read -r key binary state rundir <<< "$payload"
                [[ -n $key ]] || continue
                old_binary[$key]=$binary
                old_state[$key]=$state
                old_rundir[$key]=$rundir
                ;;
            '# component: '*)
                record=$(legacy_component_record "$line" 2> /dev/null || true)
                if [[ -n $record ]]; then
                    old_components[$record]=1
                    old_component_inventory=1
                fi
                ;;
        esac
    done < "$config"
}

generator_version() {
    local plugin_root manifest
    plugin_root=$(cd -- "$self_dir/../../.." 2> /dev/null && pwd -P) || return 1
    manifest=$plugin_root/.codex-plugin/plugin.json
    [[ -r $manifest ]] || return 1
    command -v jq > /dev/null 2>&1 || return 1
    jq -r '.version // empty' < "$manifest" 2> /dev/null
}

format_delta() {
    local plus=$1 minus=$2
    if ((plus && minus)); then
        printf '+%d/-%d' "$plus" "$minus"
    elif ((plus)); then
        printf '+%d' "$plus"
    else
        printf -- '-%d' "$minus"
    fi
}

collect_ci() {
    ci_output=''
    ci_uncovered=''
    ci_gates=''
    [[ -x $ci_gap && -r $config ]] || return 0
    ci_output=$("$ci_gap" --repo-root "$repo_root" 2> /dev/null || true)
    ci_uncovered=$(sed -n 's/^ci-gap=.*uncovered=\([0-9][0-9]*\)$/\1/p' <<< "$ci_output" | head -n 1)
    [[ ${ci_uncovered:-0} =~ ^[0-9]+$ ]] || ci_uncovered=''
    ci_gates=$(sed -n '/^NOT covered by any declared command/,/^$/ { /^  /s/^  /ci-gap-gate= /p; }' <<< "$ci_output")
}

print_inventory() {
    local record key
    for record in "${!current_components[@]}"; do
        printf '%s\n' "# proposal-component|$record"
    done | sort
    for key in "${!current_binary[@]}"; do
        printf '%s\n' "# proposal-command|$key|${current_binary[$key]}|${current_state[$key]}|${current_rundir[$key]:-}"
    done | sort
}

summary=''
ci_output=''; ci_uncovered=''; ci_gates=''

if [[ $mode == inventory ]]; then
    collect_current
    print_inventory
    exit 0
fi

if [[ ! -r $config ]]; then
    printf 'drift= none\n'
    exit 0
fi

collect_current
collect_old
collect_ci

added_components=0
removed_components=0
added_lines=''; removed_lines=''
if ((old_component_inventory)); then
    for record in "${!current_components[@]}"; do
        [[ ${old_components[$record]+yes} == yes ]] && continue
        added_components=$((added_components + 1))
        added_lines+="component= added path=${record%%|*}"$'\n'
    done
    for record in "${!old_components[@]}"; do
        [[ ${current_components[$record]+yes} == yes ]] && continue
        removed_components=$((removed_components + 1))
        removed_lines+="component= removed path=${record%%|*}"$'\n'
    done
fi

tool_plus=0
tool_minus=0
tool_lines=''
for key in "${!old_state[@]}"; do
    if [[ ${current_state[$key]+yes} != yes ]]; then
        [[ ${old_state[$key]} == present ]] || continue
        [[ -n ${old_binary[$key]:-} ]] || continue
        binary_present "${old_binary[$key]}" "${old_rundir[$key]:-}" && continue
        current_state[$key]=missing
        current_binary[$key]=${old_binary[$key]}
    fi
    [[ ${old_state[$key]} == "${current_state[$key]}" ]] && continue
    if [[ ${current_state[$key]} == present ]]; then
        tool_plus=$((tool_plus + 1))
    else
        tool_minus=$((tool_minus + 1))
    fi
    binary=${current_binary[$key]:-${old_binary[$key]}}
    tool_lines+="toolchain= key=$key binary=$binary status=${old_state[$key]}->${current_state[$key]}"$'\n'
done

recorded_generator=$(sed -n 's/^AGENT_ONBOARDED_BY=//p' "$config" | head -n 1)
installed_version=$(generator_version || true)
installed_generator=''
[[ -n $installed_version ]] && installed_generator="agentkit/$installed_version"
generator_stale=0
if [[ -n $installed_generator && $recorded_generator != "$installed_generator" ]]; then
    generator_stale=1
fi

path_drift=''
if [[ -x $detector ]]; then
    path_drift=$("$detector" --repo-root "$repo_root" --format drift 2> /dev/null || true)
fi

parts=()
if ((added_components || removed_components)); then
    parts+=("components=$(format_delta "$added_components" "$removed_components")")
fi
if ((tool_plus || tool_minus)); then
    parts+=("toolchains=$(format_delta "$tool_plus" "$tool_minus")")
fi
((generator_stale)) && parts+=("generator=stale")
if [[ ${ci_uncovered:-0} =~ ^[1-9][0-9]*$ ]]; then
    parts+=("ci-gaps=$ci_uncovered")
fi

if ((${#parts[@]} == 0)) && [[ -z $path_drift ]]; then
    summary='drift= none'
else
    summary="drift= ${parts[*]}"
    if ((${#parts[@]} == 0)); then
        summary='drift= components=paths'
    fi
fi

if [[ $mode == summary ]]; then
    printf '%s\n' "$summary"
    exit 0
fi

printf '%s\n' "$summary"
printf '%s' "$added_lines$removed_lines$tool_lines"
if ((generator_stale)); then
    printf 'generator= stale recorded=%s installed=%s\n' \
        "${recorded_generator:-none}" "$installed_generator"
fi
if [[ -n $path_drift ]]; then
    printf '%s\n' "$path_drift"
fi
if [[ -n $ci_gates ]]; then
    printf '%s\n' "$ci_gates"
fi
