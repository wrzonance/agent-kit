#!/usr/bin/env bash
# Boundary coverage for the durable per-run human decision ledger.
# shellcheck disable=SC2016
set -uo pipefail

TEST_NAME='session ledger'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/session-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

state="$tmp/.agent"
mkdir -- "$state"
chmod 700 -- "$state"
ledger="$state/session-ledger.ndjson"
skills_real="$tmp/skills"
mkdir -p "$skills_real/.shared/scripts"
chmod 700 -- "$skills_real" "$skills_real/.shared" "$skills_real/.shared/scripts"
ln -s -- "$skills_real" "$tmp/skills-link"
skills_path="$tmp/skills-link"

assert_rc 0 'read treats an absent ledger as no prior decisions' -- "$script" read \
    --ledger "$ledger" --run-id 'review-pr-24'

# The helper is the single writer boundary. Its records carry the run identity
# so a resumed orchestrator can read only its own decisions.
assert_rc 0 'append writes a grant record' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --decision 'granted cross-provider review' --scope 'PR diff' \
    --quote 'Yes, send this PR diff to the named reviewer.'
assert_eq 600 "$(stat -c '%a' -- "$ledger")" 'the ledger is owner-private'
assert_eq '1' "$(wc -l < "$ledger" | tr -d ' ')" 'one append is one NDJSON record'
jq -e --arg skills "$skills_real" '
  (keys | sort) == ["decision", "procedure_set", "quote", "run_id", "scope", "skills_path", "timestamp"]
  and .run_id == "review-pr-24"
  and .skills_path == $skills
  and .procedure_set == "parallel-issues"
  and .decision == "granted cross-provider review"
  and .scope == "PR diff"
  and .quote == "Yes, send this PR diff to the named reviewer."
  and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
' "$ledger" >/dev/null
assert_rc 0 'read returns records for the requested run' -- "$script" read \
    --ledger "$ledger" --run-id 'review-pr-24'
assert_eq '' "$({ "$script" read --ledger "$ledger" --run-id other; } 2>/dev/null)" \
    'read does not leak another run'

# JSON escaping preserves the human quote verbatim without allowing a second
# physical line to forge an additional record.
assert_rc 0 'append preserves JSON punctuation in a quote' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'board adjudication' --quote 'Use "Ready" -> "In progress".'
assert_eq '2' "$(wc -l < "$ledger" | tr -d ' ')" 'the punctuation quote remains one record'
assert_rc 2 'append rejects a multiline quote' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'board adjudication' --quote $'line one\nline two'
assert_eq '2' "$(wc -l < "$ledger" | tr -d ' ')" 'rejected input does not alter the ledger'

# A ledger is not a secret store. Reject common credential-shaped material in
# every human-controlled field before it reaches disk.
for secret in 'token=ghp_example' 'password: hunter2' 'Bearer abc123' \
    '-----BEGIN PRIVATE KEY-----' 'github_pat_abc123'; do
    assert_rc 2 "append rejects secret-shaped quote: $secret" -- "$script" append \
        --ledger "$ledger" --run-id 'review-pr-24' --decision grant \
        --skills-path "$skills_path" --procedure-set parallel-issues \
        --scope 'secret check' --quote "$secret"
done
assert_eq '2' "$(wc -l < "$ledger" | tr -d ' ')" 'secret-shaped input is never persisted'

# Existing state is validated fail-closed and symlinks cannot redirect writes.
printf '%s\n' '{"quote":"forged"}' > "$tmp/invalid.ndjson"
chmod 600 -- "$tmp/invalid.ndjson"
assert_rc 1 'read rejects malformed existing state' -- "$script" read \
    --ledger "$tmp/invalid.ndjson" --run-id x
target="$tmp/target.ndjson"
printf '%s\n' 'do not overwrite' > "$target"
chmod 600 -- "$target"
ln -s -- "$target" "$tmp/symlink.ndjson"
assert_rc 1 'append rejects a symlinked ledger' -- "$script" append \
    --ledger "$tmp/symlink.ndjson" --run-id x --decision grant \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope scope --quote quote
assert_eq 'do not overwrite' "$(<"$target")" 'symlink target remains untouched'

# Concurrent human receipts serialize without losing decisions.
for id in alpha bravo charlie; do
    "$script" append --ledger "$ledger" --run-id concurrent \
        --skills-path "$skills_path" --procedure-set parallel-issues \
        --decision grant --scope "$id" --quote "approved $id" \
        >"$tmp/$id.out" 2>&1 &
done
wait
assert_eq '5' "$(jq -s 'length' "$ledger")" 'concurrent appends preserve every record'
assert_eq '3' "$("$script" read --ledger "$ledger" --run-id concurrent | jq -s 'length')" \
    'read returns all concurrent decisions'

# The repository's existing working-state ignore rule covers this durable
# artifact, so it cannot be swept into history by ordinary staging.
assert_rc 0 'session ledger is excluded from repository history' -- \
    git -C "$root" check-ignore -q -- .agent/session-ledger.ndjson

for skill in parallel-issues review-remote-pr; do
    skill_file="$root/agentkit/skills/$skill/SKILL.md"
    skill_text=$(<"$skill_file")
    assert_contains "$skill_text" 'session-ledger.sh" append' \
        "$skill instructs orchestrators to append ledger decisions"
    assert_contains "$skill_text" '--skills-path "$agentkit"' \
        "$skill records the resolved skills path"
    assert_contains "$skill_text" "--procedure-set $skill" \
        "$skill records its active procedure set"
    assert_contains "$skill_text" 'compaction/resume' \
        "$skill requires a ledger reread after compaction or resume"
    assert_contains "$skill_text" 'verbatim quote' \
        "$skill requires the exact human wording"
done

parallel_text=$(<"$root/agentkit/skills/parallel-issues/SKILL.md")
assert_contains "$parallel_text" \
    'issue_scope="${selected_issue_scope:-${requested_issue_scope:-auto}}"' \
    'parallel run IDs use the requested or selected issue scope'
assert_contains "$parallel_text" \
    'invocation_flags="yolo=${yolo_invocation:-false};trust-trunk=${trust_trunk:-false};fast-mode=${fast_mode:-false};auto-review=${auto_review:-false};auto-serialize=${auto_serialize:-false}"' \
    'parallel run IDs include canonical authorization flags'
assert_contains "$parallel_text" \
    'starting_head="$(git rev-parse HEAD)"' \
    'parallel run IDs include the pinned starting head'
assert_contains "$parallel_text" \
    'contract_head="$(sha256sum "$repository_root/.agent/env-contract.txt" | cut -c1-16)"' \
    'parallel run IDs include the pinned contract head'
assert_contains "$parallel_text" \
    'RUN_ID="parallel-issues-$(printf '\''%s'\'' "$run_inputs" | sha256sum | cut -c1-32)"' \
    'parallel run IDs hash the normalized invocation inputs'
assert_contains "$parallel_text" \
    'scope=57,54' \
    'parallel documents the first distinct issue scope input'
assert_contains "$parallel_text" \
    'scope=57,62' \
    'parallel documents the second distinct issue scope input'
assert_contains "$parallel_text" \
    'auto-review=false' \
    'parallel documents the first distinct authorization flag input'
assert_contains "$parallel_text" \
    'auto-review=true' \
    'parallel documents the second distinct authorization flag input'

normalize_run_input() {
    local value=$1
    value=${value//[^A-Za-z0-9._-]/-}
    printf '%s' "$value"
}
run_id_digest() {
    local scope=$1 flags=$2 repository=$3 base=$4 starting_head=$5 contract_head=$6
    local inputs
    inputs="scope=$(normalize_run_input "$scope");flags=$(normalize_run_input "$flags");repository=$(normalize_run_input "$repository");base=$(normalize_run_input "$base");starting-head=$(normalize_run_input "$starting_head");contract-head=$(normalize_run_input "$contract_head")"
    printf 'parallel-issues-%s' "$(printf '%s' "$inputs" | sha256sum | cut -c1-32)"
}
scope_run_a=$(run_id_digest '57,54' 'yolo=false;auto-review=false' wrzonance/agent-kit main abc123 contract-a)
scope_run_b=$(run_id_digest '57,62' 'yolo=false;auto-review=false' wrzonance/agent-kit main abc123 contract-a)
flag_run_b=$(run_id_digest '57,54' 'yolo=false;auto-review=true' wrzonance/agent-kit main abc123 contract-a)
assert_eq 'different' "$([[ $scope_run_a != "$scope_run_b" ]] && printf different || printf same)" \
    'different issue scopes produce different parallel run IDs'
assert_eq 'different' "$([[ $scope_run_a != "$flag_run_b" ]] && printf different || printf same)" \
    'different authorization flags produce different parallel run IDs'

ledger_section=$(awk '/^## Session decision ledger/{capture=1} /^### Diff-size facts/{capture=0} capture' \
    "$root/agentkit/skills/parallel-issues/SKILL.md")
assert_not_contains "$ledger_section" 'issue_number' \
    'parallel ledger identity does not use per-worker issue numbers'
assert_not_contains "$ledger_section" 'branch=' \
    'parallel ledger identity does not use per-worker branches'
assert_not_contains "$ledger_section" 'worktree=' \
    'parallel ledger identity does not use per-worker worktrees'

finish
