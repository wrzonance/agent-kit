#!/usr/bin/env bash
# Suite: the two-wave fixture tally-waves-v1 (issues 11-14): its hidden accept suites, outcome.sh scoring,
# and the sandbox reset's per-issue board status. Offline: stub gh, a local bare "origin".
set -uo pipefail

TEST_NAME='bench accept waves'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

run_accept="$repo_root/bench/accept/run-accept.sh"
gold="$repo_root/bench/gold/tally"
fixture="$repo_root/bench/fixtures/tally"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

vector() { "$run_accept" --set waves "$1" 2>/dev/null | jq -c '.results'; }

assert_eq '{"tally-11":"pass","tally-12":"pass","tally-13":"pass","tally-14":"pass"}' "$(vector "$gold")" 'gold passes all four wave suites'
assert_eq '{"tally-11":"fail","tally-12":"fail","tally-13":"fail","tally-14":"fail"}' "$(vector "$fixture")" 'the untouched skeleton fails all four'

no11="$tmp/no11"; cp -r "$gold/." "$no11"; rm "$no11/src/sorting.js"
assert_eq '{"tally-11":"fail","tally-12":"fail","tally-13":"pass","tally-14":"pass"}' "$(vector "$no11")" 'without tally-11 the dependent tally-12 fails too'
no13="$tmp/no13"; cp -r "$gold/." "$no13"; rm "$no13/src/search.js"
assert_eq '{"tally-11":"pass","tally-12":"pass","tally-13":"fail","tally-14":"fail"}' "$(vector "$no13")" 'without tally-13 the dependent tally-14 fails too'

bad11="$tmp/bad11"; cp -r "$gold/." "$bad11"
sed -i 's/  return copy;/  return items;/' "$bad11/src/sorting.js"
assert_eq fail "$(vector "$bad11" | jq -r '.["tally-11"]')" 'tally-11 rejects returning the input array for an unknown key'

bad14="$tmp/bad14"; cp -r "$gold/." "$bad14"
sed -i "/return matches.map/c\\  return matches.map((item) => '<p>' + item.name + '</p>').join('');" "$bad14/src/results.js"
assert_eq fail "$(vector "$bad14" | jq -r '.["tally-14"]')" 'tally-14 rejects text that is not renderItemRow markup'
assert_eq 10 "$("$run_accept" "$gold" | jq .total)" 'the default set is still the ten frozen suites'

# outcome.sh against a PR head that is the gold tree: it exits 0 and scores 11-14 with the waves set.
origin="$tmp/origin.git"
git init -q --bare "$origin"
work="$tmp/work"; cp -r "$gold" "$work"
git -C "$work" init -q -b main
git -C "$work" add -A
git -C "$work" -c user.name=t -c user.email=t@example.invalid commit -q -m gold
sha=$(git -C "$work" rev-parse HEAD)
git -C "$work" push -q "$origin" "HEAD:refs/pull/7/head" "HEAD:refs/heads/main"
git clone -q "$origin" "$tmp/clone"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<STUB
#!/usr/bin/env bash
case "\$*" in
    *check-runs*) echo green ;;
    *pulls*) printf '7\t$sha\tfalse\n' ;;
esac
STUB
chmod +x "$tmp/bin/gh"
out=$(PATH="$tmp/bin:$PATH" "$repo_root/bench/live/outcome.sh" o/r "$tmp/clone" "11 12 13 14" 0 5 2>&1)
rc=$?
assert_eq 0 "$rc" 'outcome.sh exits 0 for the wave ids'
assert_eq 4 "$(jq .passed <<<"$out")" 'outcome.sh scores 4 of 4 wave issues passed'
assert_eq 4 "$(jq .wanted <<<"$out")" 'outcome.sh wants the four wave issues'

# Board status: the blocked dependents start in Backlog, everything else (01-10 included) in Ready.
# shellcheck source=../bench/live/sandbox.sh
source "$repo_root/bench/live/sandbox.sh"
statuses=''
for id in 01 03 10 11 12 13 14; do statuses+="$id=$(issue_board_status "$(ls "$repo_root"/bench/issues/"$id"-*.md)") "; done
assert_eq '01=Ready 03=Ready 10=Ready 11=Ready 12=Backlog 13=Ready 14=Backlog ' "$statuses" 'only the blocked wave dependents start in Backlog'
bench="$repo_root/bench"
# shellcheck source=../bench/live/trial-lib.sh
source "$repo_root/bench/live/trial-lib.sh"
assert_eq 2 "$(ready_count '11 12 13 14')" 'the board wait counts only the unblocked wave issues'
assert_eq 3 "$(ready_count '01 03 04')" 'the board wait still counts every frozen issue'

finish
