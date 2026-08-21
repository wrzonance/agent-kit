#!/usr/bin/env bash
# Suite: tests/ci-record-tier0.sh -- the CI wrapper that idempotently
# records bench/tier0.sh's Tier-0 measurement for one merge SHA and
# publishes it back to the ledger (issue #328, epic #152 "Cadence").
#
# Covers the two acceptance criteria a synthetic fixture can actually prove:
#  - a re-run for the same SHA appends exactly one record, never a second;
#  - the append-only property survives round-tripping through a real
#    push/pull (the ledger file only ever grows, existing lines never
#    change).
# The .github/workflows/ci.yml wiring itself (push-to-main trigger, the
# structural [skip ci] anti-recursion mechanism, and the deliberate absence
# of a concurrency group) is asserted directly against the checked-in
# workflow text, since exercising GitHub Actions triggers themselves is
# outside what a local suite can run.
set -uo pipefail

TEST_NAME='ci-record-tier0'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_wrapper="$repo_root/tests/ci-record-tier0.sh"
real_tier0="$repo_root/bench/tier0.sh"
real_estimator="$repo_root/tests/lib/token-estimate.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

RUN_RC=0
RUN_OUT=''
run_wrapper() {
    RUN_RC=0
    RUN_OUT=$("$@" 2>&1) || RUN_RC=$?
}

# --- usage / argument validation ----------------------------------------
run_wrapper "$real_wrapper"
assert_eq '1' "$RUN_RC" 'no --sha argument fails'
assert_contains "$RUN_OUT" 'usage' 'no --sha argument prints usage'
assert_contains "$RUN_OUT" '--sha is required' 'no --sha argument names the missing flag'

# --- build a synthetic repo shaped like this one -------------------------
synth=$tmp/synth
mkdir -p "$synth/bench/results" "$synth/tests/lib"
cp "$real_tier0" "$synth/bench/tier0.sh"
chmod +x "$synth/bench/tier0.sh"
cp "$real_estimator" "$synth/tests/lib/token-estimate.sh"
cp "$real_wrapper" "$synth/tests/ci-record-tier0.sh"
chmod +x "$synth/tests/ci-record-tier0.sh"

git -C "$synth" init --quiet --initial-branch=main
git -C "$synth" config user.email test@example.invalid
git -C "$synth" config user.name 'Test'
git -C "$synth" add -A
git -C "$synth" commit --quiet -m 'initial'
sha1=$(git -C "$synth" rev-parse HEAD)

echo more > "$synth/README-fixture"
git -C "$synth" add -A
git -C "$synth" commit --quiet -m 'second'
sha2=$(git -C "$synth" rev-parse HEAD)

ledger="$synth/bench/results/tier0.jsonl"

# --- an unresolvable SHA fails, never touches the ledger -----------------
run_wrapper "$synth/tests/ci-record-tier0.sh" --sha not-a-real-sha-xyz
assert_eq '1' "$RUN_RC" 'an unresolvable SHA fails'
assert_contains "$RUN_OUT" 'not present in this checkout' 'the unresolvable-SHA error names the problem'
assert_eq 'no' "$([[ -f $ledger ]] && echo yes || echo no)" 'an unresolvable SHA never creates the ledger'

# --- local (no --push) recording is idempotent ----------------------------
run_wrapper "$synth/tests/ci-record-tier0.sh" --sha "$sha1"
assert_eq '0' "$RUN_RC" 'recording sha1 succeeds'
lines_after_first=$(wc -l < "$ledger" | tr -d ' ')
assert_eq '1' "$lines_after_first" 'sha1 appends exactly one ledger line'

first_line=$(cat "$ledger")

run_wrapper "$synth/tests/ci-record-tier0.sh" --sha "$sha1"
assert_eq '0' "$RUN_RC" 're-recording sha1 succeeds (no-op)'
assert_contains "$RUN_OUT" 'already recorded' 're-recording sha1 reports it as already recorded'
lines_after_second=$(wc -l < "$ledger" | tr -d ' ')
assert_eq '1' "$lines_after_second" 're-recording sha1 does not append a second line'
assert_eq "$first_line" "$(cat "$ledger")" 're-recording sha1 leaves the existing line byte-identical'

# recording a genuinely different SHA still appends its own line.
run_wrapper "$synth/tests/ci-record-tier0.sh" --sha "$sha2"
assert_eq '0' "$RUN_RC" 'recording sha2 succeeds'
lines_after_third=$(wc -l < "$ledger" | tr -d ' ')
assert_eq '2' "$lines_after_third" 'sha2 appends its own, second ledger line'
assert_eq "$first_line" "$(sed -n '1p' "$ledger")" "sha1's line is unchanged after sha2 is recorded"

distinct_shas=$(jq -r '.plugin_sha' "$ledger" | sort -u | wc -l | tr -d ' ')
assert_eq '2' "$distinct_shas" 'the ledger holds exactly one record per distinct SHA measured'

# --- --push round-trips through a real remote, still idempotent ----------
remote_bare=$tmp/remote.git
git init --quiet --bare --initial-branch=main "$remote_bare"

push_repo=$tmp/push-repo
mkdir -p "$push_repo/bench/results" "$push_repo/tests/lib"
cp "$real_tier0" "$push_repo/bench/tier0.sh"
chmod +x "$push_repo/bench/tier0.sh"
cp "$real_estimator" "$push_repo/tests/lib/token-estimate.sh"
cp "$real_wrapper" "$push_repo/tests/ci-record-tier0.sh"
chmod +x "$push_repo/tests/ci-record-tier0.sh"

git -C "$push_repo" init --quiet --initial-branch=main
git -C "$push_repo" config user.email test@example.invalid
git -C "$push_repo" config user.name 'Test'
git -C "$push_repo" remote add origin "$remote_bare"
git -C "$push_repo" add -A
git -C "$push_repo" commit --quiet -m 'initial'
git -C "$push_repo" push --quiet origin main
merge_sha=$(git -C "$push_repo" rev-parse HEAD)

run_wrapper "$push_repo/tests/ci-record-tier0.sh" --sha "$merge_sha" --push
assert_eq '0' "$RUN_RC" '--push records and pushes the merge SHA'
assert_contains "$RUN_OUT" 'pushed tier0 record' '--push reports the push'

remote_head_after_first=$(git -C "$remote_bare" rev-parse main)

# a second run against a stale local checkout (still pointed at the
# pre-push commit) must fetch, see the record is already there, and not
# push a second commit -- the scenario a manual workflow re-run produces.
run_wrapper "$push_repo/tests/ci-record-tier0.sh" --sha "$merge_sha" --push
assert_eq '0' "$RUN_RC" 're-running --push for the same merge SHA succeeds (no-op)'
assert_contains "$RUN_OUT" 'already recorded' 're-running --push reports the SHA as already recorded'
remote_head_after_second=$(git -C "$remote_bare" rev-parse main)
assert_eq "$remote_head_after_first" "$remote_head_after_second" \
    're-running --push does not add a second commit to the remote'

remote_ledger_lines=$(git -C "$remote_bare" show main:bench/results/tier0.jsonl | wc -l | tr -d ' ')
assert_eq '1' "$remote_ledger_lines" 'the pushed remote ledger holds exactly one record for the one merge'

# --- CI wiring: record-tier0.yml is its own workflow (not a job living ----
# --- inside ci.yml's cancelling concurrency group), triggered on green ----
# --- CI completion, with NO concurrency group of its own and NO ----------
# --- commit-message guard -- the anti-recursion mechanism is structural ---
#
# This job MUST NOT live inside ci.yml: ci.yml's own workflow-level
# concurrency group (`ci-${{ github.ref }}`, cancel-in-progress: true)
# cancels an entire in-progress run -- including every job in it -- the
# moment a newer push lands on the same ref, and a job-level concurrency
# setting cannot exempt a job from that run-level cancellation. A merge's
# Tier-0 recording living as a job inside ci.yml would therefore be
# silently dropped whenever a second merge lands before the first
# finishes, defeating "exactly one record per merge". Splitting it into a
# separate workflow file removes it from that group entirely.
ci_text=$(cat -- "$repo_root/.github/workflows/ci.yml")
assert_not_contains "$ci_text" 'record-tier0' \
    "ci.yml itself does not declare the record-tier0 job (it would inherit ci.yml's cancelling concurrency group)"

record_text=$(cat -- "$repo_root/.github/workflows/record-tier0.yml")
assert_contains "$record_text" 'record-tier0:' 'record-tier0.yml declares the record-tier0 job'
assert_contains "$record_text" "tests/ci-record-tier0.sh --sha" 'record-tier0.yml invokes the wrapper script'
assert_contains "$record_text" '--push' 'record-tier0.yml runs the wrapper with --push'
assert_contains "$record_text" 'workflow_run:' \
    'record-tier0 triggers on workflow_run, never directly on push'
assert_contains "$record_text" 'workflows: [CI]' \
    "record-tier0 triggers off CI's completion"
assert_contains "$record_text" "github.event.workflow_run.conclusion == 'success'" \
    'record-tier0 only records a merge whose own CI run finished green'
assert_contains "$record_text" 'contents: write' \
    'record-tier0 carries the write permission the push needs'

# A concurrency group only ever retains at most one PENDING run: queuing a
# new run cancels any run already pending in that group, so a group here
# would silently drop a merge's record under a burst of completions. This
# workflow must not declare one of its own.
assert_not_contains "$record_text" 'concurrency:' \
    'record-tier0 declares no concurrency group of its own (one would cancel a pending run and drop a record)'

# The startsWith commit-message guard is forgeable: a merge/squash commit
# that happens to start with the same text as the wrapper's commit message
# would silently suppress recording, with no warning. It must be gone.
assert_not_contains "$record_text" 'startsWith(github.event.workflow_run.head_commit.message' \
    'record-tier0 does not gate on commit-message text (forgeable by any merge/squash commit)'

# the wrapper's own commit message carries the actual anti-recursion
# mechanism -- [skip ci] stops ci.yml from ever creating a CI run for that
# push, so no workflow_run completion event is ever generated for it.
wrapper_prefix=$(grep -m1 "printf 'chore(bench): record tier0 for %s" "$real_wrapper" || true)
assert_contains "$wrapper_prefix" '[skip ci]' \
    "the wrapper's own commit message carries [skip ci] so its push never triggers a CI run"

# --- race regression (finding 2): two stale checkouts recording the same --
# --- SHA must never both push a row --------------------------------------
# Two independent clones taken before either has recorded anything (the
# shape of two overlapping runs -- e.g. a workflow re-run racing the
# original run) both try to record the SAME merge SHA. The fix is the
# fetch+hard-reset the wrapper performs immediately before its idempotency
# check on every --push attempt: whichever clone pushes second must see the
# first clone's row once it re-syncs, and skip instead of duplicating.
race_remote=$tmp/race-remote.git
git init --quiet --bare --initial-branch=main "$race_remote"

race_seed=$tmp/race-seed
mkdir -p "$race_seed/bench/results" "$race_seed/tests/lib"
cp "$real_tier0" "$race_seed/bench/tier0.sh"
chmod +x "$race_seed/bench/tier0.sh"
cp "$real_estimator" "$race_seed/tests/lib/token-estimate.sh"
cp "$real_wrapper" "$race_seed/tests/ci-record-tier0.sh"
chmod +x "$race_seed/tests/ci-record-tier0.sh"
git -C "$race_seed" init --quiet --initial-branch=main
git -C "$race_seed" config user.email test@example.invalid
git -C "$race_seed" config user.name 'Test'
git -C "$race_seed" remote add origin "$race_remote"
git -C "$race_seed" add -A
git -C "$race_seed" commit --quiet -m 'initial'
git -C "$race_seed" push --quiet origin main
race_sha=$(git -C "$race_seed" rev-parse HEAD)

worker_a=$tmp/race-worker-a
worker_b=$tmp/race-worker-b
git clone --quiet "$race_remote" "$worker_a"
git clone --quiet "$race_remote" "$worker_b"
git -C "$worker_a" config user.email test@example.invalid
git -C "$worker_a" config user.name 'Test'
git -C "$worker_b" config user.email test@example.invalid
git -C "$worker_b" config user.name 'Test'

out_a=$tmp/race-a.out
out_b=$tmp/race-b.out
rc_a_file=$tmp/race-a.rc
rc_b_file=$tmp/race-b.rc
(
    "$worker_a/tests/ci-record-tier0.sh" --sha "$race_sha" --push > "$out_a" 2>&1
    echo $? > "$rc_a_file"
) &
pid_a=$!
(
    "$worker_b/tests/ci-record-tier0.sh" --sha "$race_sha" --push > "$out_b" 2>&1
    echo $? > "$rc_b_file"
) &
pid_b=$!
wait "$pid_a"
wait "$pid_b"
rc_a=$(cat "$rc_a_file")
rc_b=$(cat "$rc_b_file")

assert_eq '0' "$rc_a" 'racing worker A exits 0'
assert_eq '0' "$rc_b" 'racing worker B exits 0'

race_ledger_lines=$(git -C "$race_remote" show main:bench/results/tier0.jsonl | wc -l | tr -d ' ')
assert_eq '1' "$race_ledger_lines" \
    'two racing --push runs for the same merge SHA leave exactly one ledger row, never two'

race_commit_count=$(git -C "$race_remote" log --oneline main -- bench/results/tier0.jsonl | wc -l | tr -d ' ')
assert_eq '1' "$race_commit_count" \
    'exactly one of the two racing runs actually pushed a recording commit'

# --- record-tier0.yml declares the ledger-only-commit backstop -----------
# The [skip ci] mechanism in the wrapper's own commit message is the
# primary anti-recursion guard; this step is the defence-in-depth backstop
# that does not depend on it surviving future edits.
assert_contains "$record_text" 'Skip ledger-only commits' \
    'record-tier0.yml declares the ledger-only-commit guard step'
assert_contains "$record_text" 'git diff-tree' \
    'record-tier0.yml uses git diff-tree to detect a ledger-only commit'
assert_contains "$record_text" '--first-parent -m' \
    'record-tier0.yml diffs merge commits against their first parent (plain diff-tree on a merge prints nothing)'

# --- the guard's actual git diff-tree invocation: ledger-only vs. merge --
# Reproduce exactly the command the workflow step runs
# (`git diff-tree --no-commit-id --name-only -r --first-parent -m <sha>`)
# against a synthetic repo shaped like both cases it must tell apart:
#  - a commit whose entire diff is bench/results/tier0.jsonl (must be
#    detected as ledger-only and skipped);
#  - an ordinary two-parent merge commit that touches other files (must
#    NOT be mistaken for ledger-only just because a bare `diff-tree`
#    without -m/--first-parent would print nothing for it).
guard_repo=$tmp/guard-repo
mkdir -p "$guard_repo"
git -C "$guard_repo" init --quiet --initial-branch=main
git -C "$guard_repo" config user.email test@example.invalid
git -C "$guard_repo" config user.name 'Test'

echo base > "$guard_repo/base.txt"
git -C "$guard_repo" add -A
git -C "$guard_repo" commit --quiet -m 'initial'

# A ledger-only commit on main.
mkdir -p "$guard_repo/bench/results"
echo '{"plugin_sha":"deadbeef"}' > "$guard_repo/bench/results/tier0.jsonl"
git -C "$guard_repo" add -A
git -C "$guard_repo" commit --quiet -m 'chore(bench): record tier0 for deadbeef [skip ci]'
ledger_only_sha=$(git -C "$guard_repo" rev-parse HEAD)

guard_changed() {
    git -C "$guard_repo" diff-tree --no-commit-id --name-only -r --first-parent -m "$1"
}

ledger_only_changed=$(guard_changed "$ledger_only_sha")
assert_eq 'bench/results/tier0.jsonl' "$ledger_only_changed" \
    'a ledger-only commit diffs to exactly the ledger path'

# A genuine merge commit: branch off before the ledger-only commit, add an
# unrelated file on a side branch, and merge it into main. This is the
# shape a bare `git diff-tree --no-commit-id --name-only -r <sha>` (no -m,
# no --first-parent) prints NOTHING for -- the exact footgun the guard
# must not fall into.
git -C "$guard_repo" checkout --quiet -b side "$(git -C "$guard_repo" rev-parse HEAD~1)"
echo feature > "$guard_repo/feature.txt"
git -C "$guard_repo" add -A
git -C "$guard_repo" commit --quiet -m 'side work'
git -C "$guard_repo" checkout --quiet main
git -C "$guard_repo" merge --quiet --no-ff side -m 'merge side into main'
merge_commit_sha=$(git -C "$guard_repo" rev-parse HEAD)

bare_diff_tree_output=$(git -C "$guard_repo" diff-tree --no-commit-id --name-only -r "$merge_commit_sha")
assert_eq '' "$bare_diff_tree_output" \
    'sanity check: a bare diff-tree with no -m/--first-parent prints nothing for a merge commit (the footgun the guard avoids)'

merge_changed=$(guard_changed "$merge_commit_sha")
assert_contains "$merge_changed" 'feature.txt' \
    'the --first-parent -m guard invocation correctly reports the merge commit changed files'
assert_eq 'no' "$([[ "$merge_changed" == 'bench/results/tier0.jsonl' ]] && echo yes || echo no)" \
    'an ordinary merge commit is never mistaken for a ledger-only commit and skipped'

finish
