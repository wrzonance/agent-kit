#!/usr/bin/env bash
# Resumable, idempotent ledger for bounded bulk mutations.
#
# The caller performs the remote mutation. It records the returned number and
# URL immediately afterwards with `record`; a later invocation consumes only
# `pending` IDs. The ledger is deliberately data, not an orchestrator.
set -euo pipefail
umask 077

PROGRAM=${0##*/}
readonly SCHEMA_VERSION=1

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    usage >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  apply-ledger.sh init --ledger FILE --plan FILE
  apply-ledger.sh pending --ledger FILE [--ids|--json]
  apply-ledger.sh record --ledger FILE --id ID --number N --url URL
  apply-ledger.sh status --ledger FILE

The plan is JSON: {"planId":"...","entries":[{"id":"...", ...}]}.
`record` is the post-mutation write: it is safe to repeat, but conflicting
number/URL results for an already-applied ID are rejected.
EOF
}

[[ $# -gt 0 ]] || { usage >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'
command -v mktemp >/dev/null 2>&1 || die 'mktemp is not installed'
command -v flock >/dev/null 2>&1 || die 'flock is not installed; ledger mutations cannot be serialized'

subcommand=$1
shift
ledger=
plan=
entry_id=
number=
url=
pending_mode=json

while (($#)); do
    case $1 in
        --ledger)
            (($# >= 2)) || { usage >&2; exit 2; }
            ledger=$2
            shift 2
            ;;
        --plan)
            (($# >= 2)) || { usage >&2; exit 2; }
            plan=$2
            shift 2
            ;;
        --id)
            (($# >= 2)) || { usage >&2; exit 2; }
            entry_id=$2
            shift 2
            ;;
        --number)
            (($# >= 2)) || { usage >&2; exit 2; }
            number=$2
            shift 2
            ;;
        --url)
            (($# >= 2)) || { usage >&2; exit 2; }
            url=$2
            shift 2
            ;;
        --ids)
            pending_mode=ids
            shift
            ;;
        --json)
            pending_mode=json
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n $ledger ]] || die_usage '--ledger is required'
[[ ! -L $ledger ]] || die "refusing a ledger symlink: $ledger"

ledger_dir=${ledger%/*}
[[ $ledger_dir != "$ledger" ]] || ledger_dir=.
mkdir -p -- "$ledger_dir"
ledger_lock_fd=

acquire_ledger_lock() {
    local lock_file="$ledger.lock"
    [[ ! -L $lock_file ]] || die "refusing a ledger lock symlink: $lock_file"
    exec {ledger_lock_fd}>"$lock_file" || die "could not open ledger lock: $lock_file"
    chmod 600 -- "$lock_file" || {
        exec {ledger_lock_fd}>&-
        die "could not secure ledger lock: $lock_file"
    }
    flock "$ledger_lock_fd" || {
        exec {ledger_lock_fd}>&-
        die "could not acquire ledger lock: $lock_file"
    }
}

release_ledger_lock() {
    [[ -n $ledger_lock_fd ]] || return 0
    flock -u "$ledger_lock_fd" || true
    exec {ledger_lock_fd}>&-
    ledger_lock_fd=
}

validate_ledger() {
    [[ -f $ledger && ! -L $ledger ]] || die "ledger is not a regular file: $ledger"
    jq -e --argjson version "$SCHEMA_VERSION" '
      .schemaVersion == $version
      and (.planId | type) == "string" and (.planId | length) > 0
      and (.plan | type) == "array"
      and (.applied | type) == "array"
      and (.remaining | type) == "array"
      and (.idMap | type) == "object"
      and ([.plan[]?.id] | length == (unique | length))
    ' "$ledger" >/dev/null 2>&1 || die "invalid apply ledger: $ledger"
}

atomic_write() {
    local content=$1 staged
    staged=$(mktemp "$ledger_dir/.apply-ledger.XXXXXX") || die 'could not create atomic ledger temp file'
    if ! printf '%s\n' "$content" >"$staged"; then
        rm -f -- "$staged"
        die 'could not write atomic ledger temp file'
    fi
    chmod 600 -- "$staged" || {
        rm -f -- "$staged"
        die 'could not secure atomic ledger temp file'
    }
    mv -- "$staged" "$ledger" || {
        rm -f -- "$staged"
        die "could not publish ledger: $ledger"
    }
}

init_ledger() {
    [[ -n $plan ]] || die_usage '--plan is required for init'
    [[ -f $plan && ! -L $plan ]] || die "plan is not a regular file: $plan"
    jq -e '
      ((.planId // "") | type) == "string" and ((.planId // "") | length) > 0
      and (.entries | type) == "array" and (.entries | length) > 0
      and all(.entries[]; (.id | type) == "string" and (.id | length) > 0)
      and ([.entries[].id] | length == (unique | length))
      and all(.entries[]; .id | test("^[A-Za-z0-9._:-]+$"))
    ' "$plan" >/dev/null 2>&1 || die 'plan must have a non-empty unique planId and entries[].id values; valid example: {"planId":"batch-v1","entries":[{"id":"entry-1"}]}'
    acquire_ledger_lock
    if [[ -e $ledger ]]; then
        validate_ledger
        jq -e --slurpfile source "$plan" \
            '(.planId == $source[0].planId) and (.plan == $source[0].entries)' "$ledger" \
            >/dev/null 2>&1 || die 'existing ledger does not match the supplied plan'
        printf 'ledger already initialized: %s\n' "$ledger"
        release_ledger_lock
        return 0
    fi
    local content
    content=$(jq -S -c --argjson version "$SCHEMA_VERSION" '
      {schemaVersion: $version, planId: .planId, plan: .entries,
       applied: [], remaining: [.entries[].id], idMap: {}}
    ' "$plan") || die 'could not create ledger from plan'
    atomic_write "$content"
    printf 'ledger initialized: %s\n' "$ledger"
    release_ledger_lock
}

record_entry() {
    acquire_ledger_lock
    validate_ledger
    [[ $entry_id =~ ^[A-Za-z0-9._:-]+$ ]] || die '--id must contain only letters, numbers, ., _, :, or -'
    [[ $number =~ ^[1-9][0-9]*$ ]] || die '--number must be a positive integer'
    [[ $url =~ ^https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(issues|pull)/[1-9][0-9]*$ ]] ||
        die '--url must be a canonical GitHub issue or pull URL'
    jq -e --arg id "$entry_id" 'any(.plan[]; .id == $id)' "$ledger" >/dev/null 2>&1 ||
        die "planning id is not in the ledger: $entry_id"

    if jq -e --arg id "$entry_id" 'any(.applied[]; .id == $id)' "$ledger" >/dev/null 2>&1; then
        jq -e --arg id "$entry_id" --argjson n "$number" --arg u "$url" \
            'any(.applied[]; .id == $id and .number == $n and .url == $u)' "$ledger" \
            >/dev/null 2>&1 || die "planning id already has a conflicting result: $entry_id"
        printf 'already applied: %s\n' "$entry_id"
        release_ledger_lock
        return 0
    fi

    local content
    content=$(jq -S -c --arg id "$entry_id" --argjson n "$number" --arg u "$url" '
      .applied += [{id: $id, number: $n, url: $u}]
      | .remaining = [.remaining[] | select(. != $id)]
      | .idMap[$id] = {number: $n, url: $u}
    ' "$ledger") || die 'could not update apply ledger'
    atomic_write "$content"
    printf 'recorded: %s -> #%s %s\n' "$entry_id" "$number" "$url"
    release_ledger_lock
}

case $subcommand in
    init) init_ledger ;;
    record)
        [[ -n $entry_id ]] || die_usage '--id is required for record'
        [[ -n $number ]] || die_usage '--number is required for record'
        [[ -n $url ]] || die_usage '--url is required for record'
        record_entry
        ;;
    pending)
        validate_ledger
        if [[ $pending_mode == ids ]]; then
            jq -r '.remaining[]' "$ledger"
        else
            jq -c '{schemaVersion, planId, applied, remaining, idMap}' "$ledger"
        fi
        ;;
    status)
        validate_ledger
        jq -c '{schemaVersion, planId, applied, remaining, idMap}' "$ledger"
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
