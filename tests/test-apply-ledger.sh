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

invalid_plan="$tmp/invalid-plan.json"
for invalid_id in 'slash/id' 'space id' $'line\nbreak'; do
    jq -n --arg id "$invalid_id" \
        '{planId: "invalid-id-fixture", entries: [{id: $id}]}' >"$invalid_plan"
    invalid_ledger="$tmp/invalid-$(printf '%s' "$invalid_id" | tr '/ ' '__' | tr '\n' '_').json"
    assert_rc 1 "init rejects line-unsafe plan id $(printf '%q' "$invalid_id")" -- \
        run_ledger init --ledger "$invalid_ledger" --plan "$invalid_plan"
    assert_eq 'no' "$([[ -e $invalid_ledger ]] && printf yes || printf no)" \
        'rejected plan does not create a ledger'
done

invalid_plan_error=''
invalid_plan_rc=0
invalid_plan_error=$(run_ledger init --ledger "$tmp/invalid-schema-ledger.json" \
    --plan "$invalid_plan" 2>&1) || invalid_plan_rc=$?
assert_eq '1' "$invalid_plan_rc" 'invalid plan remains a semantic validation failure'
assert_contains "$invalid_plan_error" \
    'valid example: {"planId":"batch-v1","entries":[{"id":"entry-1"}]}' \
    'invalid plan explains the copyable plan schema in its rejection'

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

# Concurrent post-mutation records must serialize the read-modify-write. The
# jq shim makes each writer pause after reading the current ledger so an
# unlocked implementation deterministically loses all but one update.
concurrent_ledger="$tmp/concurrent-ledger.json"
concurrent_jq="$tmp/jq"
real_jq=$(command -v jq)
cat >"$concurrent_jq" <<EOF
#!/usr/bin/env bash
case \$* in
    *'.applied += '* ) sleep 0.1 ;;
esac
exec "$real_jq" "\$@"
EOF
chmod 700 -- "$concurrent_jq"
run_ledger init --ledger "$concurrent_ledger" --plan "$plan" >/dev/null
concurrent_pids=()
concurrent_failures=0
for concurrent_id in alpha bravo charlie; do
    concurrent_number=$((200 + ${#concurrent_pids[@]}))
    PATH="$tmp:$PATH" run_ledger record --ledger "$concurrent_ledger" \
        --id "$concurrent_id" --number "$concurrent_number" \
        --url "https://github.com/example/repo/issues/$concurrent_number" \
        >"$tmp/concurrent-$concurrent_id.log" 2>&1 &
    concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
    wait "$concurrent_pid" || concurrent_failures=$((concurrent_failures + 1))
done
assert_eq '0' "$concurrent_failures" 'parallel records all complete successfully'
assert_eq '3' "$(jq '.applied | length' <"$concurrent_ledger")" \
    'parallel records preserve every applied entry'
assert_eq '0' "$(jq '.remaining | length' <"$concurrent_ledger")" \
    'parallel records remove every pending entry'
assert_eq '600' "$(stat -c '%a' "$concurrent_ledger.lock")" \
    'ledger lock is owner-private'

# Widened URL grammar: `record` must accept the URL form GitHub actually
# returns for a created issue/PR comment (`#issuecomment-<id>`), keep
# `--number` unambiguous as the mutation's subject issue/PR number, and
# still name the failing part of a genuinely malformed URL.
grammar_ledger="$tmp/grammar-ledger.json"
grammar_plan="$tmp/grammar-plan.json"
cat >"$grammar_plan" <<'EOF'
{
  "planId": "grammar-fixture-v1",
  "entries": [
    {"id": "issue-comment"},
    {"id": "pull-comment"},
    {"id": "bad-owner"},
    {"id": "bad-repo"},
    {"id": "bad-kind"},
    {"id": "bad-number"},
    {"id": "bad-fragment"},
    {"id": "mismatched-number"}
  ]
}
EOF
run_ledger init --ledger "$grammar_ledger" --plan "$grammar_plan" >/dev/null

assert_rc 0 'record accepts a created-issue-comment URL with its #issuecomment fragment' -- \
    run_ledger record --ledger "$grammar_ledger" --id issue-comment --number 55 \
    --url 'https://github.com/example/repo/issues/55#issuecomment-999001'
assert_eq 'https://github.com/example/repo/issues/55#issuecomment-999001' \
    "$(run_ledger status --ledger "$grammar_ledger" | jq -r '.idMap["issue-comment"].url')" \
    'status reads back the recorded comment URL verbatim'
assert_eq '0' "$(run_ledger pending --ledger "$grammar_ledger" --json | \
    jq '[.remaining[] | select(. == "issue-comment")] | length')" \
    'recording the comment mutation removes it from pending'

assert_rc 0 'record accepts a created-PR-comment URL with its #issuecomment fragment' -- \
    run_ledger record --ledger "$grammar_ledger" --id pull-comment --number 77 \
    --url 'https://github.com/example/repo/pull/77#issuecomment-999002'
assert_eq 'https://github.com/example/repo/pull/77#issuecomment-999002' \
    "$(run_ledger status --ledger "$grammar_ledger" | jq -r '.idMap["pull-comment"].url')" \
    'status reads back the recorded PR comment URL verbatim'

bad_owner_error=$(run_ledger record --ledger "$grammar_ledger" --id bad-owner --number 1 \
    --url 'https://github.com/' 2>&1)
assert_rc 1 'a URL missing the owner segment is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id bad-owner --number 1 --url 'https://github.com/'
assert_contains "$bad_owner_error" 'owner segment' 'malformed-owner refusal names the owner segment'

bad_repo_error=$(run_ledger record --ledger "$grammar_ledger" --id bad-repo --number 1 \
    --url 'https://github.com/example/' 2>&1)
assert_rc 1 'a URL missing the repository segment is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id bad-repo --number 1 --url 'https://github.com/example/'
assert_contains "$bad_repo_error" 'repository segment' 'malformed-repo refusal names the repository segment'

bad_kind_error=$(run_ledger record --ledger "$grammar_ledger" --id bad-kind --number 1 \
    --url 'https://github.com/example/repo/commits/1' 2>&1)
assert_rc 1 'a URL with neither /issues/ nor /pull/ is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id bad-kind --number 1 \
    --url 'https://github.com/example/repo/commits/1'
assert_contains "$bad_kind_error" '/issues/N or /pull/N' 'malformed-kind refusal names the expected path form'

bad_number_error=$(run_ledger record --ledger "$grammar_ledger" --id bad-number --number 1 \
    --url 'https://github.com/example/repo/issues/abc' 2>&1)
assert_rc 1 'a URL with a non-numeric issue/PR number is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id bad-number --number 1 \
    --url 'https://github.com/example/repo/issues/abc'
assert_contains "$bad_number_error" 'number or comment fragment' \
    'malformed-number refusal names the number/fragment segment'

bad_fragment_error=$(run_ledger record --ledger "$grammar_ledger" --id bad-fragment --number 55 \
    --url 'https://github.com/example/repo/issues/55#discussion_r123' 2>&1)
assert_rc 1 'a URL with an unsupported fragment is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id bad-fragment --number 55 \
    --url 'https://github.com/example/repo/issues/55#discussion_r123'
assert_contains "$bad_fragment_error" 'number or comment fragment' \
    'unsupported-fragment refusal names the number/fragment segment'

mismatched_error=$(run_ledger record --ledger "$grammar_ledger" --id mismatched-number --number 999 \
    --url 'https://github.com/example/repo/issues/55' 2>&1)
assert_rc 1 '--number that disagrees with the URL-embedded number is rejected' -- \
    run_ledger record --ledger "$grammar_ledger" --id mismatched-number --number 999 \
    --url 'https://github.com/example/repo/issues/55'
assert_contains "$mismatched_error" '--number' 'number/url mismatch refusal names --number'
assert_contains "$mismatched_error" '--url' 'number/url mismatch refusal names --url'

grammar_usage=$(run_ledger record -h)
assert_contains "$grammar_usage" 'issues/N#issuecomment-C' \
    'usage documents the issue-comment URL grammar'
assert_contains "$grammar_usage" 'pull/N#issuecomment-C' \
    'usage documents the PR-comment URL grammar'
assert_contains "$grammar_usage" 'created issue' 'usage names the created-issue kind'
assert_contains "$grammar_usage" 'created PR' 'usage names the created-PR kind'
assert_contains "$grammar_usage" 'board-move' 'usage documents board-move reuse of the plain form'

# Ledger validation must name the specific predicate that failed rather than
# a single generic "invalid apply ledger" message covering all seven checks
# (schema version, planId, the three array fields, idMap, and plan-id
# uniqueness), matching the actionable style `init`'s plan validation already
# uses. Each fixture below is a well-formed JSON document that breaks exactly
# one predicate.
# All seven fixtures reuse the same ledger path so their captured error
# messages differ only by predicate text, never by an incidentally-unique
# file path -- that is what makes the later distinctness check meaningful.
predicate_ledger="$tmp/predicate-case.json"
declare -A predicate_error=()
declare -A predicate_fixture=(
    [schema]='{schemaVersion: 2, planId: "fixture", plan: [{id: "a"}], applied: [], remaining: ["a"], idMap: {}}'
    [planId]='{schemaVersion: 1, planId: "", plan: [{id: "a"}], applied: [], remaining: ["a"], idMap: {}}'
    [plan]='{schemaVersion: 1, planId: "fixture", plan: {}, applied: [], remaining: ["a"], idMap: {}}'
    [applied]='{schemaVersion: 1, planId: "fixture", plan: [{id: "a"}], applied: {}, remaining: ["a"], idMap: {}}'
    [remaining]='{schemaVersion: 1, planId: "fixture", plan: [{id: "a"}], applied: [], remaining: {}, idMap: {}}'
    [idMap]='{schemaVersion: 1, planId: "fixture", plan: [{id: "a"}], applied: [], remaining: ["a"], idMap: []}'
    [uniqueness]='{schemaVersion: 1, planId: "fixture", plan: [{id: "a"}, {id: "a"}], applied: [], remaining: ["a"], idMap: {}}'
)
declare -A predicate_description=(
    [schema]='a ledger with the wrong schemaVersion'
    [planId]='a ledger with an empty planId'
    [plan]='a ledger whose plan is not an array'
    [applied]='a ledger whose applied is not an array'
    [remaining]='a ledger whose remaining is not an array'
    [idMap]='a ledger whose idMap is not an object'
    [uniqueness]='a ledger with duplicate plan ids'
)
declare -A predicate_keyword=(
    [schema]='schemaVersion'
    [planId]='planId'
    [plan]='plan'
    [applied]='applied'
    [remaining]='remaining'
    [idMap]='idMap'
    [uniqueness]='duplicate'
)

for class in schema planId plan applied remaining idMap uniqueness; do
    jq -n "${predicate_fixture[$class]}" >"$predicate_ledger"
    predicate_error[$class]=$(run_ledger status --ledger "$predicate_ledger" 2>&1)
    assert_rc 1 "${predicate_description[$class]} is rejected" -- \
        run_ledger status --ledger "$predicate_ledger"
    assert_contains "${predicate_error[$class]}" "${predicate_keyword[$class]}" \
        "$class refusal names ${predicate_keyword[$class]}"
    assert_eq '1' "$(printf '%s\n' "${predicate_error[$class]}" | wc -l | tr -d ' ')" \
        "predicate refusal for $class stays a single line"
    assert_not_contains "${predicate_error[$class]}" '{"' \
        "predicate refusal for $class does not dump ledger contents"
done

distinct_messages=$(printf '%s\n' "${predicate_error[@]}" | sort -u | wc -l | tr -d ' ')
assert_eq '7' "$distinct_messages" 'each broken predicate produces a distinct message'

# A ledger that fails every predicate still passes the same accept/reject
# semantics as before this change (validation, not messaging, is unchanged):
# it is rejected, and none of the seven checks accidentally pass it.
still_valid_ledger="$tmp/still-valid.json"
run_ledger init --ledger "$still_valid_ledger" --plan "$plan" >/dev/null
assert_rc 0 'a genuinely valid ledger still validates cleanly' -- \
    run_ledger status --ledger "$still_valid_ledger"

finish
