#!/usr/bin/env bash
# tests/ci-record-tier0.sh -- idempotently record bench/tier0.sh's Tier-0
# measurement for one merge SHA and publish it back to the ledger.
#
# Used by .github/workflows/record-tier0.yml's job, which runs once per
# green CI completion on main (issue #328, epic #152 "Cadence"). Also
# runnable by hand for a dry run against any checkout.
#
# Idempotent by construction: before measuring, it checks whether the
# ledger already carries a record for this exact SHA and no-ops if so --
# this is what keeps a manual workflow re-run (or, mechanically, the push
# this script's own commit generates) from appending a second row for the
# same merge. bench/tier0.sh's own re-measure-on-demand behavior is
# untouched; this wrapper adds the CI-specific "once per merge" contract on
# top of it. The ledger's append-only guarantee (see bench/README) is
# preserved throughout: this script only ever adds a line via
# bench/tier0.sh, and the eventual git commit stages nothing else.
#
# --push races the ledger's remote tip against this process's own local
# checkout: two runs both starting from the same stale checkout (a workflow
# re-run overlapping the original run, or two runs racing CI completion
# order) must not both see an "unrecorded" ledger and each push a row. To
# close that window, --push does not trust the ledger state the caller
# handed it -- every attempt starts by fetching and hard-resetting to the
# remote branch tip *before* the idempotency check runs, so the check reads
# the freshest state available immediately before it decides. If the
# eventual push is rejected anyway (another writer won the race in the gap
# between that fetch and this push), the whole cycle restarts from a fresh
# fetch rather than rebasing the stale commit already built on outdated
# state -- rebasing an idempotency-check-driven commit onto new history
# would replay a decision (append vs. skip) made against data that is no
# longer current.
set -euo pipefail

program=${0##*/}

usage() {
    printf 'usage: %s --sha SHA [--ledger PATH] [--remote NAME] [--branch NAME] [--push]\n' "$program" >&2
    printf '  --sha SHA      the commit SHA to measure and record (required)\n' >&2
    printf '  --ledger PATH  ledger file (default: bench/results/tier0.jsonl)\n' >&2
    printf '  --remote NAME  git remote to push to (default: origin)\n' >&2
    printf '  --branch NAME  branch to push to (default: main)\n' >&2
    printf '  --push         commit and push the new record; without it the record\n' >&2
    printf '                 is appended to the local ledger only (dry run)\n' >&2
}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

sha=''
ledger=''
remote=origin
branch=main
do_push=false
while (($#)); do
    case $1 in
        --sha)
            (($# >= 2)) || die '--sha requires a value'
            sha=$2
            shift 2
            ;;
        --ledger)
            (($# >= 2)) || die '--ledger requires a value'
            ledger=$2
            shift 2
            ;;
        --remote)
            (($# >= 2)) || die '--remote requires a value'
            remote=$2
            shift 2
            ;;
        --branch)
            (($# >= 2)) || die '--branch requires a value'
            branch=$2
            shift 2
            ;;
        --push)
            do_push=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[[ -n $sha ]] || {
    usage
    die '--sha is required'
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
repo_root=$(cd -- "$script_dir/.." && pwd -P) || die 'could not resolve repo root'

[[ -n $ledger ]] || ledger=$repo_root/bench/results/tier0.jsonl

command -v jq > /dev/null 2>&1 || die 'jq is required and was not found on PATH'

resolved_sha=$(cd -- "$repo_root" && git rev-parse --verify "${sha}^{commit}" 2> /dev/null) ||
    die "ref not present in this checkout: $sha"

# already_recorded LEDGER -- true if LEDGER exists and carries a record for
# $resolved_sha.
already_recorded() {
    local ledger_path=$1
    [[ -f $ledger_path ]] && jq -e --slurp --arg sha "$resolved_sha" \
        'any(.[]?; .plugin_sha == $sha)' "$ledger_path" > /dev/null 2>&1
}

if ! $do_push; then
    # No remote to race against: check once, append once.
    if already_recorded "$ledger"; then
        printf 'tier0 already recorded for %s; nothing to do\n' "$resolved_sha"
        exit 0
    fi
    "$repo_root/bench/tier0.sh" "$resolved_sha" --ledger "$ledger"
    printf 'recorded %s locally (no --push)\n' "$resolved_sha"
    exit 0
fi

cd -- "$repo_root" || die "could not cd to repo root: $repo_root"
rel_ledger=${ledger#"$repo_root"/}

msg_file=$(mktemp) || die 'could not create commit message file'
trap 'rm -f -- "$msg_file"' EXIT
{
    printf 'chore(bench): record tier0 for %s\n\n' "$resolved_sha"
    printf 'Automated Tier-0 measurement appended by CI on merge to %s.\n' "$branch"
    printf 'See bench/README for the ledger schema.\n'
} > "$msg_file"

# Each attempt re-fetches and hard-resets to the remote tip BEFORE checking
# idempotency and appending, so the check and the append it gates are both
# made against state no staler than this attempt's own start. A push
# rejection means another writer landed a commit in the gap between that
# reset and this push; the loop restarts from a fresh fetch rather than
# rebasing, so the next attempt's idempotency check sees that writer's
# commit (and its own decision reflects it) instead of blindly replaying an
# append decided against data that is no longer current.
attempt=1
max_attempts=5
while true; do
    git fetch "$remote" "$branch" || die "could not fetch $remote/$branch"
    git reset --quiet --hard "$remote/$branch" || die "could not sync to $remote/$branch"

    if already_recorded "$ledger"; then
        printf 'tier0 already recorded for %s; nothing to do\n' "$resolved_sha"
        exit 0
    fi

    "$repo_root/bench/tier0.sh" "$resolved_sha" --ledger "$ledger"
    git add -- "$rel_ledger"
    git commit --quiet -F "$msg_file" -- "$rel_ledger" || die 'commit failed'

    if git push "$remote" "HEAD:$branch"; then
        break
    fi

    ((attempt < max_attempts)) || die "failed to push tier0 record after $max_attempts attempts"
    attempt=$((attempt + 1))
    printf 'push rejected (attempt %d of %d); re-syncing and retrying\n' "$attempt" "$max_attempts" >&2
done

printf 'pushed tier0 record for %s to %s/%s\n' "$resolved_sha" "$remote" "$branch"
