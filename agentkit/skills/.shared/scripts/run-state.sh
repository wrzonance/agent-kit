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
ACTION=''; FILE=''; RUN_ID=''; REPO_ROOT=''; REPORTS_DIR=''; KEY_PATH=''; VALUE=''; JSON_VALUE=''; VALUE_SET=0; LEDGER=''

usage() {
    cat <<EOF
Usage: $PROGNAME get|set|append|unset (--file FILE | --run-id ID [--repo-root DIR]) --path a.b.c [--value V | --json J]
       $PROGNAME init-summary --run-id ID [--repo-root DIR]
       $PROGNAME record-summary --run-id ID [--repo-root DIR] --path COLLECTION --json POSITIVE_INTEGER
       $PROGNAME dequeue-summary --run-id ID [--repo-root DIR] --json POSITIVE_INTEGER
       $PROGNAME summary --run-id ID [--repo-root DIR] [--reports-dir DIR]
get     print the value at --path (scalars raw, objects/arrays compact JSON, null as "null");
        exit 11 when the key is absent -- a key explicitly set to JSON null is present, not absent
set     store --value (string), --json (parsed), or true when neither is given
append  append --value/--json to the array at --path (created when absent; a non-array, including
        an existing null-valued key, refuses)
unset   remove --path
summary print handoff coverage from durable run state and active-worker lifecycle evidence
init-summary create only missing summary collections, preserving every existing value
record-summary append one unique producer identity to a required summary collection
dequeue-summary remove one queued issue identity when its dispatch starts (absent is success)
The file must be absent or an owned, non-symlink regular file holding exactly one JSON object;
anything else (unparseable, empty, or more than one JSON value) exits 1 (never read as empty).
Writes are atomic (temp file beside it, mode 0600, rename).
Exit: 0 ok; 1 evidence unavailable or unparseable state; 2 usage; 11 get: absent.
EOF
}
die() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; exit 1; }
die_usage() { printf '%s: %s\n' "$PROGNAME" "$1" >&2; usage >&2; exit 2; }
require_value() { [[ -n ${2:-} ]] || die_usage "option $1 requires a value"; }

parse_args() {
    (($#)) || die_usage 'a subcommand is required'
    case $1 in
        get|set|append|unset|init-summary|record-summary|dequeue-summary|summary) ACTION=$1; shift ;;
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
            --reports-dir) require_value "$1" "${2:-}"; REPORTS_DIR=$2; shift 2 ;;
            --path) require_value "$1" "${2:-}"; KEY_PATH=$2; shift 2 ;;
            --value) require_value "$1" "${2:-}"; VALUE=$2; VALUE_SET=1; shift 2 ;;
            --json) require_value "$1" "${2:-}"; JSON_VALUE=$2; VALUE_SET=1; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -z $VALUE || -z $JSON_VALUE ]] || die_usage '--value and --json are mutually exclusive'
    if [[ $ACTION == summary ]]; then
        [[ -z $FILE ]] || die_usage 'summary requires --run-id, not --file'
        [[ -n $RUN_ID ]] || die_usage 'summary requires --run-id'
        [[ -z $KEY_PATH && $VALUE_SET == 0 ]] || die_usage 'summary takes no --path/--value/--json'
    elif [[ $ACTION == init-summary ]]; then
        [[ -z $FILE ]] || die_usage 'init-summary requires --run-id, not --file'
        [[ -n $RUN_ID ]] || die_usage 'init-summary requires --run-id'
        [[ -z $KEY_PATH && $VALUE_SET == 0 && -z $REPORTS_DIR ]] ||
            die_usage 'init-summary takes no --path/--value/--json/--reports-dir'
    elif [[ $ACTION == record-summary ]]; then
        [[ -z $FILE ]] || die_usage 'record-summary requires --run-id, not --file'
        [[ -n $RUN_ID ]] || die_usage 'record-summary requires --run-id'
        [[ -z $REPORTS_DIR ]] || die_usage 'record-summary takes no --reports-dir'
        case $KEY_PATH in opened_prs|queued|receipt_prs|skipped_prs) ;; *) die_usage 'record-summary --path must name a summary collection' ;; esac
        [[ -n $JSON_VALUE && -z $VALUE ]] || die_usage 'record-summary requires --json POSITIVE_INTEGER'
    elif [[ $ACTION == dequeue-summary ]]; then
        [[ -z $FILE ]] || die_usage 'dequeue-summary requires --run-id, not --file'
        [[ -n $RUN_ID ]] || die_usage 'dequeue-summary requires --run-id'
        [[ -z $KEY_PATH && -z $REPORTS_DIR ]] || die_usage 'dequeue-summary takes no --path/--reports-dir'
        [[ -n $JSON_VALUE && -z $VALUE ]] || die_usage 'dequeue-summary requires --json POSITIVE_INTEGER'
        KEY_PATH=queued
    else
        [[ -z $REPORTS_DIR ]] || die_usage "$ACTION takes no --reports-dir"
        [[ -n $KEY_PATH ]] || die_usage '--path is required'
        [[ $KEY_PATH =~ $PATH_RE ]] || die_usage "--path must be dot-separated [A-Za-z0-9_-] segments: $KEY_PATH"
        [[ $ACTION != get && $ACTION != unset || $VALUE_SET == 0 ]] || die_usage "$ACTION takes no --value/--json"
        if [[ -n $FILE && -n $RUN_ID ]]; then die_usage '--file and --run-id are mutually exclusive'; fi
        [[ -n $FILE || -n $RUN_ID ]] || die_usage 'either --file or --run-id is required'
    fi
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
}

resolve_summary_ledger() {
    [[ $ACTION == summary ]] || return 0
    local selected_root checkout_root primary_root
    if [[ -n $REPO_ROOT ]]; then
        [[ -d $REPO_ROOT ]] || die_usage "--repo-root is not a directory: $REPO_ROOT"
        selected_root=$(cd -P -- "$REPO_ROOT" && pwd -P) || die 'could not resolve --repo-root'
    else
        selected_root=$(git rev-parse --show-toplevel 2>/dev/null) ||
            die 'could not resolve the repository root (pass --repo-root outside a Git worktree)'
        selected_root=$(cd -P -- "$selected_root" && pwd -P) || die 'could not resolve the repository root'
    fi
    checkout_root=$(git -C "$selected_root" rev-parse --show-toplevel 2>/dev/null) ||
        die '--repo-root must be a Git checkout'
    checkout_root=$(realpath -e -- "$checkout_root") || die 'could not resolve the Git checkout root'
    [[ $selected_root == "$checkout_root" ]] || die_usage '--repo-root must name the Git checkout root'
    primary_root=$(git -C "$checkout_root" worktree list --porcelain |
        awk '/^worktree / && !found { sub(/^worktree /, ""); primary=$0; found=1 } END { if (found) print primary }')
    [[ -n $primary_root ]] || die 'could not resolve the primary checkout for active-workers evidence'
    primary_root=$(realpath -e -- "$primary_root") || die 'could not resolve the primary checkout'
    REPO_ROOT=$selected_root
    LEDGER=$primary_root/.agent/runs/active-workers.ndjson
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

print_summary() {
    local counts ledger_mode parked_rows parked_count
    counts=$(jq -er '
        def positive_ids($name; $required):
            (if has($name) then .[$name]
             elif $required then error($name + " is required")
             else [] end) as $value |
            if ($value | type) == "array" and all($value[]; type == "number" and . > 0 and floor == .)
                and (($value | length) == ($value | unique | length))
            then $value else error($name + " must be a unique positive-integer array") end;
        positive_ids("opened_prs"; true) as $prs |
        positive_ids("queued"; true) as $queued |
        positive_ids("receipt_prs"; true) as $receipts |
        positive_ids("skipped_prs"; true) as $skipped |
        if (($receipts - $prs) | length) > 0 then error("receipt_prs must be a subset of opened_prs")
        elif (($skipped - $prs) | length) > 0 then error("skipped_prs must be a subset of opened_prs")
        elif (($receipts + $skipped | length) != ($receipts + $skipped | unique | length))
            then error("receipt_prs and skipped_prs must be disjoint")
        else [($prs | length), ($receipts | length), ($skipped | length), ($queued | length)] | @tsv end
    ' <<<"$STATE" 2>/dev/null) ||
        die 'summary state requires valid opened_prs, queued, receipt_prs, and skipped_prs collections'

    [[ ! -L $LEDGER && -f $LEDGER && -r $LEDGER && -O $LEDGER ]] ||
        die "active-workers evidence must be an owned readable regular file: $LEDGER"
    ledger_mode=$(stat -c %a -- "$LEDGER") || die "could not inspect active-workers evidence: $LEDGER"
    (( (8#$ledger_mode & 8#077) == 0 )) || die "active-workers evidence must be owner-private: $LEDGER"
    parked_rows=$(jq -Rsc --arg run "$RUN_ID" '
        (split("\n") | map(select(length > 0) | fromjson)) as $rows |
        if all($rows[]; type == "object") | not then error("row is not an object") else . end |
        [$rows[] | select(.runId? == $run)] as $run_rows |
        if all($run_rows[];
            .version == 2 and (.issue | type == "number" and . > 0 and floor == .) and
            (.attempt | type == "string" and length > 0) and
            (.state == "unknown" or .state == "active" or .state == "terminal") and
            (.disposition | type == "string") and (.evidence | type == "string")) | not
        then error("malformed current-run lifecycle row") else . end |
        reduce $run_rows[] as $row ({}; .[$row.issue | tostring] = $row) |
        [.[] | select(.state == "terminal" and .disposition == "handed-back") |
            if (.evidence | length > 0 and (explode | all(. >= 32 and . != 127)))
            then . else error("invalid handback evidence") end] |
        sort_by(.issue)
    ' "$LEDGER" 2>/dev/null) || die "unparseable active-workers evidence: $LEDGER"
    parked_count=$(jq 'length' <<<"$parked_rows")

    local prs receipts skipped queued
    IFS=$'\t' read -r prs receipts skipped queued <<<"$counts"
    printf 'coverage= prs=%s receipts=%s skipped=%s parked=%s queued=%s\n' \
        "$prs" "$receipts" "$skipped" "$parked_count" "$queued"
    jq -r '.[] | "blocked=\(.issue):\(.evidence)"' <<<"$parked_rows"

    [[ -n $REPORTS_DIR ]] || return 0
    [[ ! -L $REPORTS_DIR ]] || die "verification reports directory must not be a symlink: $REPORTS_DIR"
    [[ ! -e $REPORTS_DIR || (-d $REPORTS_DIR && -O $REPORTS_DIR) ]] ||
        die "verification reports must be an owned directory: $REPORTS_DIR"
    [[ -e $REPORTS_DIR ]] || return 0
    local reports_mode report report_mode report_text
    reports_mode=$(stat -c %a -- "$REPORTS_DIR") || die "could not inspect verification reports: $REPORTS_DIR"
    (( (8#$reports_mode & 8#077) == 0 )) || die "verification reports directory must be owner-private: $REPORTS_DIR"
    local -a reports=("$REPORTS_DIR"/issue-*.report)
    [[ -e ${reports[0]} ]] || return 0
    for report in "${reports[@]}"; do
        [[ ! -L $report && -f $report && -O $report ]] || die "verification report must be an owned regular file: $report"
        report_mode=$(stat -c %a -- "$report") || die "could not inspect verification report: $report"
        (( (8#$report_mode & 8#077) == 0 )) || die "verification report must be owner-private: $report"
        report_text=$(cat -- "$report") || die "could not read verification report: $report"
        [[ $(wc -l <"$report") -eq 1 && $report_text != *$'\n'* &&
            $report_text =~ ^spec-verification=\ issue=[0-9]+\ steps=[1-9][0-9]*\  ]] ||
            die "malformed durable verification report: $report"
        cat -- "$report"
    done
}

main() {
    parse_args "$@"
    resolve_summary_ledger
    resolve_file
    # Lock a stable inode, not the JSON inode replaced by write_state. Resolve
    # parent aliases so independent writers cannot lose successful updates.
    local parent lock lock_fd
    [[ ! -L $FILE ]] || die "state file must not be a symlink: $FILE"
    if [[ $ACTION == set || $ACTION == append || $ACTION == unset || $ACTION == init-summary || $ACTION == record-summary || $ACTION == dequeue-summary ]]; then
        parent=$(cd -P -- "$(dirname -- "$FILE")" && pwd -P) || die 'state directory unavailable'
        FILE=$parent/$(basename -- "$FILE")
        lock=$FILE.lock
        [[ ! -L $lock && (! -e $lock || (-f $lock && -O $lock)) ]] || die 'unsafe state lock'
        exec {lock_fd}>>"$lock"
        flock -w 10 "$lock_fd" || die 'state lock unavailable after 10 seconds'
    fi
    read_state
    local path='' next present value=''
    [[ $ACTION == summary || $ACTION == init-summary ]] || path=$(jq_path)
    if [[ $ACTION == set || $ACTION == append || $ACTION == record-summary || $ACTION == dequeue-summary ]]; then
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
        unset)
            next=$(jq -c --argjson p "$path" 'delpaths([$p])' <<< "$STATE") || die 'could not unset the path'
            write_state "$next"
            ;;
        init-summary)
            next=$(jq -ec '
                def valid_ids($name):
                    (has($name) | not) or
                    ((.[$name] | type) == "array" and all(.[$name][]; type == "number" and . > 0 and floor == .) and
                    ((.[$name] | length) == (.[$name] | unique | length)));
                if valid_ids("opened_prs") and valid_ids("queued") and
                   valid_ids("receipt_prs") and valid_ids("skipped_prs")
                then .
                    | if has("opened_prs") then . else .opened_prs=[] end
                    | if has("queued") then . else .queued=[] end
                    | if has("receipt_prs") then . else .receipt_prs=[] end
                    | if has("skipped_prs") then . else .skipped_prs=[] end
                    | if ((.receipt_prs - .opened_prs) | length) > 0 or ((.skipped_prs - .opened_prs) | length) > 0 or
                         ((.receipt_prs + .skipped_prs | length) != (.receipt_prs + .skipped_prs | unique | length))
                      then error("inconsistent summary collections") else . end
                else error("invalid summary collection") end
            ' <<<"$STATE" 2>/dev/null) || die 'could not initialize invalid summary collections'
            write_state "$next"
            ;;
        record-summary|dequeue-summary)
            [[ $value =~ ^[1-9][0-9]*$ ]] || die_usage "$ACTION --json must be a positive integer"
            next=$(jq -ec --arg name "$KEY_PATH" --argjson v "$value" --arg action "$ACTION" '
                def valid_ids($name):
                    has($name) and (.[$name] | type) == "array" and
                    all(.[$name][]; type == "number" and . > 0 and floor == .) and
                    ((.[$name] | length) == (.[$name] | unique | length));
                if valid_ids("opened_prs") and valid_ids("queued") and
                   valid_ids("receipt_prs") and valid_ids("skipped_prs")
                then if $action == "dequeue-summary" then .queued -= [$v]
                     elif (.[$name] | index($v)) == null then .[$name] += [$v] else . end
                    | if ((.receipt_prs - .opened_prs) | length) > 0 or ((.skipped_prs - .opened_prs) | length) > 0 or
                         ((.receipt_prs + .skipped_prs | length) != (.receipt_prs + .skipped_prs | unique | length))
                      then error("inconsistent summary collections") else . end
                else error("missing or invalid summary collection") end
            ' <<<"$STATE" 2>/dev/null) || die 'could not update summary identity; initialize and repair summary collections first'
            write_state "$next"
            ;;
        summary)
            print_summary
            ;;
    esac
}

main "$@"
