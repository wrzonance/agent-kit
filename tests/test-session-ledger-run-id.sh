#!/usr/bin/env bash
# Canonical run identities, stdin quote fidelity, and receipt idempotence.
set -uo pipefail

TEST_NAME='session ledger canonical run id'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

ledger_script="$root/agentkit/skills/.shared/scripts/session-ledger.sh"
run_dir_script="$root/agentkit/skills/review-remote-pr/scripts/run-dir.sh"
collision_fixture="$here/fixtures/session-ledger-run-id-collisions.tsv"
quote_fixture="$here/fixtures/session-ledger-quote.txt"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

run_id() {
    "$ledger_script" run-id --procedure-set "$1" --scope "$2" --flags "$3" \
        --repo "$4" --base "$5"
}

first=$(run_id parallel-issues '57,54' 'yolo=true,fast-mode=false' owner/repo main)
second=$(run_id parallel-issues '54,57' 'fast-mode=false,yolo=true' owner/repo main)
assert_eq "$first" "$second" 'scope and flag ordering do not change the canonical id'
assert_eq "$first" "$(run_id parallel-issues '54,57,54' 'yolo=true,fast-mode=false' owner/repo main)" \
    'duplicate CSV members do not change the canonical id'
assert_eq yes "$([[ $first =~ ^parallel-issues-[0-9a-f]{32}$ ]] && printf yes || printf no)" \
    'the canonical id is a readable procedure prefix plus a 128-bit digest'

while IFS=$'\t' read -r proc_a scope_a flags_a repo_a base_a proc_b scope_b flags_b repo_b base_b; do
    [[ $proc_a == \#* || -z $proc_a ]] && continue
    id_a=$(run_id "$proc_a" "$scope_a" "$flags_a" "$repo_a" "$base_a")
    id_b=$(run_id "$proc_b" "$scope_b" "$flags_b" "$repo_b" "$base_b")
    assert_eq differ "$([[ $id_a != "$id_b" ]] && printf differ || printf same)" \
        "fixture identities remain distinct: $proc_a/$scope_a and $proc_b/$scope_b"
done < "$collision_fixture"

assert_rc 2 'an empty CSV member is rejected instead of canonicalized ambiguously' -- \
    "$ledger_script" run-id --procedure-set parallel-issues --scope '1,,2' \
    --repo owner/repo --base main
ordinary_identity=$(run_id review-remote-pr 511 'auto-review=false' flask-sqlalchemy task-queue)
assert_eq yes "$([[ $ordinary_identity =~ ^review-remote-pr-[0-9a-f]{32}$ ]] && printf yes || printf no)" \
    'ordinary sk-prefixed repository and branch text is accepted for hashed identity inputs'

review_skill=$(<"$root/agentkit/skills/review-remote-pr/SKILL.md")
assert_contains "$review_skill" '--base review-pr-v1' \
    'review identity uses a stable version discriminator'
# shellcheck disable=SC2016
assert_not_contains "$(awk '/^## Session decision ledger/{on=1} /^## Runtime/{on=0} on' <<<"$review_skill")" \
    '--base "$BASE_BRANCH"' 'review identity does not change when a stacked PR is retargeted'

repo="$tmp/repo"
mkdir -p "$repo"
derived_dir=$(
    "$run_dir_script" --procedure-set parallel-issues --scope '57,54' \
        --flags 'yolo=true,fast-mode=false' --repo owner/repo --base main \
        --repo-root "$repo"
)
assert_eq "$repo/.agent/evidence/run-$first" "$derived_dir" \
    'run-dir delegates canonical identity derivation to session-ledger'
legacy_dir=$("$run_dir_script" --run-id review-pr-legacy123 --repo-root "$repo")
assert_eq "$repo/.agent/evidence/run-review-pr-legacy123" "$legacy_dir" \
    'run-dir keeps explicit historical run ids resumable'

state="$tmp/state"
skills="$tmp/skills"
mkdir -p "$state" "$skills/.shared/scripts"
chmod 700 -- "$state" "$skills" "$skills/.shared" "$skills/.shared/scripts"
ledger="$state/session-ledger.ndjson"
first_record=$("$ledger_script" append --ledger "$ledger" --run-id "$first" \
    --skills-path "$skills" --procedure-set parallel-issues --decision authorize \
    --scope 'PRs 54,57' --quote-stdin --timestamp 2026-09-16T12:00:00Z < "$quote_fixture")
second_record=$("$ledger_script" append --ledger "$ledger" --run-id "$first" \
    --skills-path "$skills" --procedure-set parallel-issues --decision authorize \
    --scope 'PRs 54,57' --quote-stdin --timestamp 2026-09-16T12:01:00Z < "$quote_fixture")
assert_eq "$first_record" "$second_record" \
    'a duplicate append prints the existing record, including its original timestamp'
assert_eq 1 "$(wc -l < "$ledger" | tr -d ' ')" \
    'a duplicate semantic receipt remains one ledger record'
stored_quote="$tmp/stored-quote.txt"
jq -j '.quote' "$ledger" > "$stored_quote"
assert_rc 0 '--quote-stdin preserves punctuation and the fixture trailing newline exactly' -- \
    cmp -s "$quote_fixture" "$stored_quote"

assert_rc 2 '--quote-stdin is mutually exclusive with --quote' -- \
    "$ledger_script" append --ledger "$ledger" --run-id "$first" \
    --skills-path "$skills" --procedure-set parallel-issues --decision conflict \
    --scope conflict --quote inline --quote-stdin
# Positional parameters intentionally expand inside the child bash.
# shellcheck disable=SC2016
assert_rc 2 '--quote-stdin rejects a NUL byte instead of truncating the quote' -- \
    bash -c 'printf "approve\0deny" | "$1" append --ledger "$2" --run-id "$3" --skills-path "$4" --procedure-set parallel-issues --decision nul --scope nul --quote-stdin' \
        _ "$ledger_script" "$ledger" "$first" "$skills"

finish
