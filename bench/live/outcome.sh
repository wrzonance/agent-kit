#!/usr/bin/env bash
# bench/live/outcome.sh REPO CLONE "01 03 04" EXIT_RC ELAPSED: what a trial delivered, as one JSON object.
#
# Every PR open after the trial is the trial's (the reset closed all others). For each PR head: CI state from
# REST check-runs, and the hidden acceptance suites (bench/accept/run-accept.sh) run against that tree. An
# issue counts as passed when any PR head passes its suite, because a chain's last PR carries its predecessors.
set -euo pipefail
export LC_ALL=C

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
accept="$(dirname -- "$here")/accept/run-accept.sh"
repo=$1 clone=$2 wanted=$3 rc=$4 elapsed=$5

prs='[]' passed='{}'
for id in $wanted; do passed=$(jq --arg id "tally-$id" '. + {($id): false}' <<<"$passed"); done

while IFS=$'\t' read -r number sha draft; do
    [[ -n $number ]] || continue
    ci=$(gh api "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '
        [.check_runs[] | {done: (.conclusion != null or .status == "completed"),
                          bad: ((.conclusion // "success") | IN("success","neutral","skipped") | not)}]
        | if length == 0 then "none" elif any(.[]; .done | not) then "pending"
          elif any(.[]; .bad) then "red" else "green" end')
    tree=$(mktemp -d)
    git -C "$clone" fetch -q origin "pull/$number/head"
    git -C "$clone" archive "$sha" | tar -x -C "$tree"
    vector=$("$accept" "$tree" 2>/dev/null || printf '{"results":{}}')
    rm -rf -- "$tree"
    passed=$(jq --argjson v "$vector" 'with_entries(.value = (.value or ($v.results[.key] == "pass")))' <<<"$passed")
    prs=$(jq --arg n "$number" --arg sha "$sha" --arg ci "$ci" --argjson draft "$draft" --argjson v "$vector" \
        '. + [{pr: ($n | tonumber), head: $sha, draft: $draft, ci: $ci, accept: ($v.results // {})}]' <<<"$prs")
done < <(gh api "repos/$repo/pulls?state=open&per_page=100" --jq '.[] | [.number, .head.sha, .draft] | @tsv')

jq -n --argjson prs "$prs" --argjson issues "$passed" --argjson rc "$rc" --argjson elapsed "$elapsed" '{
    exit_rc: $rc, timed_out: ($rc == 124 or $rc == 137), elapsed_s: $elapsed,
    prs: ($prs | length), prs_green: ([$prs[] | select(.ci == "green")] | length),
    wanted: ($issues | length), passed: ([$issues[] | select(.)] | length),
    issues: $issues, pr_detail: $prs}'
