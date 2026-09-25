#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)
readonly SCRIPT_DIR
RUN_DIR_SH=${RUN_STATE_RUN_DIR_SH:-$SCRIPT_DIR/../../review-remote-pr/scripts/run-dir.sh}
ACTIVATION_SH=${RUN_STATE_ACTIVATION_SH:-$SCRIPT_DIR/workflow-activation.sh}
readonly PATH_RE='^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$'
# shellcheck disable=SC2016
readonly PATH_EXISTS_DEF='def path_exists($p): . as $d | reduce $p[] as $seg
    ({p: true, c: $d};
        if .p and (.c | type) == "object" and (.c | has($seg)) then {p: true, c: .c[$seg]}
        else {p: false, c: null} end)
    | .p;'
ACTION=''; FILE=''; RUN_ID=''; REPO_ROOT=''; REPORTS_DIR=''; KEY_PATH=''; VALUE=''; JSON_VALUE=''; VALUE_SET=0; LEDGER=''; REBIND=0; AFTER_STEER=0
ACTIVATION_SESSION=''; DECISION_LEDGER=''; WORKER_LEDGER=''

usage() {
    cat <<EOF
Usage: $PROGNAME get|set|append|append-unique|unset (--file FILE | --run-id ID [--repo-root DIR]) --path a.b.c [--value V | --json J]
       $PROGNAME latest --repo-root DIR --path a.b.c
       $PROGNAME bind --repo-root DIR --activation-session ID [--run-id ID [--rebind]]
       $PROGNAME init-summary --run-id ID [--repo-root DIR]
       $PROGNAME record-summary --run-id ID [--repo-root DIR] --path COLLECTION --json POSITIVE_INTEGER
       $PROGNAME dequeue-summary --run-id ID [--repo-root DIR] --json POSITIVE_INTEGER
       $PROGNAME next-action [--after-steer] (--file FILE | --run-id ID [--repo-root DIR]) --json SNAPSHOT
       $PROGNAME summary --run-id ID [--repo-root DIR] [--reports-dir DIR]
get     print the value at --path (scalars raw, objects/arrays compact JSON, null as "null");
        exit 11 when the key is absent -- a key explicitly set to JSON null is present, not absent
set     store --value (string), --json (parsed), or true when neither is given
append  append --value/--json to the array at --path (created when absent; a non-array, including
        an existing null-valued key, refuses)
append-unique  append only when the same JSON value is not already present; preserves first-seen order
unset   remove --path
latest  select the newest trusted run state and print {"run_id":ID,"value":VALUE};
        exit 11 when no run state or requested path exists
bind    with --run-id, initialize/validate one run binding; without it, recover the unique
        binding for this repository and activation session. --rebind explicitly moves the exact
        selected run to an independently authorized current session. Prints compact binding JSON.
summary print handoff coverage from durable run state and active-worker lifecycle evidence
init-summary create only missing summary collections, preserving every existing value
record-summary append one unique producer identity to a required summary collection
dequeue-summary remove one queued issue identity when its dispatch starts (absent is success)
next-action validate/save evidence, actionable_work, operations, operator_dependencies, completed_work, and remaining_work; evidence requires id, observed_at (YYYY-MM-DDThh:mm:ss[.fff]Z), actionable_complete, operations_complete; operations require id, kind (worker|reviewer|test|other), status (active|unknown), and affected IDs; operator_dependencies require question and affected IDs; --after-steer refuses exact replay of the prior evidence observation; print the saved decision with outstanding and resume_required
Example: {"evidence":{"id":"e","observed_at":"2026-09-24T12:00:00Z","actionable_complete":true,"operations_complete":true},"actionable_work":["B"],"operations":[{"id":"o","kind":"reviewer","status":"unknown","affected":["A"]}],"operator_dependencies":[{"question":"q","affected":["A"]}],"completed_work":[],"remaining_work":["A","B"]}
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
        get|set|append|append-unique|unset|latest|bind|init-summary|record-summary|dequeue-summary|next-action|summary) ACTION=$1; shift ;;
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
            --activation-session) require_value "$1" "${2:-}"; ACTIVATION_SESSION=$2; shift 2 ;;
            --rebind) REBIND=1; shift ;;
            --after-steer) AFTER_STEER=1; shift ;;
            --path) require_value "$1" "${2:-}"; KEY_PATH=$2; shift 2 ;;
            --value) require_value "$1" "${2:-}"; VALUE=$2; VALUE_SET=1; shift 2 ;;
            --json) require_value "$1" "${2:-}"; JSON_VALUE=$2; VALUE_SET=1; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -z $VALUE || -z $JSON_VALUE ]] || die_usage '--value and --json are mutually exclusive'
    if [[ $ACTION == bind ]]; then
        [[ -z $FILE ]] || die_usage 'bind accepts --repo-root, not --file'
        [[ -n $REPO_ROOT ]] || die_usage 'bind requires --repo-root'
        [[ -n $ACTIVATION_SESSION ]] || die_usage 'bind requires --activation-session'
        ((${#ACTIVATION_SESSION} <= 256)) && [[ $ACTIVATION_SESSION != *$'\n'* && $ACTIVATION_SESSION != *$'\r'* ]] ||
            die_usage '--activation-session must be one line (maximum 256 characters)'
        [[ -z $KEY_PATH && $VALUE_SET == 0 && -z $REPORTS_DIR ]] ||
            die_usage 'bind takes no --path/--value/--json/--reports-dir'
        ((REBIND == 0)) || [[ -n $RUN_ID ]] || die_usage '--rebind requires an exact --run-id selection'
    elif [[ $ACTION == summary ]]; then
        [[ -z $FILE ]] || die_usage 'summary requires --run-id, not --file'
        [[ -n $RUN_ID ]] || die_usage 'summary requires --run-id'
        [[ -z $KEY_PATH && $VALUE_SET == 0 ]] || die_usage 'summary takes no --path/--value/--json'
    elif [[ $ACTION == latest ]]; then
        [[ -z $FILE && -z $RUN_ID ]] || die_usage 'latest accepts --repo-root, not --file/--run-id'
        [[ -n $REPO_ROOT ]] || die_usage 'latest requires --repo-root'
        [[ -n $KEY_PATH ]] || die_usage '--path is required'
        [[ $KEY_PATH =~ $PATH_RE ]] || die_usage "--path must be dot-separated [A-Za-z0-9_-] segments: $KEY_PATH"
        ((VALUE_SET == 0)) || die_usage 'latest takes no --value/--json'
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
    elif [[ $ACTION == next-action ]]; then
        [[ -z $KEY_PATH && -z $REPORTS_DIR ]] || die_usage 'next-action takes no --path/--reports-dir'
        [[ -n $JSON_VALUE && -z $VALUE ]] || die_usage 'next-action requires --json SNAPSHOT'
        if [[ -n $FILE && -n $RUN_ID ]]; then die_usage '--file and --run-id are mutually exclusive'; fi
        [[ -n $FILE || -n $RUN_ID ]] || die_usage 'either --file or --run-id is required'
    else
        [[ -z $REPORTS_DIR ]] || die_usage "$ACTION takes no --reports-dir"
        [[ -n $KEY_PATH ]] || die_usage '--path is required'
        [[ $KEY_PATH =~ $PATH_RE ]] || die_usage "--path must be dot-separated [A-Za-z0-9_-] segments: $KEY_PATH"
        [[ $ACTION != get && $ACTION != unset || $VALUE_SET == 0 ]] || die_usage "$ACTION takes no --value/--json"
        if [[ -n $FILE && -n $RUN_ID ]]; then die_usage '--file and --run-id are mutually exclusive'; fi
        [[ -n $FILE || -n $RUN_ID ]] || die_usage 'either --file or --run-id is required'
    fi
    [[ $ACTION == bind || -z $ACTIVATION_SESSION ]] || die_usage '--activation-session is valid only with bind'
    [[ $ACTION == bind || $REBIND -eq 0 ]] || die_usage '--rebind is valid only with bind'
    [[ $ACTION == next-action || $AFTER_STEER == 0 ]] || die_usage '--after-steer is valid only with next-action'
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
}

resolve_binding_paths() {
    local selected_root checkout_root primary_root
    [[ -d $REPO_ROOT ]] || die_usage "--repo-root is not a directory: $REPO_ROOT"
    selected_root=$(cd -P -- "$REPO_ROOT" && pwd -P) || die 'could not resolve --repo-root'
    checkout_root=$(git -C "$selected_root" rev-parse --show-toplevel 2>/dev/null) ||
        die '--repo-root must be a Git checkout'
    checkout_root=$(realpath -e -- "$checkout_root") || die 'could not resolve the Git checkout root'
    [[ $selected_root == "$checkout_root" ]] || die_usage '--repo-root must name the Git checkout root'
    primary_root=$(git -C "$checkout_root" worktree list --porcelain |
        awk '/^worktree / && !found { sub(/^worktree /, ""); primary=$0; found=1 } END { if (found) print primary }')
    [[ -n $primary_root ]] || die 'could not resolve the primary checkout for run binding'
    primary_root=$(realpath -e -- "$primary_root") || die 'could not resolve the primary checkout'
    REPO_ROOT=$primary_root
    DECISION_LEDGER=$primary_root/.agent/session-ledger.ndjson
    WORKER_LEDGER=$primary_root/.agent/runs/active-workers.ndjson
}

validate_activation_session() {
    [[ -x $ACTIVATION_SH ]] || die "workflow-activation.sh not found at $ACTIVATION_SH; binding unavailable"
    "$ACTIVATION_SH" check --require pre-tool-use --repo-root "$REPO_ROOT" \
        --session "$ACTIVATION_SESSION" --skill parallel-issues >/dev/null
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

latest_state() {
    local roots='' roots_rc=0 evidence candidate state_file mode mtime run_id seen_run_id
    local selected_mtime='' selected_run_id='' selected_state=''
    local -a seen_run_ids=()
    [[ -x $RUN_DIR_SH ]] || die "run-dir.sh not found at $RUN_DIR_SH; evidence unavailable"
    roots=$("$RUN_DIR_SH" --list-run-roots --repo-root "$REPO_ROOT") || roots_rc=$?
    case $roots_rc in
        0) ;;
        11) exit 11 ;;
        *) die 'could not resolve trusted run-state roots' ;;
    esac

    shopt -s nullglob
    while IFS= read -r evidence; do
        [[ -n $evidence ]] || continue
        for candidate in "$evidence"/run-*; do
            [[ ! -L $candidate ]] || die "candidate run directory must not be a symlink: $candidate"
            [[ -d $candidate && -O $candidate ]] || die "candidate run must be an owned directory: $candidate"
            mode=$(stat -c %a -- "$candidate") || die "candidate run mode was unreadable: $candidate"
            [[ $mode == 700 ]] || die "candidate run must be owner-private (mode 0700): $candidate"
            run_id=${candidate##*/run-}
            for seen_run_id in "${seen_run_ids[@]}"; do
                [[ $seen_run_id != "$run_id" ]] ||
                    die "duplicate run ID across trusted run-state roots: $run_id"
            done
            seen_run_ids+=("$run_id")
            state_file=$candidate/run-state.json
            [[ ! -L $state_file ]] || die "state file must not be a symlink: $state_file"
            [[ -e $state_file ]] || continue
            FILE=$state_file
            read_state
            mtime=$(stat -c %y -- "$state_file") || die "state file mtime was unreadable: $state_file"
            if [[ -z $selected_mtime || $mtime > $selected_mtime ||
                ($mtime == "$selected_mtime" && $run_id > $selected_run_id) ]]; then
                selected_mtime=$mtime
                selected_run_id=$run_id
                selected_state=$STATE
            fi
        done
    done <<<"$roots"
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

expected_binding() {
    jq -nc --arg run_id "$RUN_ID" --arg activation_session "$ACTIVATION_SESSION" \
        --arg repository_root "$REPO_ROOT" --arg decision_ledger "$DECISION_LEDGER" \
        --arg worker_ledger "$WORKER_LEDGER" \
        '{run_id:$run_id,activation_session:$activation_session,repository_root:$repository_root,
          decision_ledger:$decision_ledger,worker_ledger:$worker_ledger}'
}

validate_binding() {
    local run_id=$1 state=$2
    jq -e --arg run_id "$run_id" --arg repository_root "$REPO_ROOT" \
        --arg decision_ledger "$DECISION_LEDGER" --arg worker_ledger "$WORKER_LEDGER" '
        .binding as $b |
        ($b | type) == "object" and
        ($b.run_id == $run_id) and
        ($b.activation_session | type) == "string" and ($b.activation_session | length) > 0 and
        ($b.repository_root == $repository_root) and
        ($b.decision_ledger == $decision_ledger) and
        ($b.worker_ledger == $worker_ledger)
    ' <<<"$state" >/dev/null 2>&1 || die "damaged run binding for run $run_id; operator recovery is required before retrying"
}

resume_binding() {
    local roots='' roots_rc=0 evidence candidate state_file mode run_id seen_run_id
    local matched_state='' matched_run_id=''
    local -a seen_run_ids=() matched_run_ids=()
    [[ -x $RUN_DIR_SH ]] || die "run-dir.sh not found at $RUN_DIR_SH; evidence unavailable"
    roots=$("$RUN_DIR_SH" --list-run-roots --repo-root "$REPO_ROOT") || roots_rc=$?
    case $roots_rc in 0) ;; 11) die 'no run binding matches repository and activation session; select a current run with --run-id' ;; *) die 'could not resolve trusted run-state roots' ;; esac
    shopt -s nullglob
    while IFS= read -r evidence; do
        [[ -n $evidence ]] || continue
        for candidate in "$evidence"/run-*; do
            [[ ! -L $candidate ]] || die "candidate run directory must not be a symlink: $candidate"
            [[ -d $candidate && -O $candidate ]] || die "candidate run must be an owned directory: $candidate"
            mode=$(stat -c %a -- "$candidate") || die "candidate run mode was unreadable: $candidate"
            [[ $mode == 700 ]] || die "candidate run must be owner-private (mode 0700): $candidate"
            run_id=${candidate##*/run-}
            for seen_run_id in "${seen_run_ids[@]}"; do
                [[ $seen_run_id != "$run_id" ]] || die "duplicate run ID across trusted run-state roots: $run_id"
            done
            seen_run_ids+=("$run_id")
            state_file=$candidate/run-state.json
            [[ ! -L $state_file ]] || die "state file must not be a symlink: $state_file"
            [[ -e $state_file ]] || continue
            FILE=$state_file
            read_state
            jq -e 'has("binding")' <<<"$STATE" >/dev/null || continue
            validate_binding "$run_id" "$STATE"
            if [[ $(jq -r '.binding.activation_session' <<<"$STATE") == "$ACTIVATION_SESSION" ]]; then
                matched_run_ids+=("$run_id")
                matched_run_id=$run_id
                matched_state=$STATE
            fi
        done
    done <<<"$roots"
    ((${#matched_run_ids[@]} > 0)) ||
        die 'no run binding matches repository and activation session; select a current run with --run-id'
    ((${#matched_run_ids[@]} == 1)) ||
        die "multiple run bindings match repository and activation session (${matched_run_ids[*]}); select one with --run-id"
    RUN_ID=$matched_run_id
    jq -c '.binding' <<<"$matched_state"
}

initialize_summary_state() {
    jq -ec '
        def valid_ids($name):
            (has($name) | not) or
            ((.[$name] | type) == "array" and all(.[$name][]; type == "number" and . > 0 and floor == .) and
            ((.[$name] | length) == (.[$name] | unique | length)));
        if valid_ids("opened_prs") and valid_ids("queued") and
           valid_ids("receipt_prs") and valid_ids("skipped_prs") and
           ((has("root_turns") | not) or
            ((.root_turns | type) == "array" and all(.root_turns[]; . == true))) and
           ((has("first_completion") | not) or (.first_completion | type) == "boolean")
        then .
            | if has("opened_prs") then . else .opened_prs=[] end
            | if has("queued") then . else .queued=[] end
            | if has("receipt_prs") then . else .receipt_prs=[] end
            | if has("skipped_prs") then . else .skipped_prs=[] end
            | if has("first_completion") then . else .first_completion=false end
            | if ((.receipt_prs - .opened_prs) | length) > 0 or ((.skipped_prs - .opened_prs) | length) > 0 or
                 ((.receipt_prs + .skipped_prs | length) != (.receipt_prs + .skipped_prs | unique | length))
              then error("inconsistent summary collections") else . end
        else error("invalid summary collection") end
    ' <<<"$1" 2>/dev/null
}

initialize_binding() {
    local binding existing next rebind_command
    binding=$(expected_binding) || die 'could not construct run binding'
    if jq -e 'has("binding")' <<<"$STATE" >/dev/null; then
        validate_binding "$RUN_ID" "$STATE"
        existing=$(jq -c '.binding' <<<"$STATE")
        if [[ $existing == "$binding" ]]; then
            next=$STATE
        elif ((REBIND)); then
            next=$(jq -c --argjson binding "$binding" '.binding=$binding' <<<"$STATE") ||
                die 'could not rebind the selected run'
        else
            printf -v rebind_command '%q ' "$0" bind --run-id "$RUN_ID" --repo-root "$REPO_ROOT" \
                --activation-session "$ACTIVATION_SESSION" --rebind
            die "run binding for run $RUN_ID belongs to a different activation session; retry: ${rebind_command% }"
        fi
    else
        next=$(jq -c --argjson binding "$binding" '.binding=$binding' <<<"$STATE") ||
            die 'could not initialize run binding'
    fi
    next=$(initialize_summary_state "$next") || die 'could not initialize invalid summary collections'
    [[ $next == "$STATE" ]] || write_state "$next"
    printf '%s\n' "$binding"
}

validate_next_action_snapshot() {
    jq -ec '
        def strings:
            type == "array" and length <= 10000 and
            all(.[]; type == "string" and length > 0 and length <= 4096) and
            length == (unique | length);
        def exact_keys($wanted): (keys | sort) == ($wanted | sort);
        . as $s |
        ($s | type) == "object" and
        ($s | exact_keys(["actionable_work","completed_work","evidence","operations",
                          "operator_dependencies","remaining_work"])) and
        ($s.evidence | type) == "object" and
        ($s.evidence | exact_keys(["actionable_complete","id","observed_at","operations_complete"])) and
        ($s.evidence.id | type) == "string" and ($s.evidence.id | length) > 0 and
        ($s.evidence.id | length) <= 1024 and
        ($s.evidence.observed_at | type) == "string" and
        ($s.evidence.observed_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")) and
        ($s.evidence.actionable_complete | type) == "boolean" and
        ($s.evidence.operations_complete | type) == "boolean" and
        ($s.actionable_work | strings) and ($s.completed_work | strings) and
        ($s.remaining_work | strings) and
        (($s.completed_work + $s.remaining_work | length) ==
         ($s.completed_work + $s.remaining_work | unique | length)) and
        ($s.operations | type) == "array" and ($s.operations | length) <= 10000 and
        all($s.operations[];
            type == "object" and exact_keys(["affected","id","kind","status"]) and
            (.id | type) == "string" and (.id | length) > 0 and (.id | length) <= 1024 and
            (.kind == "worker" or .kind == "reviewer" or .kind == "test" or .kind == "other") and
            (.status == "active" or .status == "unknown") and
            (.affected | strings) and (.affected | length) > 0) and
        (($s.operations | map(.id) | length) == ($s.operations | map(.id) | unique | length)) and
        ($s.operator_dependencies | type) == "array" and ($s.operator_dependencies | length) <= 10000 and
        all($s.operator_dependencies[];
            type == "object" and exact_keys(["affected","question"]) and
            (.question | type) == "string" and (.question | length) > 0 and (.question | length) <= 4096 and
            (.affected | strings) and (.affected | length) > 0) and
        ($s.remaining_work as $remaining |
            all($s.actionable_work[]; . as $id | $remaining | index($id) != null) and
            all($s.operations[].affected[]; . as $id | $remaining | index($id) != null) and
            all($s.operator_dependencies[].affected[]; . as $id | $remaining | index($id) != null))
        | if . then $s else error("invalid") end
    ' <<<"$1" 2>/dev/null
}

next_action_ownership_overlaps() {
    jq -r '
        ([.operations[].affected[]] | unique) as $owned |
        any(.actionable_work[]; . as $id | $owned | index($id) != null)
    ' <<<"$1"
}

select_next_action() {
    jq -ec '
        . as $snapshot |
        ($snapshot.operations | map(select(.status == "active")) | length) as $active |
        ($snapshot.operations | map(select(.status == "unknown")) | length) as $unknown |
        ([$snapshot.operator_dependencies[].affected[]] | unique) as $operator_affected |
        (if ($snapshot.actionable_work | length) > 0 and $snapshot.evidence.operations_complete then "dispatch"
         elif $unknown > 0 then "reconcile"
         elif $active > 0 then "collect"
         elif (($snapshot.evidence.actionable_complete and $snapshot.evidence.operations_complete) | not)
            then "reconcile"
         elif ($snapshot.remaining_work | length) == 0 then "complete"
         elif ($snapshot.operator_dependencies | length) > 0 and
              (($snapshot.remaining_work - $operator_affected) | length) == 0 then "end-turn"
         else "reconcile" end) as $action |
        {snapshot:$snapshot,
         decision:{next_action:$action,
                   actionable_count:($snapshot.actionable_work | length),
                   active_operations:$active,unknown_operations:$unknown,
                   operator_dependencies:($snapshot.operator_dependencies | length),
                   remaining_count:($snapshot.remaining_work | length),
                   outstanding:($snapshot.remaining_work | length),
                   evidence_id:$snapshot.evidence.id,observed_at:$snapshot.evidence.observed_at,
                   wait_allowed:($action == "collect"),task_complete:($action == "complete"),
                   resume_required:($action != "end-turn" and $action != "complete"),
                   ownership_released:false}}
    ' <<<"$1" 2>/dev/null
}

record_next_action() {
    local snapshot=$1 overlap record next
    snapshot=$(validate_next_action_snapshot "$snapshot") ||
        die 'invalid next-action snapshot; every evidence and work field is required'
    if ((AFTER_STEER)) && jq -e --argjson snapshot "$snapshot" '
        .orchestration.snapshot.evidence? == $snapshot.evidence
    ' <<<"$STATE" >/dev/null; then
        die 'after-steer requires a newly observed snapshot; reconcile current source records'
    fi
    overlap=$(next_action_ownership_overlaps "$snapshot") || die 'could not compare next-action ownership'
    [[ $overlap == false ]] || die 'actionable work overlaps an outstanding operation'
    record=$(select_next_action "$snapshot") || die 'could not select next action'
    next=$(jq -c --argjson record "$record" '.orchestration=$record' <<<"$STATE") ||
        die 'could not record next action'
    write_state "$next"
    jq -c '.decision' <<<"$record"
}

print_summary() {
    local counts ledger_mode parked_rows parked_count
    counts=$(jq -er '
        def positive_ids($name; $required):
            (if has($name) then .[$name] elif $required then error($name + " is required") else [] end) as $value |
            if ($value | type) == "array" and all($value[]; type == "number" and . > 0 and floor == .)
                and (($value | length) == ($value | unique | length))
            then $value else error($name + " must be a unique positive-integer array") end;
        positive_ids("opened_prs"; true) as $prs |
        positive_ids("queued"; true) as $queued |
        positive_ids("receipt_prs"; true) as $receipts |
        positive_ids("skipped_prs"; true) as $skipped |
        has("auto_review") as $has_auto_review |
        .auto_review as $auto_review |
        has("root_turns") as $has_root_turns |
        has("first_completion") as $has_first_completion |
        .root_turns as $root_turns |
        .first_completion as $first_completion |
        if (($receipts - $prs) | length) > 0 then error("receipt_prs must be a subset of opened_prs")
        elif (($skipped - $prs) | length) > 0 then error("skipped_prs must be a subset of opened_prs")
        elif (($receipts + $skipped | length) != ($receipts + $skipped | unique | length))
            then error("receipt_prs and skipped_prs must be disjoint")
        elif $has_auto_review and ($auto_review | type) != "boolean"
            then error("auto_review must be a boolean")
        elif $has_root_turns and (($has_first_completion | not) or ($root_turns | type) != "array"
            or any($root_turns[]; . != true) or ($first_completion | type) != "boolean")
            then error("invalid root-turn summary evidence")
        elif $has_first_completion and (($first_completion | type) != "boolean")
            then error("invalid first-completion evidence")
        else (if $has_root_turns | not then "unavailable"
              elif $first_completion then ($root_turns | length | tostring) else "unlatched" end) as $telemetry |
            ($prs - ($receipts + $skipped)) as $missing |
            [($prs | length), ($receipts | length), ($skipped | length), ($queued | length),
             (if $has_auto_review then ($auto_review | tostring) else "false" end),
             ($missing | if length == 0 then "-" else map(tostring) | join(",") end), $telemetry] | @tsv end
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
        if all($run_rows[]; .version == 2 and (.issue | type == "number" and . > 0 and floor == .) and
            (.attempt | type == "string" and length > 0) and
            (.state == "unknown" or .state == "active" or .state == "terminal") and
            (.disposition | type == "string") and (.evidence | type == "string")) | not
        then error("malformed current-run lifecycle row") else . end |
        reduce $run_rows[] as $row ({}; .[$row.issue | tostring] = $row) |
        [.[] | select(.state == "terminal" and .disposition == "handed-back") |
            if (.evidence | length > 0 and (explode | all(. >= 32 and . != 127)))
            then . else error("invalid handback evidence") end] | sort_by(.issue)
    ' "$LEDGER" 2>/dev/null) || die "unparseable active-workers evidence: $LEDGER"
    parked_count=$(jq 'length' <<<"$parked_rows")
    local prs receipts skipped queued auto_review missing_review_prs root_turns review_resume coverage_failure=''
    IFS=$'\t' read -r prs receipts skipped queued auto_review missing_review_prs root_turns <<<"$counts"
    if [[ $auto_review == true && $missing_review_prs != - ]]; then
        review_resume="/review-remote-pr --auto-review ${missing_review_prs//,/; /review-remote-pr --auto-review }"
        coverage_failure="auto-review coverage missing for PRs: $missing_review_prs; resume: $review_resume"
    fi
    printf 'coverage= prs=%s receipts=%s skipped=%s parked=%s queued=%s root-turns-before-first-completion=%s\n' \
        "$prs" "$receipts" "$skipped" "$parked_count" "$queued" "$root_turns"
    jq -r '.[] | "blocked=\(.issue):\(.evidence)"' <<<"$parked_rows"

    if [[ -z $REPORTS_DIR ]]; then
        [[ -z $coverage_failure ]] || die "$coverage_failure"
        return 0
    fi
    [[ ! -L $REPORTS_DIR ]] || die "verification reports directory must not be a symlink: $REPORTS_DIR"
    [[ ! -e $REPORTS_DIR || (-d $REPORTS_DIR && -O $REPORTS_DIR) ]] ||
        die "verification reports must be an owned directory: $REPORTS_DIR"
    if [[ ! -e $REPORTS_DIR ]]; then
        [[ -z $coverage_failure ]] || die "$coverage_failure"
        return 0
    fi
    local reports_mode report report_mode report_text report_issue content_issue
    reports_mode=$(stat -c %a -- "$REPORTS_DIR") || die "could not inspect verification reports: $REPORTS_DIR"
    (( (8#$reports_mode & 8#077) == 0 )) || die "verification reports directory must be owner-private: $REPORTS_DIR"
    local -a reports=("$REPORTS_DIR"/issue-*.report)
    if [[ ! -e ${reports[0]} ]]; then
        [[ -z $coverage_failure ]] || die "$coverage_failure"
        return 0
    fi
    for report in "${reports[@]}"; do
        [[ ${report##*/} =~ ^issue-([1-9][0-9]*)\.report$ ]] ||
            die "verification report filename must be issue-POSITIVE_INTEGER.report: $report"
        report_issue=${BASH_REMATCH[1]}
        [[ ! -L $report && -f $report && -O $report ]] || die "verification report must be an owned regular file: $report"
        report_mode=$(stat -c %a -- "$report") || die "could not inspect verification report: $report"
        (( (8#$report_mode & 8#077) == 0 )) || die "verification report must be owner-private: $report"
        report_text=$(cat -- "$report") || die "could not read verification report: $report"
        [[ $(wc -l <"$report") -eq 1 && $report_text != *$'\n'* ]] ||
            die "malformed durable verification report: $report"
        [[ $report_text =~ ^spec-verification=\ issue=([1-9][0-9]*)\ steps=[1-9][0-9]*\  ]] ||
            die "malformed durable verification report: $report"
        content_issue=${BASH_REMATCH[1]}
        [[ $content_issue == "$report_issue" ]] ||
            die "verification report filename issue does not match content issue: $report"
        cat -- "$report"
    done
    [[ -z $coverage_failure ]] || die "$coverage_failure"
}

main() {
    parse_args "$@"
    if [[ $ACTION == bind ]]; then
        resolve_binding_paths
        validate_activation_session
        if [[ -z $RUN_ID ]]; then
            resume_binding
            return
        fi
    fi
    resolve_summary_ledger
    if [[ $ACTION == latest ]]; then
        latest_state
        return
    fi
    resolve_file
    local parent lock lock_fd
    [[ ! -L $FILE ]] || die "state file must not be a symlink: $FILE"
    if [[ $ACTION == bind || $ACTION == set || $ACTION == append || $ACTION == append-unique || $ACTION == unset ||
        $ACTION == next-action ||
        $ACTION == init-summary || $ACTION == record-summary || $ACTION == dequeue-summary ]]; then
        parent=$(cd -P -- "$(dirname -- "$FILE")" && pwd -P) || die 'state directory unavailable'
        FILE=$parent/$(basename -- "$FILE")
        lock=$FILE.lock
        [[ ! -L $lock && (! -e $lock || (-f $lock && -O $lock)) ]] || die 'unsafe state lock'
        exec {lock_fd}>>"$lock"
        flock -w 10 "$lock_fd" || die 'state lock unavailable after 10 seconds'
    fi
    read_state
    local path='' next present value=''
    [[ $ACTION == bind || $ACTION == summary || $ACTION == init-summary || $ACTION == next-action ]] || path=$(jq_path)
    if [[ $ACTION == set || $ACTION == append || $ACTION == append-unique ||
        $ACTION == record-summary || $ACTION == dequeue-summary || $ACTION == next-action ]]; then
        value=$(value_json) || exit $?
    fi
    case $ACTION in
        bind)
            initialize_binding
            ;;
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
        init-summary)
            next=$(initialize_summary_state "$STATE") || die 'could not initialize invalid summary collections'
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
        next-action)
            record_next_action "$value"
            ;;
        summary)
            print_summary
            ;;
    esac
}

main "$@"
