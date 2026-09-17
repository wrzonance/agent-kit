#!/usr/bin/env bash
# Select the issue-body trust boundary once, before fetching or rendering data.
# Invalid or unknown visibility is deliberately public-fenced (fail closed).
set -uo pipefail

readonly PROGRAM=${0##*/}
visibility=${REPOSITORY_VISIBILITY:-${repository_visibility:-unknown}}
yolo_invocation=${YOLO_INVOCATION:-${yolo_invocation:-false}}

usage() {
    cat <<'EOF'
Usage: select-boundary-mode.sh [--visibility true|false|unknown] [--yolo|--no-yolo]

Prints exactly one selection line: boundary mode: public-fenced,
private-trusted, or yolo-trusted. Unknown visibility is public-fenced.

Recipe: select once before fetching
  repository=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || repository=''
  repository_visibility=$(gh repo view "$repository" --json isPrivate -q '.isPrivate' 2>/dev/null) || repository_visibility=unknown
  : "${yolo_invocation:?set from the invocation line}"
  boundary_args=(--visibility "$repository_visibility")
  if [[ $yolo_invocation == true ]]; then boundary_args+=(--yolo); else boundary_args+=(--no-yolo); fi
  boundary_output=$("$agentkit/parallel-issues/scripts/select-boundary-mode.sh" "${boundary_args[@]}") || exit 1
  boundary_mode=${boundary_output#boundary mode: }
  [[ $boundary_mode =~ ^(public-fenced|private-trusted|yolo-trusted)$ ]] || exit 1
  printf 'boundary mode: %s\n' "$boundary_mode"
EOF
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --)
            shift
            (($# <= 1)) || die "unexpected argument after --: $2"
            if (($# == 1)); then
                [[ $1 != -* ]] || { usage >&2; die "unknown option: $1"; }
                [[ $visibility == unknown ]] || { usage >&2; die "unexpected argument after --: $1"; }
                visibility=$1
                shift
            fi
            break
            ;;
        --visibility|--repository-visibility)
            (($# >= 2)) || die "$1 requires a value"
            visibility=$2
            shift 2
            ;;
        --yolo) yolo_invocation=true; shift ;;
        --yolo-invocation)
            if (($# >= 2)) && [[ $2 != -* ]]; then yolo_invocation=$2; shift 2
            else yolo_invocation=true; shift
            fi
            ;;
        --no-yolo) yolo_invocation=false; shift ;;
        -h|--help) usage; exit 0 ;;
        *)
            [[ $1 != -* ]] || { usage >&2; die "unknown option: $1"; }
            [[ $visibility == unknown ]] || { usage >&2; die "unknown option: $1"; }
            visibility=$1
            shift
            ;;
    esac
done

case ${yolo_invocation,,} in
    true|yes|1|yolo) yolo=true ;;
    *) yolo=false ;;
esac

if [[ $yolo == true ]]; then
    mode='yolo-trusted'
else
    case ${visibility,,} in
        true|private) mode=private-trusted ;;
        false|public|unknown) mode=public-fenced ;;
        *)
            printf '%s\n' "select-boundary-mode: malformed visibility '$visibility'; using public-fenced" >&2
            mode=public-fenced
            ;;
    esac
fi

printf 'boundary mode: %s\n' "$mode"
