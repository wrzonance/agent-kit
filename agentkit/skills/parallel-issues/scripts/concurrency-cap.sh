#!/usr/bin/env bash
# Read the runtime's advertised child-thread cap without embedding an awk
# parser in the dispatch skill.  A runtime that cannot spawn agents degrades to
# one serial worker and therefore has no cap to advertise.
set -uo pipefail

readonly PROGRAM=${0##*/}
if [[ -n ${CODEX_HOME:-} ]]; then
    config_file=$CODEX_HOME/config.toml
else
    config_file=${HOME:-}/.codex/config.toml
fi
spawn_mode=auto

usage() {
    cat <<'EOF'
Usage: concurrency-cap.sh [--config FILE] [--spawn-capable|--no-spawn]

Prints the runtime concurrency cap for a spawning session.  When spawning is
unavailable, prints the serial worker path and exits successfully without
requiring a runtime config file.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --config)
            (($# >= 2)) || die '--config requires a file path'
            config_file=$2
            shift 2
            ;;
        --spawn-capable) spawn_mode=yes; shift ;;
        --no-spawn) spawn_mode=no; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

# The runtime integration can explicitly report capability through either
# spelling used by the two supported dispatch adapters. Explicit CLI flags
# always win, and an unset variable remains the normal spawning path.
if [[ $spawn_mode == auto ]]; then
    capability=${MULTI_AGENT:-${multi_agent:-${AGENT_MULTI_AGENT:-${SPAWN_CAPABILITY:-${spawn_capability:-}}}}}
    case ${capability,,} in
        0|false|no|none|unavailable|disabled) spawn_mode=no ;;
        1|true|yes|available|enabled) spawn_mode=yes ;;
    esac
fi

if [[ $spawn_mode == no ]]; then
    printf '%s\n' 'runtime concurrency: spawn unavailable; worker=self (spawn unavailable); serial=true'
    exit 0
fi

command -v awk >/dev/null 2>&1 || die 'Unable to advertise concurrency: awk is missing; cannot inspect runtime concurrency'
[[ -e $config_file ]] || die "Unable to advertise concurrency: runtime config is absent: $config_file"
[[ -f $config_file && -r $config_file ]] ||
    die "Unable to advertise concurrency: runtime config is unreadable or not a regular file: $config_file"

probe=''
if ! probe=$(awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }
    function accepted(section) {
        return section == "agents" || section == "features.multi_agent_v2" || section == "multi_agent_v2"
    }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
        section=$0
        sub(/^[[:space:]]*\[/, "", section)
        sub(/\][[:space:]]*(#.*)?$/, "", section)
        section=trim(section)
        next
    }
    /^[[:space:]]*max_concurrent_threads_per_session[[:space:]]*=/ {
        value=$0
        sub(/^[^=]*=/, "", value)
        sub(/[[:space:]]*#.*/, "", value)
        value=trim(value)
        if (accepted(section)) {
            allowed=value
            allowed_found=1
        } else if (!outside_found) {
            outside=value
            outside_found=1
        }
    }
    END {
        if (allowed_found) print "allowed=" allowed
        else if (outside_found) print "outside=" outside
        else print "none"
    }
' "$config_file"); then
    die "Unable to advertise concurrency: could not read runtime config: $config_file"
fi

case $probe in
    allowed=*)
        cap=${probe#allowed=}
        [[ $cap =~ ^[1-9][0-9]*$ ]] ||
            die "Unable to advertise concurrency: runtime concurrency value is non-numeric or non-positive: $cap"
        printf 'runtime concurrency cap: %s total threads, including the root\n' "$cap"
        ;;
    outside=*)
        die 'Unable to advertise concurrency: max_concurrent_threads_per_session is outside the accepted sections ([agents], [features.multi_agent_v2], or [multi_agent_v2])'
        ;;
    *)
        die 'Unable to advertise concurrency: max_concurrent_threads_per_session is absent from the accepted sections ([agents], [features.multi_agent_v2], or [multi_agent_v2])'
        ;;
esac
