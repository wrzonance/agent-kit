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
# anti-self-trigger guard, and the dedicated non-cancelling concurrency
# group) is asserted directly against the checked-in workflow text, since
# exercising GitHub Actions triggers themselves is outside what a local
# suite can run.
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

# --- CI wiring: push-to-main trigger, anti-self-trigger guard, and a ------
# --- dedicated non-cancelling concurrency group ---------------------------
ci_text=$(cat -- "$repo_root/.github/workflows/ci.yml")
assert_contains "$ci_text" 'record-tier0:' 'ci.yml declares the record-tier0 job'
assert_contains "$ci_text" "tests/ci-record-tier0.sh --sha" 'ci.yml invokes the wrapper script'
assert_contains "$ci_text" '--push' 'ci.yml runs the wrapper with --push'
assert_contains "$ci_text" "github.event_name == 'push'" \
    'record-tier0 only runs on push events'
assert_contains "$ci_text" "github.ref == 'refs/heads/main'" \
    'record-tier0 is restricted to main'
assert_contains "$ci_text" "startsWith(github.event.head_commit.message, 'chore(bench): record tier0')" \
    "record-tier0 guards against re-triggering on its own commit's push"
assert_contains "$ci_text" 'cancel-in-progress: false' \
    'record-tier0 uses a non-cancelling concurrency group so a merge is never dropped mid-recording'
assert_contains "$ci_text" 'contents: write' \
    'record-tier0 is the job that carries the write permission the push needs'

# the commit-message marker the guard checks for must be exactly the prefix
# the wrapper script actually writes -- a drift here would silently defeat
# the anti-loop guard.
wrapper_prefix=$(grep -m1 "printf 'chore(bench): record tier0 for %s" "$real_wrapper" || true)
assert_contains "$wrapper_prefix" 'chore(bench): record tier0 for %s' \
    "the wrapper's own commit message starts with the guard's exact marker string"

finish
