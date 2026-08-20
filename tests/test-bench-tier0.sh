#!/usr/bin/env bash
# Suite: bench/tier0.sh -- static resident/reachable/dispatched-template
# accounting and its append-only results ledger.
#
# Runs against two kinds of fixtures:
#  - a synthetic, throwaway git repo shaped like this one (bench/, tests/lib/,
#    agentkit/skills/), so byte counts are exactly known and independent of
#    however this repo's real skill tree grows over time;
#  - the two real, already-merged commits (06d18cf, 53e7e8c) issue #323's
#    acceptance criteria pin, to prove the script reproduces the epic's
#    published numbers against actual history, not just a fixture.
set -uo pipefail

TEST_NAME='bench tier0'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

real_tier0="$repo_root/bench/tier0.sh"
real_estimator="$repo_root/tests/lib/token-estimate.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

RUN_RC=0
RUN_OUT=''
run_tier0() {
    RUN_RC=0
    RUN_OUT=$("$@" 2>&1) || RUN_RC=$?
}

# --- estimator is shared, not copied ------------------------------------
# Both callers source the one file; grep counts of the divisor constant
# across the repo prove there is exactly one definition for the two of them
# to (potentially) disagree about.
estimator_present=absent
[[ -f $real_estimator ]] && estimator_present=present
assert_eq 'present' "$estimator_present" 'tests/lib/token-estimate.sh exists'

lint_sources=$(grep -c 'source .*lib/token-estimate\.sh' "$repo_root/tests/lint-skill-size.sh" || true)
assert_eq '1' "$lint_sources" 'lint-skill-size.sh sources the shared estimator'

tier0_sources=$(grep -c 'source .*lib/token-estimate\.sh' "$real_tier0" || true)
assert_eq '1' "$tier0_sources" 'bench/tier0.sh sources the shared estimator'

constant_defs=$(grep -rl '^readonly TOKEN_ESTIMATE_BYTES_PER_TOKEN=' "$repo_root/tests" "$repo_root/bench" 2> /dev/null | wc -l | tr -d ' ')
assert_eq '1' "$constant_defs" 'the bytes-per-token constant is defined exactly once in the repo'

# --- usage / argument validation ----------------------------------------
run_tier0 "$real_tier0"
assert_eq '2' "$RUN_RC" 'no REF argument exits 2'
assert_contains "$RUN_OUT" 'usage' 'no REF argument prints usage'

# F2: an unresolvable ref must fail immediately with a named, diagnosable
# error -- not cascade into a missing ledger file and a downstream jq/awk
# crash three steps later (the exact failure mode a shallow CI checkout hit
# against 06d18cf/53e7e8c: see the repro block below).
run_tier0 "$real_tier0" 'not-a-real-ref-xyz'
assert_eq '1' "$RUN_RC" 'an unresolvable ref fails'
assert_contains "$RUN_OUT" 'not present in this checkout' 'an unresolvable ref names the problem'
assert_contains "$RUN_OUT" 'not-a-real-ref-xyz' 'the error names the actual ref, not a generic message'
assert_contains "$RUN_OUT" 'shallow' 'the error suggests a shallow clone as the likely cause'

run_tier0 "$real_tier0" HEAD --fixture-version ''
assert_eq '1' "$RUN_RC" 'an empty --fixture-version fails'

# --- synthetic repo: exact byte accounting -------------------------------
synth=$tmp/synth
mkdir -p "$synth/bench" "$synth/tests/lib" \
    "$synth/agentkit/skills/alpha" \
    "$synth/agentkit/skills/alpha/references" \
    "$synth/agentkit/skills/.shared" \
    "$synth/agentkit/skills/parallel-issues/references"

cp "$real_tier0" "$synth/bench/tier0.sh"
chmod +x "$synth/bench/tier0.sh"
cp "$real_estimator" "$synth/tests/lib/token-estimate.sh"

# byte counts chosen to divide cleanly by 4 so token math is exact, not just
# floor-rounded, and to differ across files so a summing bug (e.g. counting
# one file twice, or missing one) shows up as a wrong total rather than a
# coincidentally-right one.
printf -- '---\nname: alpha\ndescription: Use when testing.\n---\n%s\n' "$(head -c 96 /dev/zero | tr '\0' a)" \
    > "$synth/agentkit/skills/alpha/SKILL.md" # 100 body bytes after frontmatter, but whole-file size is what's summed
printf '%s\n' "$(head -c 199 /dev/zero | tr '\0' b)" > "$synth/agentkit/skills/alpha/references/ref.md"
printf '%s\n' "$(head -c 79 /dev/zero | tr '\0' c)" > "$synth/agentkit/skills/.shared/policy.md"
printf '%s\n' "$(head -c 39 /dev/zero | tr '\0' d)" > "$synth/agentkit/skills/parallel-issues/references/worker-prompts.md"
# a non-.md file under skills/ must never contribute to either surface
printf '%s\n' "should never be counted" > "$synth/agentkit/skills/alpha/notes.txt"

# F1 regression: a skill directory whose name contains a tab. `git ls-tree`
# without -z C-quotes a path like this (e.g. as "a\tb/SKILL.md"), which
# breaks both a naive grep match and a naive `git cat-file` lookup against
# the quoted display form. sum_bytes_matching must count it exactly like any
# other skill.
tab_dir="$synth/agentkit/skills/$(printf 'weird\tname')"
mkdir -p "$tab_dir"
printf -- '---\nname: weird\ndescription: Use when the path itself is adversarial.\n---\n%s\n' \
    "$(head -c 19 /dev/zero | tr '\0' e)" > "$tab_dir/SKILL.md"

skill_bytes=$(wc -c < "$synth/agentkit/skills/alpha/SKILL.md")
ref_bytes=$(wc -c < "$synth/agentkit/skills/alpha/references/ref.md")
shared_bytes=$(wc -c < "$synth/agentkit/skills/.shared/policy.md")
dispatch_bytes=$(wc -c < "$synth/agentkit/skills/parallel-issues/references/worker-prompts.md")
tab_skill_bytes=$(wc -c < "$tab_dir/SKILL.md")

expect_resident=$((skill_bytes + tab_skill_bytes))
expect_reachable=$((skill_bytes + ref_bytes + shared_bytes + dispatch_bytes + tab_skill_bytes))

git -C "$synth" init -q
git -C "$synth" -c user.email=t@example.com -c user.name=t add -A
git -C "$synth" -c user.email=t@example.com -c user.name=t commit -q -m 'synthetic fixture v1'
sha1=$(git -C "$synth" rev-parse HEAD)

ledger="$synth/bench/results/tier0.jsonl"
run_tier0 "$synth/bench/tier0.sh" "$sha1" --ledger "$ledger" --timestamp 2026-01-01T00:00:00Z
assert_eq '0' "$RUN_RC" 'tier0.sh succeeds against the synthetic fixture'

record1=$(tail -n 1 "$ledger")
got_resident=$(jq -r '.resident.bytes' <<< "$record1")
got_reachable=$(jq -r '.reachable.bytes' <<< "$record1")
got_dispatch_present=$(jq -r '.dispatched_template.present' <<< "$record1")
got_dispatch_bytes=$(jq -r '.dispatched_template.bytes' <<< "$record1")
got_key=$(jq -r '[.plugin_sha, .fixture_version, .model, .effort] | @tsv' <<< "$record1")

assert_eq "$expect_resident" "$got_resident" \
    'resident bytes = every SKILL.md (including the tab-path one), whole-file'
assert_eq "$expect_reachable" "$got_reachable" \
    'reachable bytes = every *.md under skills/ (including the tab-path one), non-md excluded'
assert_eq 'true' "$got_dispatch_present" 'dispatched_template is present when the file exists at the SHA'
assert_eq "$dispatch_bytes" "$got_dispatch_bytes" 'dispatched_template bytes match the template file exactly'
assert_eq "$(printf '%s\ttier0-v1\tstatic-accounting\tn/a' "$sha1")" "$got_key" \
    'ledger key is (plugin_sha, fixture_version, model, effort) with the Tier-0 sentinel'

resident_tokens=$(jq -r '.resident.tokens' <<< "$record1")
assert_eq "$((expect_resident / 4))" "$resident_tokens" 'resident tokens = bytes/4 via the shared estimator'

# --- dispatched_template absent before the file exists -------------------
rm "$synth/agentkit/skills/parallel-issues/references/worker-prompts.md"
git -C "$synth" -c user.email=t@example.com -c user.name=t add -A
git -C "$synth" -c user.email=t@example.com -c user.name=t commit -q -m 'drop the template (pre-dispatch-surface history)'
sha0=$(git -C "$synth" rev-parse HEAD)

run_tier0 "$synth/bench/tier0.sh" "$sha0" --ledger "$ledger" --timestamp 2026-01-01T00:00:01Z
assert_eq '0' "$RUN_RC" 'tier0.sh succeeds when the template file is absent at the SHA'
record2=$(tail -n 1 "$ledger")
assert_eq 'false' "$(jq -r '.dispatched_template.present' <<< "$record2")" \
    'dispatched_template.present is false, not omitted, before the file existed'
assert_eq '0' "$(jq -r '.dispatched_template.bytes' <<< "$record2")" \
    'dispatched_template.bytes reads 0 rather than null when absent'

# --- append-only: growth, never rewrite ----------------------------------
lines_after_two=$(wc -l < "$ledger")
assert_eq '2' "$lines_after_two" 'the ledger has exactly one line per invocation so far'
assert_eq "$record1" "$(sed -n '1p' "$ledger")" 'the first record is untouched by the second invocation'

run_tier0 "$synth/bench/tier0.sh" "$sha1" --ledger "$ledger" --timestamp 2026-01-01T00:00:02Z
assert_eq '0' "$RUN_RC" 'a third invocation succeeds'
lines_after_three=$(wc -l < "$ledger")
assert_eq '3' "$lines_after_three" 'a third invocation strictly grows the ledger'
assert_eq "$record1" "$(sed -n '1p' "$ledger")" 'line 1 is still byte-identical after a third invocation'
assert_eq "$record2" "$(sed -n '2p' "$ledger")" 'line 2 is still byte-identical after a third invocation'

# F2: (plugin_sha, fixture_version, model, effort) is a grouping/comparison
# key, not a uniqueness constraint -- re-measuring the same SHA is a normal
# operation the ledger writer never rejects (see bench/README). The third
# invocation above re-measured sha1, so line 3 must carry the SAME key as
# line 1 while being a genuinely distinct row (different measured_at).
record3=$(sed -n '3p' "$ledger")
got_key3=$(jq -r '[.plugin_sha, .fixture_version, .model, .effort] | @tsv' <<< "$record3")
assert_eq "$got_key" "$got_key3" \
    're-measuring the same SHA appends a row with the identical grouping key'
assert_eq '2026-01-01T00:00:02Z' "$(jq -r '.measured_at' <<< "$record3")" \
    'the duplicate-key row is still a distinct, individually-dated measurement'

# --- refuses to append through a symlink ----------------------------------
symlinked_ledger="$synth/bench/results/via-symlink.jsonl"
ln -s "$ledger" "$symlinked_ledger"
run_tier0 "$synth/bench/tier0.sh" "$sha1" --ledger "$symlinked_ledger" --timestamp 2026-01-01T00:00:03Z
assert_eq '1' "$RUN_RC" 'appending through a symlinked ledger path is refused'
assert_contains "$RUN_OUT" 'symlink' 'the symlink refusal names the reason'

# --- reproduces the epic's real-history numbers ---------------------------
# 06d18cf / 53e7e8c are real, already-merged commits in THIS repository's
# history (the compression refactor issue #323 cites): no fixture, no
# network, just this repo's own git objects.
# This reproduction needs both arm SHAs actually present in the checkout's
# git history -- a shallow clone (fetch-depth: 1, GitHub Actions' checkout
# default) does not have them. Each run is asserted on its own line so a
# missing-history failure names itself (F2's error, asserted above) instead
# of surfacing three steps later as a jq "could not open file" or an awk
# "division by zero". If either arm SHA did not resolve, the numeric
# comparisons below are reported as explicit failures -- never silently
# skipped -- because a passing suite that quietly didn't check the epic's
# headline reproduction is worse than a loud one that says so.
repro_ledger=$tmp/repro-tier0.jsonl
run_tier0 "$real_tier0" 06d18cf --ledger "$repro_ledger" --timestamp 2026-01-01T00:00:00Z
before_rc=$RUN_RC before_out=$RUN_OUT
assert_eq '0' "$before_rc" '06d18cf resolves and measures cleanly'

run_tier0 "$real_tier0" 53e7e8c --ledger "$repro_ledger" --timestamp 2026-01-01T00:00:01Z
after_rc=$RUN_RC after_out=$RUN_OUT
assert_eq '0' "$after_rc" '53e7e8c resolves and measures cleanly'

if [[ $before_rc -eq 0 && $after_rc -eq 0 ]]; then
    before_resident=$(jq -r 'select(.plugin_sha | startswith("06d18cf")) | .resident.tokens' "$repro_ledger")
    after_resident=$(jq -r 'select(.plugin_sha | startswith("53e7e8c")) | .resident.tokens' "$repro_ledger")
    before_reachable=$(jq -r 'select(.plugin_sha | startswith("06d18cf")) | .reachable.tokens' "$repro_ledger")
    after_reachable=$(jq -r 'select(.plugin_sha | startswith("53e7e8c")) | .reachable.tokens' "$repro_ledger")

    # Compare with one decimal digit of precision using awk (no bc
    # dependency) -- the epic's published table is -59.4% resident / -8.9%
    # reachable "within rounding".
    resident_pct=$(awk -v b="$before_resident" -v a="$after_resident" 'BEGIN { printf "%.1f", (b - a) / b * 100 }')
    reachable_pct=$(awk -v b="$before_reachable" -v a="$after_reachable" 'BEGIN { printf "%.1f", (b - a) / b * 100 }')
    assert_eq '59.4' "$resident_pct" 'resident dropped 59.4% between 06d18cf and 53e7e8c, matching the epic table'
    assert_eq '8.9' "$reachable_pct" 'reachable dropped 8.9% between 06d18cf and 53e7e8c, matching the epic table'

    before_dispatch_present=$(jq -r 'select(.plugin_sha | startswith("06d18cf")) | .dispatched_template.present' "$repro_ledger")
    after_dispatch_present=$(jq -r 'select(.plugin_sha | startswith("53e7e8c")) | .dispatched_template.present' "$repro_ledger")
    assert_eq 'false' "$before_dispatch_present" 'worker-prompts.md did not exist yet at 06d18cf'
    assert_eq 'true' "$after_dispatch_present" 'worker-prompts.md exists at 53e7e8c'
else
    _fail 'resident dropped 59.4% between 06d18cf and 53e7e8c, matching the epic table' \
        'not measured: an arm SHA failed to resolve -- see the failing 06d18cf/53e7e8c assertions above' \
        "06d18cf rc=$before_rc: ${before_out:0:200}" "53e7e8c rc=$after_rc: ${after_out:0:200}"
    _fail 'reachable dropped 8.9% between 06d18cf and 53e7e8c, matching the epic table' \
        'not measured: an arm SHA failed to resolve -- see the failing 06d18cf/53e7e8c assertions above'
    _fail 'worker-prompts.md did not exist yet at 06d18cf' \
        'not measured: an arm SHA failed to resolve -- see the failing 06d18cf/53e7e8c assertions above'
    _fail 'worker-prompts.md exists at 53e7e8c' \
        'not measured: an arm SHA failed to resolve -- see the failing 06d18cf/53e7e8c assertions above'
fi

finish
