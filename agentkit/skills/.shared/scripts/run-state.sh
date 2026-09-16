#!/usr/bin/env bash
# run-state.sh -- one validated, owner-private JSON object of run bookkeeping
# (redrive attempts, parked PRs, per-PR loop status) so the root records a state
# change with one call and a resumed session reads it back (issue #613). The
# file is <run dir>/run-state.json (run-dir.sh --run-id) or an explicit --file.
set -euo pipefail
umask 077
readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
readonly SCRIPT_DIR
# Same shared->skill resolution shape as review-provider-config.sh:14.
RUN_DIR_SH=${RUN_STATE_RUN_DIR_SH:-$SCRIPT_DIR/../../review-remote-pr/scripts/run-dir.sh}
readonly PATH_RE='^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$'
# Presence is tracked by key membership (jq `has`), not by comparing the value
# to null, so a key explicitly set to JSON null is present, not absent.
# shellcheck disable=SC2016  # $p/$d/$seg are jq bindings, not shell ones.
readonly PATH_EXISTS_DEF='def path_exists($p): . as $d | reduce $p[] as $seg
    ({p: true, c: $d};
        if .p and (.c | type) == "object" and (.c | has($seg)) then {p: true, c: .c[$seg]}
        else {p: false, c: null} end)
    | .p;'
ACTION=''; FILE=''; RUN_ID=''; REPO_ROOT=''; KEY_PATH=''; VALUE=''; JSON_VALUE=''; VALUE_SET=0

usage() {
    cat <<EOF
Usage: $PROGNAME get|set|append|append-unique|unset (--file FILE | --run-id ID [--repo-root DIR]) --path a.b.c [--value V | --json J]
       $PROGNAME latest --repo-root DIR --path a.b.c
get     print the value at --path (scalars raw, objects/arrays compact JSON, null as "null");
        exit 11 when the key is absent -- a key explicitly set to JSON null is present, not absent
set     store --value (string), --json (parsed), or true when neither is given
append  append --value/--json to the array at --path (created when absent; a non-array, including
        an existing null-valued key, refuses)
append-unique  append only when the same JSON value is not already present; preserves first-seen order
unset   remove --path
latest  select the newest trusted run state and print {"run_id":ID,"value":VALUE};
        exit 11 when no run state or requested path exists
The file must be absent or an owned, non-symlink regular file holding exactly one JSON object;
anything else (unparseable, empty, or more than one JSON value) exits 1 (never read as empty).
Writes are atomic (temp file beside it, mode 0600, rename).
Exit: 0 ok; 1 evidence unavailable or unparseable state; 2 usage; 11 get/latest: absent.
EOF
}
die() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; exit 1; }
die_usage() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; usage >&2; exit 2; }
require_value() { [[ -n ${2:-} ]] || die_usage "option $1 requires a value"; }

parse_args() {
    (($#)) || die_usage 'a subcommand is required'
    case $1 in
        get|set|append|append-unique|unset|latest) ACTION=$1; shift ;;
        --) shift; (($# == 0)) || die_usage "unexpected argument after --: $1"; die_usage 'a subcommand is required' ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown subcommand: $1" ;;
    esac
    while (($#)); do
        case $1 in
            --) shift; (($# == 0)) || die_usage "unexpected argument after --: $1"; break ;;
            --file) require_value "$1" "${2:-}"; FILE=$2; shift 2 ;;
            --run-id) require_value "$1" "${2:-}"; RUN_ID=$2; shift 2 ;;
            --repo-root) require_value "$1" "${2:-}"; REPO_ROOT=$2; shift 2 ;;
            --path) require_value "$1" "${2:-}"; KEY_PATH=$2; shift 2 ;;
            --value) require_value "$1" "${2:-}"; VALUE=$2; VALUE_SET=1; shift 2 ;;
            --json) require_value "$1" "${2:-}"; JSON_VALUE=$2; VALUE_SET=1; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $KEY_PATH ]] || die_usage '--path is required'
    [[ $KEY_PATH =~ $PATH_RE ]] || die_usage "--path must be dot-separated [A-Za-z0-9_-] segments: $KEY_PATH"
    [[ -z $VALUE || -z $JSON_VALUE ]] || die_usage '--value and --json are mutually exclusive'
    [[ $ACTION != get && $ACTION != unset && $ACTION != latest || $VALUE_SET == 0 ]] || die_usage "$ACTION takes no --value/--json"
    if [[ $ACTION == latest ]]; then
        [[ -z $FILE && -z $RUN_ID ]] || die_usage 'latest accepts --repo-root, not --file/--run-id'
        [[ -n $REPO_ROOT ]] || die_usage 'latest requires --repo-root'
        command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
        return
    fi
    if [[ -n $FILE && -n $RUN_ID ]]; then die_usage '--file and --run-id are mutually exclusive'; fi
    [[ -n $FILE || -n $RUN_ID ]] || die_usage 'either --file or --run-id is required'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
}

latest_state() {
    local repo_root agent_dir evidence candidate state_file mode mtime run_id
    local selected_mtime='' selected_run_id='' selected_state=''
    [[ -d $REPO_ROOT ]] || die_usage "--repo-root is not a directory: $REPO_ROOT"
    repo_root=$(cd -P -- "$REPO_ROOT" && pwd -P) || die 'could not resolve --repo-root'
    agent_dir=$repo_root/.agent
    [[ ! -L $agent_dir ]] || die "environment state directory must not be a symlink: $agent_dir"
    [[ -e $agent_dir ]] || exit 11
    [[ -d $agent_dir ]] || die "environment state directory must be a directory: $agent_dir"
    evidence=$agent_dir/evidence
    [[ ! -L $evidence ]] || die "evidence directory must not be a symlink: $evidence"
    [[ -e $evidence ]] || exit 11
    [[ -d $evidence && -O $evidence ]] || die "evidence directory must be an owned directory: $evidence"
    mode=$(stat -c %a -- "$evidence") || die "evidence directory mode was unreadable: $evidence"
    [[ $mode == 700 ]] || die "evidence directory must be owner-private (mode 0700): $evidence"

    shopt -s nullglob
    for candidate in "$evidence"/run-*; do
        [[ ! -L $candidate ]] || die "candidate run directory must not be a symlink: $candidate"
        [[ -d $candidate && -O $candidate ]] || die "candidate run must be an owned directory: $candidate"
        mode=$(stat -c %a -- "$candidate") || die "candidate run mode was unreadable: $candidate"
        [[ $mode == 700 ]] || die "candidate run must be owner-private (mode 0700): $candidate"
        state_file=$candidate/run-state.json
        [[ ! -L $state_file ]] || die "state file must not be a symlink: $state_file"
        [[ -e $state_file ]] || continue
        FILE=$state_file
        read_state
        mtime=$(stat -c %y -- "$state_file") || die "state file mtime was unreadable: $state_file"
        run_id=${candidate##*/run-}
        if [[ -z $selected_mtime || $mtime > $selected_mtime ||
            ($mtime == "$selected_mtime" && $run_id > $selected_run_id) ]]; then
            selected_mtime=$mtime
            selected_run_id=$run_id
            selected_state=$STATE
        fi
    done
    [[ -n $selected_run_id ]] || exit 11

    local path present value
    path=$(jq_path)
    present=$(jq -r --argjson p "$path" "$PATH_EXISTS_DEF"' path_exists($p) | if . then "present" else "absent" end' <<< "$selected_state")
    [[ $present == present ]] || exit 11
    value=$(jq -c --argjson p "$path" 'getpath($p)' <<< "$selected_state") || die 'could not read latest run state path'
    jq -nc --arg run_id "$selected_run_id" --argjson value "$value" '{run_id: $run_id, value: $value}'
}

resolve_file() {
    [[ -z $RUN_ID ]] && return 0
    local run_dir
    local -a args=(--run-id "$RUN_ID")
    [[ -z $REPO_ROOT ]] || args+=(--repo-root "$REPO_ROOT")
    [[ -x $RUN_DIR_SH ]] || die "run-dir.sh not found at $RUN_DIR_SH; evidence unavailable"
    run_dir=$("$RUN_DIR_SH" "${args[@]}") || die 'could not resolve the run directory'
    FILE=$run_dir/run-state.json
}

# The file is trusted only as an owned, non-symlink regular file holding
# exactly one JSON object. `jq` (without -s) validates each whitespace- or
# newline-separated JSON value in the file independently, so a file holding
# two objects would pass a per-value filter -- slurp (-s) into one array
# first and require it hold exactly one object.
read_state() {
    [[ ! -L $FILE ]] || die "state file must not be a symlink: $FILE"
    if [[ ! -e $FILE ]]; then STATE='{}'; return 0; fi
    [[ -f $FILE && -O $FILE ]] || die "state file must be an owned regular file: $FILE"
    local mode
    mode=$(stat -c %a -- "$FILE") || die "state file mode was unreadable: $FILE"
    (( (8#$mode & 8#077) == 0 )) || die "state file must be owner-private (mode 0600): $FILE"
    STATE=$(jq -ecs 'if length == 1 and (.[0] | type) == "object" then .[0] else error("not one JSON object") end' "$FILE" 2>/dev/null) ||
        die "unparseable run state (not one JSON object): $FILE"
}

jq_path() { jq -nc --arg p "$KEY_PATH" '$p | split(".")'; }

value_json() {
    if [[ -n $JSON_VALUE ]]; then
        jq -c '.' <<< "$JSON_VALUE" 2>/dev/null || die_usage "--json is not valid JSON: $JSON_VALUE"
    elif ((VALUE_SET)); then
        jq -nc --arg v "$VALUE" '$v'
    else
        printf 'true'
    fi
}

write_state() {
    local next=$1 dir staged
    dir=$(dirname -- "$FILE")
    [[ -d $dir && ! -L $dir ]] || die "state directory must be an existing directory: $dir"
    staged=$(mktemp "$dir/.run-state.XXXXXX") || die "could not stage the state file in $dir"
    printf '%s\n' "$next" >"$staged" || { rm -f -- "$staged"; die "could not write the state file: $FILE"; }
    chmod 600 -- "$staged"
    mv -f -- "$staged" "$FILE" || { rm -f -- "$staged"; die "could not replace the state file: $FILE"; }
}

main() {
    parse_args "$@"
    if [[ $ACTION == latest ]]; then
        latest_state
        return
    fi
    resolve_file
    # Lock a stable inode, not the JSON inode replaced by write_state. Resolve
    # parent aliases so independent writers cannot lose successful updates.
    local parent lock lock_fd
    [[ ! -L $FILE ]] || die "state file must not be a symlink: $FILE"
    if [[ $ACTION != get ]]; then
        parent=$(cd -P -- "$(dirname -- "$FILE")" && pwd -P) || die 'state directory unavailable'
        FILE=$parent/$(basename -- "$FILE")
        lock=$FILE.lock
        [[ ! -L $lock && (! -e $lock || (-f $lock && -O $lock)) ]] || die 'unsafe state lock'
        exec {lock_fd}>>"$lock"
        flock -w 10 "$lock_fd" || die 'state lock unavailable after 10 seconds'
    fi
    read_state
    local path next present value=''
    path=$(jq_path)
    if [[ $ACTION == set || $ACTION == append || $ACTION == append-unique ]]; then
        value=$(value_json) || exit $?
    fi
    case $ACTION in
        get)
            present=$(jq -r --argjson p "$path" "$PATH_EXISTS_DEF"' path_exists($p) | if . then "present" else "absent" end' <<< "$STATE")
            [[ $present == present ]] || exit 11
            jq -r --argjson p "$path" 'getpath($p) | if type == "string" then . else tojson end' <<< "$STATE"
            ;;
        set)
            next=$(jq -c --argjson p "$path" --argjson v "$value" 'setpath($p; $v)' <<< "$STATE") || die 'could not set the path'
            write_state "$next"
            ;;
        append)
            next=$(jq -ec --argjson p "$path" --argjson v "$value" \
                "$PATH_EXISTS_DEF"' path_exists($p) as $present | getpath($p) as $cur |
                 if $present then
                     (if ($cur | type) == "array" then setpath($p; $cur + [$v]) else error("not an array") end)
                 else setpath($p; [$v]) end' \
                <<< "$STATE" 2>/dev/null) || die "append target is not an array: $KEY_PATH"
            write_state "$next"
            ;;
        append-unique)
            next=$(jq -ec --argjson p "$path" --argjson v "$value" \
                "$PATH_EXISTS_DEF"' path_exists($p) as $present | getpath($p) as $cur |
                 if $present then
                     (if ($cur | type) == "array" then
                         setpath($p; if any($cur[]; . == $v) then $cur else $cur + [$v] end)
                      else error("not an array") end)
                 else setpath($p; [$v]) end' \
                <<< "$STATE" 2>/dev/null) || die "append-unique target is not an array: $KEY_PATH"
            [[ $next == "$STATE" ]] || write_state "$next"
            ;;
        unset)
            next=$(jq -c --argjson p "$path" 'delpaths([$p])' <<< "$STATE") || die 'could not unset the path'
            write_state "$next"
            ;;
    esac
}

main "$@"
