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

fence_rm() {
    if [[ ${FENCE_TEST_FAIL_RM_PATH:-} == "$1" ]]; then
        unset FENCE_TEST_FAIL_RM_PATH
        return 1
    fi
    rm -f -- "$1"
}

fence_mv() {
    if [[ ${FENCE_TEST_FAIL_MV_PATH:-} == "$2" ]]; then
        unset FENCE_TEST_FAIL_MV_PATH
        return 1
    fi
    mv -f -- "$1" "$2"
}

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
    local tmp="$target.tmp" input_file cleanup_rc
    input_file=$(mktemp "$tmp_dir/fence-input.XXXXXX") || return 1
    cleanup_rc=0
    fence_rm "$target" || cleanup_rc=1
    fence_rm "$tmp" || cleanup_rc=1
    if (( cleanup_rc != 0 )); then
        fence_rm "$input_file" || cleanup_rc=1
        return 1
    fi
    if ! printf '%s' "$input" >"$input_file"; then
        fence_rm "$input_file" || cleanup_rc=1
        return 1
    fi
    if "$producer" <"$input_file" >"$tmp"; then
        if ! fence_rm "$input_file"; then
            cleanup_rc=1
        fi
        if (( cleanup_rc != 0 )); then
            fence_rm "$target" || cleanup_rc=1
            fence_rm "$tmp" || cleanup_rc=1
            return 1
        fi
        if ! fence_mv "$tmp" "$target"; then
            cleanup_rc=1
            fence_rm "$target" || cleanup_rc=1
            fence_rm "$tmp" || cleanup_rc=1
            return 1
        fi
    else
        cleanup_rc=0
        fence_rm "$target" || cleanup_rc=1
        fence_rm "$tmp" || cleanup_rc=1
        fence_rm "$input_file" || cleanup_rc=1
        return 1
    fi
}

# Deterministic regression fixture: an early-exiting consumer closes stdin
# before a large writer finishes, reproducing the historical SIGPIPE race.
early_exit="$tmp_dir/early-exit.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$early_exit"
chmod +x "$early_exit"
large_input=$(printf '%*s' 1048576 '' | tr ' ' x)
large_input_file="$tmp_dir/large-input"
printf '%s' "$large_input" >"$large_input_file"
direct_err="$tmp_dir/direct.err"
set +e
# shellcheck disable=SC2002
# Keep cat as the actual pipe writer: input redirection would remove the EPIPE
# boundary this regression probe is required to exercise.
{ cat "$large_input_file" | "$early_exit" > /dev/null; } 2>"$direct_err"
direct_rc=$?
set -e
if [[ $direct_rc == 141 || $(grep -c 'Broken pipe' "$direct_err" || true) -gt 0 ]]; then
    _pass 'the old pipe writer reports SIGPIPE or Broken pipe deterministically'
else
    _fail 'the old pipe writer reports SIGPIPE or Broken pipe deterministically' \
        "writer rc=$direct_rc; stderr=$(<"$direct_err")"
fi
early_target="$tmp_dir/early-fence.txt"
early_rc=0
run_fence_recipe "$early_exit" "$early_target" "$large_input" || early_rc=$?
assert_eq 0 "$early_rc" \
    'the fence recipe accepts an early-exiting producer without killing its writer'
assert_eq yes "$( [[ -e "$early_target" ]] && printf yes || printf no )" \
    'the fence recipe publishes the early producer output'

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

# Every cleanup and publication operation is part of the recipe contract. A
# deterministic command shim is added by the implementation below; these
# probes must fail closed even when the operation itself fails.
rm_failure_target="$tmp_dir/rm-failure.txt"
rm_failure_rc=0
FENCE_TEST_FAIL_RM_PATH="$rm_failure_target" \
    run_fence_recipe "$producer" "$rm_failure_target" "$rendered" || rm_failure_rc=$?
assert_eq 1 "$rm_failure_rc" 'a stale-target cleanup failure is reported'

mv_failure_target="$tmp_dir/mv-failure.txt"
mv_failure_rc=0
FENCE_TEST_FAIL_MV_PATH="$mv_failure_target" \
    run_fence_recipe "$producer" "$mv_failure_target" "$rendered" || mv_failure_rc=$?
assert_eq 1 "$mv_failure_rc" 'a publication move failure is reported'
assert_eq no "$( [[ ! -e "$mv_failure_target.tmp" ]] && printf no || printf yes )" \
    'a publication move failure removes its temporary fence'

# A crash after publishing only one member of the pair must be recoverable on
# the next invocation. The canonical recipe removes an incomplete pair and
# republishes both files, while a complete ready-marked pair is refused as
# deliberate existing state.
run_recoverable_pair_recipe() {
    local producer=$1 target=$2 prior_target=$3 input=$4 prior_input=$5
    local tmp="$target.tmp" prior_tmp="$prior_target.tmp" ready="$target.ready"
    if [[ -d $ready && -f $target && -f $prior_target &&
        ! -e $tmp && ! -e $prior_tmp ]]; then
        return 1
    fi
    rm -f -- "$target" "$prior_target" "$tmp" "$prior_tmp"
    rmdir -- "$ready" 2>/dev/null || rm -f -- "$ready"
    if ! printf '%s' "$input" | "$producer" >"$tmp" ||
        ! printf '%s' "$prior_input" | "$producer" >"$prior_tmp"; then
        rm -f -- "$target" "$prior_target" "$tmp" "$prior_tmp"
        return 1
    fi
    mv -f -- "$tmp" "$target" || return 1
    mv -f -- "$prior_tmp" "$prior_target" || return 1
    mkdir -- "$ready" || return 1
}

recovery_target="$tmp_dir/recovery-spec.txt"
recovery_prior="$tmp_dir/recovery-prior.txt"
printf '%s\n' stale >"$recovery_target"
printf '%s\n' stale-marker >"$recovery_target.ready"
run_recoverable_pair_recipe "$producer" "$recovery_target" "$recovery_prior" \
    'new spec' 'new prior'
assert_eq 'exact fenced bytes' "$(<"$recovery_target")" \
    'an incomplete first-move pair is replaced on retry'
assert_eq 'exact fenced bytes' "$(<"$recovery_prior")" \
    'recovery publishes the missing prior-art member'
assert_eq yes "$( [[ -d "$recovery_target.ready" ]] && printf yes || printf no )" \
    'recovery leaves the ready marker'
complete_rc=0
run_recoverable_pair_recipe "$producer" "$recovery_target" "$recovery_prior" \
    'new spec' 'new prior' || complete_rc=$?
assert_eq 1 "$complete_rc" 'a complete ready-marked pair is not silently overwritten'

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
assert_contains "$recipe_text" 'mkdir -p -- "${issue_payload_file%/*}" || exit 1' \
    'the canonical recipe creates the raw payload directory'
assert_contains "$recipe_text" '[[ $issue_has_content == true ]] || exit 1' \
    'the canonical recipe rejects an empty issue payload before rendering'
assert_contains "$recipe_text" 'target="$worktree/.agent/fenced-spec.txt"' \
    'the canonical recipe keeps fenced bytes in excluded per-worktree state'
assert_contains "$recipe_text" 'prior_target="$worktree/.agent/fenced-prior-art.txt"' \
    'the canonical recipe persists prior-art fence bytes beside the spec'
assert_contains "$recipe_text" ': "${prior_art_contents:="(no prior art selected by triage digest)"}"' \
    'the canonical recipe initializes the absent-prior-art sentinel before fencing'
assert_contains "$recipe_text" 'cat -- "$worktree/.agent/fenced-spec.txt"' \
    'the worker embeds persisted spec bytes rather than re-fencing'
assert_contains "$recipe_text" 'cat -- "$worktree/.agent/fenced-prior-art.txt"' \
    'the worker embeds persisted prior-art bytes rather than re-fencing'
assert_contains "$recipe_text" 'Re-running the fence helper for an existing block is churn' \
    'the recipe documents deliberate deletion before re-fencing'
assert_contains "$recipe_text" 'fence artifacts already exist; delete the affected file deliberately' \
    'the recipe refuses implicit re-fencing of persisted artifacts'
assert_contains "$recipe_text" 'mkdir -p -- "${target%/*}" || exit 1' \
    'the canonical recipe creates its excluded artifact directory'
assert_contains "$recipe_text" 'ready_marker="$worktree/.agent/fenced-ready"' \
    'the canonical recipe has a ready marker for the artifact pair'
assert_contains "$recipe_text" 'incomplete stale fence artifacts; removing them before retry' \
    'the canonical recipe removes an incomplete stale pair before retry'
assert_contains "$recipe_text" 'mkdir -- "$ready_marker"' \
    'the canonical recipe publishes readiness only after both moves'
assert_contains "$recipe_text" 'spec_payload=$(mktemp' \
    'the canonical recipe creates a temporary spec payload file'
assert_contains "$recipe_text" 'prior_payload=$(mktemp' \
    'the canonical recipe creates a temporary prior-art payload file'
assert_contains "$recipe_text" 'chmod 600 -- "$spec_payload" "$prior_payload"' \
    'the canonical recipe protects both temporary payload files'
assert_contains "$recipe_text" 'rm -f -- "$spec_payload" "$prior_payload"' \
    'the canonical recipe removes both temporary payload files after publication'
assert_contains "$recipe_text" 'trap cleanup_fence EXIT' \
    'the canonical recipe cleans up on normal exit'
assert_contains "$recipe_text" 'fence_signal_handler()' \
    'the canonical recipe defines a signal cleanup handler'
assert_contains "$recipe_text" 'trap fence_signal_handler HUP INT TERM' \
    'the canonical recipe routes termination signals to the cleanup handler'
assert_contains "$recipe_text" 'trap - EXIT HUP INT TERM' \
    'the signal handler clears traps before exiting'
assert_not_contains "$recipe_text" 'trap cleanup_fence EXIT HUP INT TERM' \
    'the canonical recipe does not resume after signals through a combined cleanup trap'
cleanup_line=$(grep -nF 'trap cleanup_fence EXIT' <<<"$recipe_text" | head -n 1 | cut -d: -f1)
first_payload_line=$(grep -nF 'spec_payload=$(mktemp' <<<"$recipe_text" | head -n 1 | cut -d: -f1)
assert_eq yes "$([[ -n $cleanup_line && -n $first_payload_line && $cleanup_line -lt $first_payload_line ]] && printf yes || printf no)" \
    'the canonical fence cleanup trap is installed before payload allocation'
assert_contains "$recipe_text" '<"$spec_payload"' \
    'the canonical recipe feeds the spec fence producer by stdin redirection'
assert_contains "$recipe_text" '<"$prior_payload"' \
    'the canonical recipe feeds the prior-art fence producer by stdin redirection'
assert_not_contains "$recipe_text" 'printf '\''%s'\'' "$issue_contents" |' \
    'the canonical recipe never pipes spec bytes into a fence producer'
assert_not_contains "$recipe_text" 'printf '\''%s'\'' "$prior_art_contents" |' \
    'the canonical recipe never pipes prior-art bytes into a fence producer'

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
