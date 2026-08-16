#!/usr/bin/env bash
# Pull the Backlog worklist for a human vetting pass.  Promotion is
# intentionally outside this helper: Backlog -> Ready is an authority move.
set -uo pipefail

readonly PROGRAM=${0##*/}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
board_helper="$script_dir/../../.shared/scripts/board-list.sh"
repo_root=''
json_only=no

usage() {
    cat <<'EOF'
Usage: groom-backlog.sh [--repo-root DIR] [--board-helper FILE] [--json]

Reads the Project Backlog once and prints Issue-typed candidates. It never
promotes an issue or calls the project mover.
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

while (($#)); do
    case $1 in
        --repo-root)
            (($# >= 2)) || die '--repo-root requires a value'
            repo_root=$2
            shift 2
            ;;
        --board-helper)
            (($# >= 2)) || die '--board-helper requires a value'
            board_helper=$2
            shift 2
            ;;
        --json) json_only=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
done

[[ -x $board_helper ]] || die "board-list helper is missing or not executable: $board_helper"
command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'

args=(--status Backlog --json)
[[ -n $repo_root ]] && args+=(--repo-root "$repo_root")
backlog_json=''
backlog_rc=0
backlog_json=$("$board_helper" "${args[@]}" 2> >(sed "s/^/$PROGRAM: /" >&2)) || backlog_rc=$?
case $backlog_rc in
    0) ;;
    3)
        printf '%s\n' 'board query unsupported here (no gh, or no board declared); skipping Backlog grooming' >&2
        exit 0
        ;;
    *)
        printf '%s: board-list helper failed (exit %s); Backlog grooming not attempted\n' \
            "$PROGRAM" "$backlog_rc" >&2
        exit 1
        ;;
esac

if ! jq -e 'type == "array"' <<<"$backlog_json" >/dev/null 2>&1; then
    die 'board-list returned malformed JSON; Backlog grooming is blocked'
fi

if [[ $json_only == yes ]]; then
    jq -c '[.[] | select(.type == "Issue")]' <<<"$backlog_json"
    exit 0
fi

printf '%s\n' 'Backlog → Ready candidates (human vetting required):'
issue_count=0
while IFS=$'\t' read -r number title; do
    [[ -n $number ]] || continue
    issue_count=$((issue_count + 1))
    printf '  #%s  %s\n' "$number" "$title"
done < <(jq -r '.[] | select(.type == "Issue") | [(.number // ""), (.title // "(untitled)")] | @tsv' <<<"$backlog_json")
((issue_count > 0)) || printf '  (no Issue-typed items)\n'
printf '%s\n' 'No issues were promoted; review candidates against the Ready bar before using the board mover.'
