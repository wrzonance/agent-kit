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

# Pull the documented content-validation program the same way, so the test
# executes the recipe's actual guard rather than a test-local approximation.
validation=$(sed -n '/^issue_has_content=$(jq -r /,/<<<"\$issue_payload")$/p' "$skill" |
    sed '1d;$d')
[[ -n $validation ]] || { printf '%s\n' 'canonical validation program not found' >&2; exit 1; }

# The documented fetch recipe must fail before it creates a fence when GitHub
# returns an error or when the payload carries no issue content. Both jq
# programs here are the extracted canonical ones: the renderer emits fixed
# headings, so only the validation program can reject an empty payload.
run_fetch_and_fence_recipe() {
    local fetcher=$1 producer=$2 target=$3
    local issue_payload issue_contents issue_has_content
    issue_payload=$("$fetcher") || return 1
    issue_has_content=$(jq -r "$validation" <<<"$issue_payload")
    [[ $issue_has_content == true ]] || return 1
    issue_contents=$(jq -r "$program" <<<"$issue_payload")
    run_fence_recipe "$producer" "$target" "$issue_contents"
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

failed_fetch="$tmp_dir/failed-fetch.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 7' >"$failed_fetch"
chmod +x "$failed_fetch"
failed_fetch_rc=0
run_fetch_and_fence_recipe "$failed_fetch" "$producer" "$target" || failed_fetch_rc=$?
assert_eq 1 "$failed_fetch_rc" 'a failed issue fetch is reported'
assert_eq no "$( [[ ! -e "$target" ]] && printf no || printf yes )" \
    'a failed issue fetch leaves no final fence'
assert_eq no "$( [[ ! -e "$target.tmp" ]] && printf no || printf yes )" \
    'a failed issue fetch leaves no temporary fence'

# {} through the CANONICAL renderer would still produce the fixed headings, so
# this fixture proves the validation program is what rejects an empty payload.
empty_fetch="$tmp_dir/empty-fetch.sh"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "{}"' >"$empty_fetch"
chmod +x "$empty_fetch"
empty_fetch_rc=0
run_fetch_and_fence_recipe "$empty_fetch" "$producer" "$target" || empty_fetch_rc=$?
assert_eq 1 "$empty_fetch_rc" 'an empty issue payload is rejected before rendering'
assert_eq no "$( [[ ! -e "$target" ]] && printf no || printf yes )" \
    'an empty issue payload leaves no final fence'
assert_eq no "$( [[ ! -e "$target.tmp" ]] && printf no || printf yes )" \
    'an empty issue payload leaves no temporary fence'

recipe_text=$(<"$skill")
assert_contains "$recipe_text" 'issue_payload=$(gh issue view "$issue_number" --json title,body,labels,comments) || exit 1' \
    'the canonical recipe exits when GitHub issue fetch fails'
assert_contains "$recipe_text" '[[ $issue_has_content == true ]] || exit 1' \
    'the canonical recipe rejects an empty issue payload before rendering'
assert_contains "$recipe_text" 'target="$worktree/.agent/fenced-spec.txt"' \
    'the canonical recipe keeps fenced bytes in excluded per-worktree state'
assert_contains "$recipe_text" 'mkdir -p -- "${target%/*}" || exit 1' \
    'the canonical recipe creates its excluded artifact directory'

worktree="$tmp_dir/worktree"
git init -q "$worktree"
printf '%s\n' '.agent/*' >"$worktree/.gitignore"
git -C "$worktree" add .gitignore
git -C "$worktree" -c user.email=t@example.invalid -c user.name=t commit -qm fixture
worktree_target="$worktree/.agent/fenced-spec.txt"
mkdir -p -- "${worktree_target%/*}"
run_fence_recipe "$producer" "$worktree_target" "$rendered"
assert_eq '' "$(git -C "$worktree" status --short)" \
    'the canonical per-worktree fence artifact does not dirty the worktree'

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
