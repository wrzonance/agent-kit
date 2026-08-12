#!/usr/bin/env bash
# Regression suite for the resumable bulk-apply ledger.
set -uo pipefail

TEST_NAME='apply ledger'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

ledger_sh="$root/agentkit/skills/.shared/scripts/apply-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

plan="$tmp/plan.json"
ledger="$tmp/ledger.json"
batch_ledger="$tmp/batch-ledger.json"
cat >"$plan" <<'EOF'
{
  "planId": "fixture-batch-v1",
  "entries": [
    {"id": "alpha", "title": "first"},
    {"id": "bravo", "title": "second"},
    {"id": "charlie", "title": "third"}
  ]
}
EOF

run_ledger() {
    "$ledger_sh" "$@"
}

assert_rc 0 'init creates a ledger' -- run_ledger init --ledger "$ledger" --plan "$plan"
assert_eq '1' "$(jq -r '.schemaVersion' <"$ledger")" 'ledger schema is version 1'
assert_eq 'fixture-batch-v1' "$(jq -r '.planId' <"$ledger")" 'ledger retains the planning id'
assert_eq '3' "$(jq '.remaining | length' <"$ledger")" 'all plan entries start remaining'
assert_eq '0' "$(jq '.applied | length' <"$ledger")" 'nothing is applied at init'

assert_rc 0 'recording a successful mutation works' -- run_ledger record \
    --ledger "$ledger" --id alpha --number 101 --url https://github.com/example/repo/issues/101
assert_eq '101' "$(jq -r '.idMap.alpha.number' <"$ledger")" 'record stores the created number'
assert_eq 'https://github.com/example/repo/issues/101' \
    "$(jq -r '.idMap.alpha.url' <"$ledger")" 'record stores the created URL'
assert_eq '2' "$(jq '.remaining | length' <"$ledger")" 'record removes the id from remaining'
assert_eq '1' "$(jq '.applied | length' <"$ledger")" 'record appends one applied entry'

before_duplicate=$(<"$ledger")
assert_rc 0 'recording an applied id is an idempotent no-op' -- run_ledger record \
    --ledger "$ledger" --id alpha --number 101 --url https://github.com/example/repo/issues/101
assert_eq "$before_duplicate" "$(<"$ledger")" 'duplicate recording does not rewrite ledger state'
assert_rc 1 'an unknown planning id is rejected' -- run_ledger record \
    --ledger "$ledger" --id missing --number 999 --url https://github.com/example/repo/issues/999

assert_eq '["bravo","charlie"]' "$(run_ledger pending --ledger "$ledger" --json | jq -c '.remaining')" \
    'pending exposes a machine-readable follow-on split'
assert_eq '2' "$(run_ledger status --ledger "$ledger" | jq '.remaining | length')" \
    'status reports remaining evidence as JSON'

# Interrupted fixture batch: the first invocation mutates only alpha and exits;
# the resumed invocation sees only bravo/charlie and therefore creates no duplicate.
mutations="$tmp/mutations.log"
run_ledger init --ledger "$batch_ledger" --plan "$plan" >/dev/null
run_fixture_batch() {
    local stop_after=$1 id number
    while IFS= read -r id; do
        number=$((100 + $(printf '%s' "$id" | od -An -tuC | awk '{print $1}')))
        printf '%s\n' "$id" >>"$mutations"
        run_ledger record --ledger "$batch_ledger" --id "$id" --number "$number" \
            --url "https://github.com/example/repo/issues/$number" >/dev/null
        ((stop_after--)) || return 0
    done < <(run_ledger pending --ledger "$batch_ledger" --ids)
}

run_fixture_batch 1
run_fixture_batch 10
assert_eq '3' "$(wc -l <"$mutations" | tr -d ' ')" 'resumed fixture creates each item once'
assert_eq 'alpha' "$(sed -n '1p' "$mutations")" 'first invocation records alpha'
assert_eq 'bravo' "$(sed -n '2p' "$mutations")" 'resume starts at bravo'
assert_eq 'charlie' "$(sed -n '3p' "$mutations")" 'resume finishes at charlie'
assert_eq '0' "$(jq '.remaining | length' <"$batch_ledger")" 'completed rerun leaves no remaining ids'
assert_eq '3' "$(jq '.idMap | length' <"$batch_ledger")" 'completed rerun has a complete follow-on id map'

finish
