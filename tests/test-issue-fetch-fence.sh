#!/usr/bin/env bash
# Suite: the documented issue fetch jq program and atomic fence publication.
# shellcheck disable=SC2016
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='issue fetch and fence recipe'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
skill="$root/agentkit/skills/parallel-issues/SKILL.md"
fixture="$here/fixtures/issue-fetch.json"
fence="$root/agentkit/skills/parallel-issues/scripts/fence-untrusted-data.sh"

# Pull the one documented jq program from the canonical snippet. Executing this
# extracted program, rather than a copied test filter, prevents documentation and
# behavior from drifting apart.
program=$(sed -n '/^issue_contents=$(jq -r /,/<<<"\$issue_payload")$/p' "$skill" |
    sed '1d;$d')
[[ -n $program ]] || { printf '%s\n' 'canonical jq program not found' >&2; exit 1; }
rendered=$(jq -r "$program" <"$fixture")
assert_contains "$rendered" 'Title: Resolver lesson' 'jq renders the issue title'
assert_contains "$rendered" 'Body:' 'jq renders the issue body'
assert_contains "$rendered" 'reliability, area/hooks' 'jq renders labels'
assert_contains "$rendered" 'maintainer: Please preserve atomic writes.' 'jq renders comments'
assert_contains "$rendered" 'unknown: A comment without an author is still data.' \
    'jq renders comments with a missing author'

run_fence_recipe() {
    local producer=$1 target=$2 input=$3
    local tmp="$target.tmp"
    rm -f -- "$target" "$tmp"
    set -o pipefail
    if printf '%s' "$input" | "$producer" >"$tmp"; then
        mv -f -- "$tmp" "$target"
    else
        rm -f -- "$target" "$tmp"
        return 1
    fi
}

producer="$tmp_dir/producer.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "exact fenced bytes"' >"$producer"
chmod +x "$producer"
target="$tmp_dir/fenced-spec.txt"
run_fence_recipe "$producer" "$target" "$rendered"
assert_eq 'exact fenced bytes' "$(<"$target")" 'success publishes exact fenced bytes'
assert_eq no "$( [[ ! -e "$target.tmp" ]] && printf no || printf yes )" \
    'success removes the temporary fence'

failing="$tmp_dir/failing.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" partial' 'exit 7' >"$failing"
chmod +x "$failing"
failed_rc=0
run_fence_recipe "$failing" "$target" "$rendered" || failed_rc=$?
assert_eq 1 "$failed_rc" 'failed upstream is reported'
assert_eq no "$( [[ ! -e "$target" ]] && printf no || printf yes )" \
    'failed upstream leaves no final fence'
assert_eq no "$( [[ ! -e "$target.tmp" ]] && printf no || printf yes )" \
    'failed upstream removes its temporary fence'

# The real helper remains the producer for boundary correctness; this assertion
# checks its output has matching nonce-bound markers without persisting a partial
# final file.
real_target="$tmp_dir/real-fenced-spec.txt"
run_fence_recipe "$fence" "$real_target" "$rendered"
real_bytes=$(<"$real_target")
assert_contains "$real_bytes" '<BEGIN UNTRUSTED ISSUE DATA: BND_' \
    'the real helper emits the opening boundary'
assert_contains "$real_bytes" '<END UNTRUSTED ISSUE DATA: BND_' \
    'the real helper emits the closing boundary'

finish
