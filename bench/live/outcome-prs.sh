#!/usr/bin/env bash
# bench/live/outcome-prs.sh REPO CLONE "01 03 04" EXIT_RC ELAPSED: what a PR-scenario trial delivered.
# The oracle is main itself: the hidden acceptance suites run against origin/main after the trial, so a planted bug
# merged unfixed fails its issue. Also reports how many seeded PRs merged and how many are still open.
set -euo pipefail
export LC_ALL=C
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
accept="$(dirname -- "$here")/accept/run-accept.sh"
repo=$1 clone=$2 wanted=$3 rc=$4 elapsed=$5
prs="${AK_BENCH_WORK:-$HOME/.cache/ak-bench}/current-prs.json"

git -C "$clone" fetch -q origin main
tree=$(mktemp -d)
git -C "$clone" archive origin/main | tar -x -C "$tree"
vector=$("$accept" "$tree" 2>/dev/null || printf '{"results":{}}')
rm -rf -- "$tree"
detail='[]'
for pr in $(jq -r '.[]' "$prs"); do
    detail=$(jq --argjson s "$(gh api "repos/$repo/pulls/$pr" --jq '{pr: .number, merged: .merged, state: .state, draft: .draft}')" '. + [$s]' <<<"$detail")
done
jq -n --argjson v "$vector" --arg wanted "$wanted" --argjson d "$detail" --argjson rc "$rc" --argjson elapsed "$elapsed" '
    ($wanted | split(" ") | map(select(. != "")) | map("tally-" + .)) as $ids |
    {exit_rc: $rc, timed_out: ($rc == 124 or $rc == 137), elapsed_s: $elapsed,
     wanted: ($ids | length), passed: ([$ids[] | select($v.results[.] == "pass")] | length),
     issues: ([$ids[] | {key: ., value: ($v.results[.] == "pass")}] | from_entries),
     prs: ($d | length), merged: ([$d[] | select(.merged)] | length), pr_detail: $d}'
