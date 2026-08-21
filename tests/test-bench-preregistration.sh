#!/usr/bin/env bash
# Suite: bench/PREREGISTRATION.md -- the token-benchmark epic's (#152) Tier-1
# decision rules, which the design (docs/superpowers/specs/
# 2026-08-13-token-benchmark-design.md, "Pre-registration") requires be
# committed before trial 1. Asserts the doc carries the six rules verbatim
# and that no Tier-1 record exists yet in the ledger -- the two facts that
# together make "pre-registration precedes trial 1" checkable rather than
# merely claimed.
set -uo pipefail

TEST_NAME='bench preregistration'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "$here/.." && pwd)
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

doc="$repo_root/bench/PREREGISTRATION.md"

# --- the document exists and is dated ------------------------------------
doc_present=absent
[[ -f $doc ]] && doc_present=present
assert_eq 'present' "$doc_present" 'bench/PREREGISTRATION.md exists'

if [[ $doc_present == present ]]; then
    contents=$(<"$doc")

    dated=$(grep -c '^Dated:' "$doc" || true)
    assert_eq '1' "$dated" 'the document is dated'

    # --- the six rules, verbatim from the issue body ----------------------
    assert_contains "$contents" 'Q1 verdict' 'names the Q1 verdict rule'
    assert_contains "$contents" 'resident token delta' 'Q1 verdict: resident token delta wording'
    assert_contains "$contents" '40%' 'Q1 verdict: >=40% threshold'
    assert_contains "$contents" '-59.4%' 'Q1 verdict: already-met figure'

    assert_contains "$contents" 'Dominance' 'names the Dominance rule'
    assert_contains "$contents" 'new@low' 'Dominance: new@low term'
    assert_contains "$contents" 'old@high' 'Dominance: old@high term'
    assert_contains "$contents" 'median acceptance' 'Dominance: median acceptance term'
    assert_contains "$contents" 'median blended USD' 'Dominance: median blended USD term'
    assert_contains "$contents" 'non-overlapping IQRs' 'Dominance: non-overlapping IQRs term'

    assert_contains "$contents" 'Reference siting' 'names the Reference siting rule'
    assert_contains "$contents" '90%' 'Reference siting: >=90% misfiled threshold'
    assert_contains "$contents" 'dead weight' 'Reference siting: 0% dead-weight term'
    assert_contains "$contents" 'lint-skill-size.sh' 'Reference siting: lint-skill-size.sh cross-reference'
    assert_contains "$contents" '900-line' 'Reference siting: 900-line design-floor figure'

    assert_contains "$contents" 'Void trials' 'names the Void trials rule'
    assert_contains "$contents" 'realised tier' 'Void trials: realised-tier term'
    assert_contains "$contents" 'model-id' 'Void trials: model-id drift term'
    assert_contains "$contents" 'void, never adjusted' 'Void trials: void-never-adjusted wording'

    assert_contains "$contents" 'Fixture fork' 'names the Fixture fork rule'
    assert_contains "$contents" 'bench/fixtures/' 'Fixture fork: bench/fixtures/ path'
    assert_contains "$contents" 'bench/issues/' 'Fixture fork: bench/issues/ path'
    assert_contains "$contents" 'bench/accept/' 'Fixture fork: bench/accept/ path'
    assert_contains "$contents" 'fixture_version' 'Fixture fork: fixture_version field'

    assert_contains "$contents" 'Drift normalisation' 'names the Drift normalisation rule'
    assert_contains "$contents" '06d18cf' 'Drift normalisation: frozen SHA'
    assert_contains "$contents" 'drift-control trial' 'Drift normalisation: drift-control trial term'
    assert_contains "$contents" 'excluded from trend claims' 'Drift normalisation: exclusion wording'
else
    _fail 'bench/PREREGISTRATION.md contents' 'file missing -- skipped content assertions'
fi

# --- no Tier-1 trial record exists yet in the ledger ----------------------
# fixture_version values are namespaced per tier (tier0-v1, tier1-v1, ...):
# a "tier1" record anywhere in the ledger glob would mean a real trial ran
# before this pre-registration document was committed.
shopt -s nullglob
ledger_files=("$repo_root"/bench/results/*.jsonl)
shopt -u nullglob

tier1_records=0
if ((${#ledger_files[@]} > 0)); then
    tier1_records=$(grep -h -o '"fixture_version":"tier1[^"]*"' "${ledger_files[@]}" 2> /dev/null | wc -l | tr -d ' ')
fi
assert_eq '0' "$tier1_records" 'bench/results/*.jsonl contains no Tier-1 records at merge time'

finish
