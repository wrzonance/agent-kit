#!/usr/bin/env bash
# tests/ci-record-tier0.sh -- idempotently record bench/tier0.sh's Tier-0
# measurement for one merge SHA and publish it back to the ledger.
#
# Used by .github/workflows/ci.yml's record-tier0 job, which runs once per
# push to main (issue #328, epic #152 "Cadence"). Also runnable by hand for
# a dry run against any checkout.
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

# --- idempotency: a record for this exact SHA already exists -------------
if [[ -f $ledger ]] && jq -e --slurp --arg sha "$resolved_sha" \
    'any(.[]?; .plugin_sha == $sha)' "$ledger" > /dev/null 2>&1; then
    printf 'tier0 already recorded for %s; nothing to do\n' "$resolved_sha"
    exit 0
fi

"$repo_root/bench/tier0.sh" "$resolved_sha" --ledger "$ledger"

if ! $do_push; then
    printf 'recorded %s locally (no --push)\n' "$resolved_sha"
    exit 0
fi

cd -- "$repo_root" || die "could not cd to repo root: $repo_root"

rel_ledger=${ledger#"$repo_root"/}
git add -- "$rel_ledger"

msg_file=$(mktemp) || die 'could not create commit message file'
trap 'rm -f -- "$msg_file"' EXIT
{
    printf 'chore(bench): record tier0 for %s\n\n' "$resolved_sha"
    printf 'Automated Tier-0 measurement appended by CI on merge to %s.\n' "$branch"
    printf 'See bench/README for the ledger schema.\n'
} > "$msg_file"
git commit --quiet -F "$msg_file" -- "$rel_ledger" || die 'commit failed'

# Push with a short retry to absorb ordinary races against unrelated commits
# landing on the target branch between checkout and push; the workflow's own
# job-level concurrency group serializes concurrent record-tier0 runs, so
# this loop is a safety net, not the primary defense against a duplicate
# append.
attempt=1
max_attempts=3
while true; do
    if git push "$remote" "HEAD:$branch"; then
        break
    fi
    ((attempt < max_attempts)) || die "failed to push tier0 record after $max_attempts attempts"
    attempt=$((attempt + 1))
    git fetch "$remote" "$branch" || die "could not fetch $remote/$branch to retry the push"
    git rebase "$remote/$branch" || die "could not rebase onto $remote/$branch to retry the push"
done

printf 'pushed tier0 record for %s to %s/%s\n' "$resolved_sha" "$remote" "$branch"
