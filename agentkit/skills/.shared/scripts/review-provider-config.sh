#!/usr/bin/env bash
# Resolve the declared provider capability plan without reading config.env.
#
# repo-config.sh remains the sole line-oriented config reader. This helper only
# interprets its NUL-delimited resolve records and maps provider identities to
# their orchestration capabilities.
set -euo pipefail

readonly PROGRAM=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
readonly SCRIPT_DIR
readonly RESOLVER=$SCRIPT_DIR/repo-config.sh
# Overridable only for tests; the real path is fixed relative to this script.
CODE_QUALITY_STATE=${REVIEW_PROVIDER_CONFIG_CODE_QUALITY_STATE:-$SCRIPT_DIR/../../review-remote-pr/scripts/code-quality-state.sh}
readonly CODE_QUALITY_STATE
# shellcheck source=lib/review-provider-catalog.sh
source "$SCRIPT_DIR/lib/review-provider-catalog.sh"

usage() {
    printf 'usage: %s [--repo-root DIR] [--probe]\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

repo_root=''
probe=no
while (($#)); do
    case $1 in
        --repo-root)
            (($# >= 2)) || usage
            repo_root=$2
            shift 2
            ;;
        --probe) probe=yes; shift ;;
        -h | --help) usage 0 ;;
        *) usage ;;
    esac
done

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null || true)
fi

emit_none() {
    printf 'provider=none mode=disabled source=%s\n' "$1"
}

warn() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
}

if [[ -z $repo_root ]]; then
    warn 'repository root is unavailable; using effective none'
    emit_none missing
    exit 0
fi
if [[ ! -d $repo_root ]]; then
    warn "repository root is not a directory; using effective none"
    emit_none invalid
    exit 0
fi

records_file=$(mktemp "${TMPDIR:-/tmp}/review-provider-config.XXXXXX")
warnings_file=$(mktemp "${TMPDIR:-/tmp}/review-provider-config-warnings.XXXXXX")
trap 'rm -f -- "$records_file" "$warnings_file"' EXIT

resolver_rc=0
"$RESOLVER" --repo-root "$repo_root" --resolve AGENT_REVIEW_PROVIDERS \
    >"$records_file" 2>"$warnings_file" || resolver_rc=$?
cat -- "$warnings_file" >&2

if ((resolver_rc != 0)); then
    warn 'provider resolution failed; using effective none'
    emit_none invalid
    exit 0
fi

declare -a records=()
mapfile -d '' -t records < "$records_file"
declared=''
parse_status=0
for ((i = 0; i < ${#records[@]}; )); do
    case ${records[i]} in
        AGENT_REVIEW_PROVIDERS)
            declared=${records[i + 1]-}
            i=$((i + 4))
            ;;
        __AGENT_CONFIG_PARSE_STATUS__)
            parse_status=${records[i + 1]:-1}
            i=$((i + 2))
            ;;
        *)
            i=$((i + 1))
            ;;
    esac
done

if [[ -z $declared ]]; then
    if ((parse_status != 0)); then
        emit_none invalid
    else
        warn 'AGENT_REVIEW_PROVIDERS is not declared; using effective none'
        emit_none missing
    fi
    exit 0
fi

# Probes GitHub Code Quality reachability ONCE for the declared
# github-code-quality provider (issue #403). Prints one of: enabled,
# not-enabled, unknown. A repository slug that cannot be resolved, or a
# probe that cannot reach a decided answer, is always "unknown" -- callers
# must never treat "unknown" as proof the feature is disabled; only a
# confirmed 403 "not enabled" response is.
probe_code_quality() {
    local repo_slug='' probe_out=''
    repo_slug=$("$RESOLVER" --repo-root "$repo_root" --get AGENT_REPO_SLUG 2>/dev/null) || {
        warn 'AGENT_REPO_SLUG is not declared; code-quality reachability is unknown'
        printf 'unknown\n'
        return 0
    }
    [[ -n $repo_slug ]] || {
        printf 'unknown\n'
        return 0
    }
    [[ -x $CODE_QUALITY_STATE ]] || {
        warn "code-quality probe helper is not executable: $CODE_QUALITY_STATE"
        printf 'unknown\n'
        return 0
    }
    probe_out=$("$CODE_QUALITY_STATE" --repo "$repo_slug" --probe 2>/dev/null) || true
    case $probe_out in
        state=enabled) printf 'enabled\n' ;;
        state=not-enabled) printf 'not-enabled\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

IFS=, read -r -a providers <<< "$declared"
for provider in "${providers[@]}"; do
    if [[ $provider == none && ${#providers[@]} -ne 1 ]]; then
        warn 'provider capability plan is invalid; using effective none'
        emit_none invalid
        exit 0
    fi
    mode=$(review_provider_mode "$provider" 2>/dev/null) || {
        warn "unknown provider '$provider'; using effective none"
        emit_none invalid
        exit 0
    }
    if [[ $probe == yes && $provider == github-code-quality ]]; then
        case $(probe_code_quality) in
            not-enabled)
                printf 'provider=%s mode=none source=declared reason=not-enabled\n' "$provider"
                continue
                ;;
            unknown)
                warn 'code-quality reachability could not be determined; treating capability as declared'
                ;;
        esac
    fi
    printf 'provider=%s mode=%s source=declared\n' "$provider" "$mode"
done
