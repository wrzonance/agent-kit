#!/usr/bin/env bash
# Report the next resumable onboarding stage and environment setup facts.
set -uo pipefail
PROGRAM=${0##*/}
usage() { printf 'usage: %s --repo-root DIR (--report | --next | --preflight | --next-steps)\n' "$PROGRAM" >&2; exit 2; }
die() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
repo_root=''; mode=''
while (($#)); do
    case $1 in
        --) shift; break ;;
        --repo-root) (($# >= 2)) || usage; repo_root=$2; shift 2 ;;
        --report) mode=report; shift ;;
        --next) mode=next; shift ;;
        --preflight) mode=preflight; shift ;;
        --next-steps) mode='next-steps'; shift ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done
[[ -n $repo_root && -d $repo_root && -n $mode ]] || usage
repo_root=$(cd -- "$repo_root" && pwd -P) || die "cannot resolve repository root: $repo_root"

state='not onboarded'; next='discover'
config=$repo_root/.agent/config.env; board=$repo_root/.agent/board.json
marker=$repo_root/.agent/cache/onboarding-stage
if [[ ! -r $config ]]; then
    if [[ $(head -n 1 "$marker" 2> /dev/null || true) == discovered ]]; then
        state=discovered; next=declare
    fi
elif [[ ! -r $board ]]; then
    state=discovered; next=declare
else
    command_declared=no
    grep -qE '^AGENT_CMD_[A-Z][A-Z0-9_]*=' "$config" 2> /dev/null && command_declared=yes
    if [[ $command_declared == no || ( ! -r $repo_root/.agent/cache/stamp-verify && ! -r $repo_root/.agent/cache/stamp-test ) ]]; then
        state=declared; next=verify
    else
        tracked=no
        git -C "$repo_root" ls-files --error-unmatch -- .agent/config.env .agent/board.json .gitignore > /dev/null 2>&1 && tracked=yes
        locally_ignored=yes
        for declaration in .agent/config.env .agent/board.json; do
            git -C "$repo_root" check-ignore --no-index -- "$declaration" > /dev/null 2>&1 || locally_ignored=no
        done
        if [[ $tracked == no && $locally_ignored == yes ]]; then
            # The blessed model keeps declarations per-machine. Once verified,
            # a local exclude is the completion boundary; no onboarding PR or
            # tracked artifact is required before the guards can arm.
            state=armed; next=none
        elif [[ $tracked == yes ]]; then
            # A feature branch can carry the artifacts before its onboarding
            # PR merges. Arm only when the declared base branch itself carries
            # all three files; missing/ambiguous refs stay conservatively
            # committed.
            base_branch=$(sed -n 's/^AGENT_BASE_BRANCH=//p' "$config" 2> /dev/null | head -n 1)
            base_ref=''
            if [[ $base_branch =~ ^[A-Za-z0-9._/-]+$ && $base_branch != -* && $base_branch != *..* ]]; then
                # Remote-tracking origin is fresher after a merge performed by
                # another checkout. Prefer it whenever present; local base is
                # only the fallback for repositories without origin refs.
                if git -C "$repo_root" rev-parse --verify "refs/remotes/origin/$base_branch" > /dev/null 2>&1; then
                    base_ref="refs/remotes/origin/$base_branch"
                elif git -C "$repo_root" rev-parse --verify "refs/heads/$base_branch" > /dev/null 2>&1; then
                    base_ref="refs/heads/$base_branch"
                fi
            fi
            trunk_artifacts=yes
            [[ -n $base_ref ]] || trunk_artifacts=no
            for artifact in .agent/config.env .agent/board.json .gitignore; do
                [[ $trunk_artifacts == yes ]] || break
                git -C "$repo_root" cat-file -e "$base_ref:$artifact" 2> /dev/null || trunk_artifacts=no
            done
            if [[ $trunk_artifacts == yes ]]; then state=armed; next=none; else state=committed; next=arm; fi
        else
            state=verified; next=commit
        fi
    fi
fi

self_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
if [[ $mode == next-steps ]]; then
    agent_run=$self_dir/agent-run.sh
    preflight=$self_dir/agent-preflight.sh
    commit_helper=$self_dir/worktree-commit.sh
    printf 'go-live checklist (repo-root=%s):\n' "$repo_root"
    printf '1. Open a PR that commits .agent/config.env, .agent/board.json, and .gitignore.\n'
    printf '   Commit helper: %s\n' "$commit_helper"
    printf '2. Whether or not that PR has merged, a declared command just runs: %s --cmd <declared name>\n' "$agent_run"
    printf '3. The environment contract (trusted skills path) is still verified; declared commands run directly, with no input-trust step.\n'
    printf '   If the contract is missing or untrusted, refresh it with: %s --ensure --worktree %s\n' \
        "$preflight" "$repo_root"
    exit 0
fi
if [[ $mode == report || $mode == next ]]; then
    printf 'stage=%s next=%s repo-root=%s\n' "$state" "$next" "$repo_root"
    if [[ $mode == report && -r $config && -x $self_dir/onboard-refresh.sh ]]; then
        "$self_dir/onboard-refresh.sh" --repo-root "$repo_root" --summary 2> /dev/null || true
    fi
    [[ $mode == next ]] && exit 0
fi
[[ $mode == preflight ]] || exit 0

detector=$self_dir/detect-toolchains.sh
printf 'environment-preflight repo-root=%s\n' "$repo_root"
ci_gap=$self_dir/ci-gap.sh
if [[ -x $ci_gap ]]; then
    printf 'ci-alignment:\n'
    "$ci_gap" --repo-root "$repo_root" 2>&1 ||
        printf 'ci-alignment: unavailable; inspect the workflow before proposing TEST.\n'
fi
components=''
[[ -x $detector ]] && components=$("$detector" --repo-root "$repo_root" --format components 2> /dev/null || true)
if [[ -n $components ]]; then printf '%s\n' "$components"; else printf 'component= none detected\n'; fi

for pin in .nvmrc .node-version .python-version .ruby-version .tool-versions; do
    if [[ -f $repo_root/$pin ]]; then
        value=$(head -n 1 "$repo_root/$pin" | tr -d '\r')
        printf 'runtime-pin=%s=%s\n' "$pin" "$value"
    fi
done

normalise_version() {
    local value=$1
    value=${value#v}; value=${value#Python }
    printf '%s' "$value"
}
pin_matches() {
    local active=$1 pin=$2
    [[ $active == "$pin" || $active == "$pin."* ]]
}
node_pin=''
python_pin=''
for pin_file in .nvmrc .node-version; do
    [[ -z $node_pin && -f $repo_root/$pin_file ]] && node_pin=$(head -n 1 "$repo_root/$pin_file" | tr -d '\r')
done
[[ -f $repo_root/.python-version ]] && python_pin=$(head -n 1 "$repo_root/.python-version" | tr -d '\r')
if [[ -n $node_pin ]]; then
    node_active=unavailable
    command -v node > /dev/null 2>&1 && node_active=$(normalise_version "$(node --version 2> /dev/null || true)")
    node_match=no; pin_matches "$node_active" "$node_pin" && node_match=yes
    printf 'toolchain=node active=%s pin=%s match=%s\n' "$node_active" "$node_pin" "$node_match"
    [[ $node_match == yes ]] || printf 'guidance: node target=%s; switch the active toolchain to this target before verify (do not assume a version manager).\n' "$node_pin"
fi
if [[ -n $python_pin ]]; then
    python_active=unavailable
    command -v python3 > /dev/null 2>&1 && python_active=$(normalise_version "$(python3 --version 2> /dev/null || true)")
    python_match=no; pin_matches "$python_active" "$python_pin" && python_match=yes
    printf 'toolchain=python active=%s pin=%s match=%s\n' "$python_active" "$python_pin" "$python_match"
    [[ $python_match == yes ]] || printf 'guidance: python target=%s; switch the active toolchain to this target before verify (do not assume a version manager).\n' "$python_pin"
fi

while IFS= read -r line; do
    [[ $line == component=* ]] || continue
    path=$(sed -n 's/.* path=\([^ ]*\) lang=.*/\1/p' <<< "$line")
    lang=$(sed -n 's/.* lang=\([^ ]*\) marker=.*/\1/p' <<< "$line")
    runner=$(sed -n 's/.* runner=//p' <<< "$line")
    [[ -n $path && -n $lang ]] || continue
    case $lang in
        node)
            component_dir=$repo_root
            [[ $path == . ]] || component_dir=$repo_root/$path
            case $runner in
                npm)
                    if [[ -f $component_dir/package-lock.json ]]; then setup='npm ci'; else setup='npm install'; fi # ecosystem-allow: output follows the detected lockfile
                    ;;
                pnpm) setup='pnpm install --frozen-lockfile' ;; # ecosystem-allow: output follows the detected lockfile
                yarn) setup='yarn install --frozen-lockfile' ;; # ecosystem-allow: output follows the detected lockfile
                bun) setup='bun install --frozen-lockfile' ;; # ecosystem-allow: output follows the detected lockfile
                *) setup="$runner install" ;;
            esac
            printf 'setup: component=%s %s (confirm the CI entry point before running)\n' "$path" "$setup"
            ;;
        python)
            if [[ -d $repo_root/$path/.venv ]]; then
                printf 'setup: component=%s existing venv=%s/.venv; dependencies are present\n' "$path" "$path"
            else
                printf 'setup: component=%s python3 -m venv %s/.venv; install declared dependencies\n' "$path" "$path"
            fi
            ;;
        *) printf 'setup: component=%s inspect the pinned %s toolchain before verify\n' "$path" "$lang" ;;
    esac
done <<< "$components"
