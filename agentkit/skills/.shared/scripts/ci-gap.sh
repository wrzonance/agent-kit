#!/usr/bin/env bash
#
# ci-gap.sh -- what does green locally NOT tell you?
#
# A local gate cannot equal CI and should not try. CI has services, matrices,
# other operating systems, and checks that are meaningless on a workstation --
# a gate that matched it would be too slow to run at the end of every turn,
# which is when the declared verify command runs.
#
# So the gap is structural, and the defect is not its existence but that nobody
# knows its size. Observed: a repository whose declared verify passed while CI
# failed a source-size limit no declared command covered. Nothing said so until
# the push.
#
# This names the delta. It does not close it, and closing it is usually wrong.
#
# Reports, never fails: exit 0 with the delta, 3 when there is no CI definition
# or no contract to compare against.
set -uo pipefail

PROGRAM=${0##*/}
ARG_REPO_ROOT=""

usage() {
    cat << 'EOF'
ci-gap.sh -- list the CI gates no declared command covers.

Usage:
  ci-gap.sh [--repo-root DIR]

Compares the step names in the repository's CI workflows against the commands
declared as AGENT_CMD_* in .agent/config.env, and reports which gates nothing
local runs. The comparison is by name and is deliberately approximate: it is a
prompt to think, not an oracle.

Exit 0 with the report, 3 when there is no workflow or no contract.
EOF
}

while (($#)); do
    case $1 in
        --repo-root)
            ARG_REPO_ROOT=${2:-}
            shift 2 || shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            printf '%s: unknown argument: %s\n' "$PROGRAM" "$1" >&2
            exit 2
            ;;
    esac
done

repo_root=${ARG_REPO_ROOT:-$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")}
self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

# Only workflows that GATE A PULL REQUEST. A release job, a scheduled scan and a
# manual dispatch are not things a local command should mirror, and counting
# them made twenty of twenty-seven gates look uncovered -- a number nobody acts
# on, which is the same as reporting nothing.
mapfile -t workflows < <(
    find "$repo_root/.github/workflows" -maxdepth 1 \
        \( -name '*.yml' -o -name '*.yaml' \) 2> /dev/null | sort |
        while IFS= read -r wf; do
            # The trigger block ends at the first top-level key after `on:`.
            sed -n '/^on:/,/^[a-zA-Z]/p' "$wf" 2> /dev/null |
                grep -q 'pull_request' && printf '%s\n' "$wf"
        done
)
((${#workflows[@]})) || {
    printf '%s: no CI workflows under .github/workflows\n' "$PROGRAM" >&2
    exit 3
}

declared=$("$self_dir/repo-config.sh" --repo-root "$repo_root" --list 2> /dev/null |
    grep -E '^AGENT_CMD_' || true)
[[ -n $declared ]] || {
    printf '%s: this repository declares no commands; every CI gate is uncovered\n' "$PROGRAM" >&2
    exit 3
}

# One haystack of everything the repository says it can run locally: the command
# values, and the names they are declared under.
haystack=$(tr '[:upper:]' '[:lower:]' <<< "$declared" | tr -c 'a-z0-9' ' ')

# A workflow step can be covered by the exact command it runs even when its
# human-readable name has no distinctive word in the local declaration.
# Normalize only presentation differences; this is still a textual comparison
# and deliberately does not attempt to interpret shell syntax.
normalize_command() {
    local value=$1
    value=${value//$'\r'/}
    value=$(sed -E 's/[[:space:]]+#.*$//' <<< "$value")
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    value=${value//$'\t'/ }
    while [[ $value == *'  '* ]]; do value=${value//'  '/ }; done
    if [[ ${#value} -ge 2 ]]; then
        if [[ ${value:0:1} == \" && ${value: -1} == \" ]] ||
            [[ ${value:0:1} == \' && ${value: -1} == \' ]]; then
            value=${value:1:${#value}-2}
        fi
    fi
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    printf '%s' "${value,,}"
}

declare -a declared_commands=()
while IFS= read -r declaration; do
    case $declaration in
        AGENT_CMD_*=*) declared_commands+=("$(normalize_command "${declaration#*=}")") ;;
    esac
done <<< "$declared"

# Keep the named step alongside its single-line run command. The existing
# ci_runs extraction below intentionally remains broader for the divergence
# report, while this association prevents one exact command from covering a
# different named step.
mapfile -t step_runs < <(
    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        FNR == 1 { current = "" }
        /^[[:space:]]*-[[:space:]]/ { current = "" }
        /^[[:space:]]+- name:[[:space:]]*.+$/ {
            line=$0; sub(/^[[:space:]]+- name:[[:space:]]*/, "", line)
            current=trim(line); next
        }
        /^[[:space:]]*run:[[:space:]]*[^|>[:space:]].*$/ {
            if (current == "") next
            line=$0; sub(/^[[:space:]]*run:[[:space:]]*/, "", line)
            print current "\t" trim(line)
        }
    ' "${workflows[@]}" 2> /dev/null
)

# Step names carry the intent ("Type check (tsc --noEmit)"), which is what a
# reader needs. Setup steps are excluded: installing a toolchain is not a gate,
# and listing it as uncovered would bury the ones that are.
mapfile -t steps < <(
    grep -hoE '^[[:space:]]+- name:[[:space:]]+.+$' "${workflows[@]}" 2> /dev/null |
        sed -E 's/^[[:space:]]+- name:[[:space:]]+//; s/["'"'"']//g' |
        grep -viE '^(setup|install|checkout|check out|cache|configure|login|upload|download|set up|restore)\b' |
        sort -u
)
((${#steps[@]})) || {
    printf '%s: no named steps found in the workflows\n' "$PROGRAM" >&2
    exit 3
}

covered=() uncovered=()
for step in "${steps[@]}"; do
    # A step counts as covered when a distinctive word from its name appears in
    # what the repository declared. Approximate on purpose -- the alternative is
    # executing CI to find out, and a false "covered" is corrected by reading
    # one line, while a missing gate is corrected by a failed push.
    hit=no
    for step_run in "${step_runs[@]}"; do
        step_run_name=${step_run%%$'\t'*}
        [[ $step_run_name == "$step" ||
            $step_run_name == "\"$step\"" || $step_run_name == "'$step'" ]] || continue
        step_run_command=${step_run#*$'\t'}
        normalized_run=$(normalize_command "$step_run_command")
        for declared_command in "${declared_commands[@]}"; do
            [[ -n $declared_command && $normalized_run == "$declared_command" ]] || continue
            hit=yes
            break 2
        done
    done
    if [[ $hit == no ]]; then
        for word in $(tr '[:upper:]' '[:lower:]' <<< "$step" | tr -c 'a-z0-9' ' '); do
            ((${#word} >= 4)) || continue
            case " $haystack " in *" $word "*)
                hit=yes
                break
                ;;
            esac
        done
    fi
    if [[ $hit == yes ]]; then covered+=("$step"); else uncovered+=("$step"); fi
done

printf 'ci-gap= workflows=%d gates=%d covered=%d uncovered=%d\n\n' \
    "${#workflows[@]}" "${#steps[@]}" "${#covered[@]}" "${#uncovered[@]}"

if ((${#uncovered[@]})); then
    printf 'NOT covered by any declared command -- green locally says nothing about these:\n'
    printf '  %s\n' "${uncovered[@]}"
    printf '\n'
fi
if ((${#covered[@]})); then
    printf 'Plausibly covered (matched by name, not verified):\n'
    printf '  %s\n' "${covered[@]}"
    printf '\n'
fi

cat << 'EOF'
Matching is by name and is approximate. Treat it as a prompt to think, not a
verdict: closing this gap is usually the wrong move, because a local gate that
equalled CI would be too slow to run at the end of every turn. Knowing which
gates only CI enforces is the point.
EOF

# Name command-level divergence separately from approximate gate matching. A
# workflow may require a verifier mode while the local declaration calls a raw
# component tool; prefer CI as the canonical TEST proposal.
mapfile -t ci_runs < <(
    awk '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function indent(s, t) { t=s; sub(/[^[:space:]].*$/, "", t); return length(t) }
        /^[[:space:]]*run:[[:space:]]*[^|>[:space:]].*$/ {
            line=$0; sub(/^[[:space:]]*run:[[:space:]]*/, "", line); print trim(line); capture=0; next
        }
        /^[[:space:]]*run:[[:space:]]*[|>][-+]?[[:space:]]*$/ { run_indent=indent($0); capture=1; next }
        capture {
            line_indent=indent($0)
            if ($0 !~ /^[[:space:]]*$/ && line_indent <= run_indent) { capture=0 }
            else if ($0 !~ /^[[:space:]]*$/ && line_indent > run_indent) { print trim($0); next }
        }
        capture { capture=0 }
    ' "${workflows[@]}" 2> /dev/null |
        sed -E 's/^["'"'']//; s/["'"'']$//' |
        sed 's/[[:space:]]+#.*$//' | sed '/^[[:space:]]*$/d'
)
test_decl=$(printf '%s\n' "$declared" | sed -n 's/^AGENT_CMD_TEST=//p' | head -n 1)
for ci_run in "${ci_runs[@]}"; do
    case "$(tr '[:upper:]' '[:lower:]' <<< "$ci_run")" in
        *test*|*verify*)
            printf 'CI verifier: %s\n' "$ci_run"
            printf 'CI entry point/defaults: inspect %s --help before proposing flags.\n' "${ci_run%% *}"
            if [[ -n $test_decl && $test_decl != "$ci_run" ]]; then
                printf 'Declared TEST proposal: %s\n' "$test_decl"
                printf 'CI divergence: prefer CI as canonical TEST; raw component proposal differs from the CI verifier above.\n'
            fi
            ;;
    esac
done
