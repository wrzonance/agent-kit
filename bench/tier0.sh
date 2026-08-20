#!/usr/bin/env bash
# bench/tier0.sh -- Tier 0 static token-surface accounting (epic #152, issue #323).
#
# Q1 the epic asks first: did the compression happen. Tier 0 answers it for
# free -- no model call, no network, just accounting bytes already committed
# to git at a given SHA -- and appends one record to the results ledger every
# later tier appends to (bench/results/*.jsonl; see bench/README).
#
# Three surfaces, all over agentkit/skills/:
#   resident             every SKILL.md file's own bytes -- what a session
#                         pays just by the skill existing, before any
#                         reference is ever read.
#   reachable             every *.md file (SKILL.md + references/*.md +
#                         .shared/*.md) -- the ceiling if every reference
#                         were hit.
#   dispatched_template   the static byte size of parallel-issues'
#                         references/worker-prompts.md alone: the one
#                         reference that is not read conditionally -- it is
#                         rendered and paid on *every* dispatch, hit rate 1.0
#                         by construction (see issue #323's maintainer
#                         comment). This is the template-only, fixture-free
#                         component of the full per-dispatch surface; the
#                         substitution byte count (issue body, prior art,
#                         per-issue write set -- which varies per issue, not
#                         per SHA) needs a frozen reference-dispatch fixture
#                         and is intentionally left to a later slice.
#
# Every byte count is converted to tokens through the same estimator
# tests/lint-skill-size.sh uses (tests/lib/token-estimate.sh), so the lint
# gate and this benchmark can never silently disagree about the same bytes.
#
# All measurements read git objects at the resolved SHA only -- never the
# working tree -- so the result is identical regardless of what happens to be
# checked out, and no network access occurs.
set -euo pipefail

program=${0##*/}

usage() {
    printf 'usage: %s REF [--ledger PATH] [--fixture-version STR] [--timestamp TS]\n' "$program" >&2
    printf '  REF                    a git commit-ish resolvable in this checkout (SHA, tag, branch)\n' >&2
    printf '  --ledger PATH          ledger file to append to (default: bench/results/tier0.jsonl)\n' >&2
    printf '  --fixture-version STR  ledger key component (default: tier0-v1)\n' >&2
    printf '  --timestamp TS         override the recorded UTC measured_at (default: now); for tests\n' >&2
}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

[[ $# -ge 1 ]] || { usage; exit 2; }
ref=$1
shift

ledger=''
fixture_version='tier0-v1'
timestamp=''
while (($#)); do
    case $1 in
        --ledger)
            (($# >= 2)) || die '--ledger requires a value'
            ledger=$2
            shift 2
            ;;
        --fixture-version)
            (($# >= 2)) || die '--fixture-version requires a value'
            fixture_version=$2
            shift 2
            ;;
        --timestamp)
            (($# >= 2)) || die '--timestamp requires a value'
            timestamp=$2
            shift 2
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

[[ -n $fixture_version && $fixture_version != *[[:cntrl:]]* ]] ||
    die '--fixture-version must be a non-empty string with no control characters'
[[ -z $timestamp || $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
    die '--timestamp must look like an ISO-8601 UTC instant, e.g. 2026-08-20T00:00:00Z'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
repo_root=$(cd -- "$script_dir/.." && pwd -P) || die 'could not resolve repo root'

# shellcheck source=../tests/lib/token-estimate.sh
source "$repo_root/tests/lib/token-estimate.sh"

[[ -z $ledger ]] && ledger=$repo_root/bench/results/tier0.jsonl

cd -- "$repo_root" || die "could not cd to repo root: $repo_root"

command -v jq > /dev/null 2>&1 || die 'jq is required and was not found on PATH'

sha=$(git rev-parse --verify "${ref}^{commit}" 2> /dev/null) ||
    die "ref not present in this checkout: '$ref' does not resolve to a commit object here -- if it should exist, this checkout is likely shallow; fetch full history (e.g. \`git fetch --unshallow\`, or actions/checkout's fetch-depth: 0) before measuring an older commit"

# sum_bytes_matching PATTERN -- sums the blob size at $sha of every path
# under agentkit/skills whose basename matches the (anchored) extended-regex
# PATTERN. NUL-delimited end to end (`ls-tree -z`, `read -d ''`, no grep) so
# a path containing a tab, newline, or other byte `ls-tree`'s default
# C-quoting would otherwise mangle is still read and counted correctly --
# this is a measurement instrument whose output is committed to an
# append-only ledger, so a silently-wrong count is worse than a crash. A
# path that cannot be read is a hard failure, not a silently-skipped zero.
sum_bytes_matching() {
    local pattern=$1 total=0 path size
    while IFS= read -r -d '' path; do
        [[ -n $path ]] || continue
        [[ $path =~ $pattern ]] || continue
        size=$(git cat-file -s "$sha:$path") || die "could not read blob size for $path at $sha"
        total=$((total + size))
    done < <(git ls-tree -rz --name-only "$sha" -- agentkit/skills)
    printf '%d\n' "$total"
}

resident_bytes=$(sum_bytes_matching '/SKILL\.md$')
reachable_bytes=$(sum_bytes_matching '\.md$')

resident_tokens=$(estimate_tokens "$resident_bytes")
reachable_tokens=$(estimate_tokens "$reachable_bytes")

dispatched_template_path='agentkit/skills/parallel-issues/references/worker-prompts.md'
dispatched_template_present=false
dispatched_template_bytes=0
if git cat-file -e "$sha:$dispatched_template_path" 2> /dev/null; then
    dispatched_template_present=true
    dispatched_template_bytes=$(git cat-file -s "$sha:$dispatched_template_path") ||
        die "could not read blob size for $dispatched_template_path at $sha"
fi
dispatched_template_tokens=$(estimate_tokens "$dispatched_template_bytes")

[[ -n $timestamp ]] || timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ledger_dir=$(dirname -- "$ledger")
mkdir -p -- "$ledger_dir" || die "could not create ledger directory: $ledger_dir"
[[ ! -e $ledger || ! -L $ledger ]] || die "refusing to append through a symlink: $ledger"

# Tier-0 records carry no model call, so model/effort are a reserved sentinel
# rather than a real identifier -- the same ledger schema every later tier's
# real (model, effort) pairs slot into (see bench/README).
record=$(jq -nc \
    --arg plugin_sha "$sha" \
    --arg fixture_version "$fixture_version" \
    --arg model 'static-accounting' \
    --arg effort 'n/a' \
    --arg measured_at "$timestamp" \
    --argjson resident_bytes "$resident_bytes" \
    --argjson resident_tokens "$resident_tokens" \
    --argjson reachable_bytes "$reachable_bytes" \
    --argjson reachable_tokens "$reachable_tokens" \
    --argjson dispatched_template_bytes "$dispatched_template_bytes" \
    --argjson dispatched_template_tokens "$dispatched_template_tokens" \
    --argjson dispatched_template_present "$dispatched_template_present" \
    --arg dispatched_template_source "$dispatched_template_path" \
    '{
        plugin_sha: $plugin_sha,
        fixture_version: $fixture_version,
        model: $model,
        effort: $effort,
        measured_at: $measured_at,
        resident: {bytes: $resident_bytes, tokens: $resident_tokens},
        reachable: {bytes: $reachable_bytes, tokens: $reachable_tokens},
        dispatched_template: {
            bytes: $dispatched_template_bytes,
            tokens: $dispatched_template_tokens,
            present: $dispatched_template_present,
            source: $dispatched_template_source
        }
    }') || die 'could not build ledger record'

# Append only. This script never opens the ledger for anything but appending
# -- see tests/test-bench-tier0.sh's append-only assertion, and bench/README's
# "charts are a pure function of the ledger" note.
printf '%s\n' "$record" >> "$ledger" || die "could not append to ledger: $ledger"

printf 'tier0 %s: resident=%d bytes (~%d tok) reachable=%d bytes (~%d tok) dispatched_template=%d bytes (~%d tok, present=%s)\n' \
    "$sha" "$resident_bytes" "$resident_tokens" "$reachable_bytes" "$reachable_tokens" \
    "$dispatched_template_bytes" "$dispatched_template_tokens" "$dispatched_template_present"
printf 'appended to %s\n' "$ledger"
