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
assert_rc 0 'appended record matches the full ledger schema' -- \
    jq -e --arg skills "$skills_real" '
      (keys | sort) == ["decision", "procedure_set", "quote", "run_id", "scope", "skills_path", "timestamp"]
      and .run_id == "review-pr-24"
      and .skills_path == $skills
      and .procedure_set == "parallel-issues"
      and .decision == "granted cross-provider review"
      and .scope == "PR diff"
      and .quote == "Yes, send this PR diff to the named reviewer."
      and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' "$ledger"
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

# A multi-line quote is the ordinary shape of a real invocation grant (flags on
# one line, scope on the next); fidelity to the human's exact wording matters
# more than single-line storage convenience, so --quote accepts embedded
# newlines directly, and --quote-file reads a file's bytes byte-exact with no
# interpolation or reflow.
assert_rc 0 'append accepts an embedded-newline quote' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'multiline grant' --quote $'line one\nline two'
assert_eq '3' "$(wc -l < "$ledger" | tr -d ' ')" 'a multi-line quote is still one NDJSON record'
assert_rc 0 'the stored multiline record parses as a single JSON value' -- \
    jq -e 'select(.scope == "multiline grant") | .quote == "line one\nline two"' "$ledger"

quote_file="$tmp/quote.txt"
printf 'flags: --yolo --fast-mode\nscope: worktree pushes, draft PRs, board moves\nquoted `cmd` and $(sub) stay literal\n' \
    > "$quote_file"
chmod 600 -- "$quote_file"
assert_rc 0 'append accepts --quote-file for a multi-line grant' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'quote-file grant' --quote-file "$quote_file"
stored_quote_file="$tmp/stored-quote.txt"
jq -j 'select(.scope == "quote-file grant") | .quote' "$ledger" > "$stored_quote_file"
assert_rc 0 '--quote-file stores the file bytes byte-exact' -- \
    cmp -s "$quote_file" "$stored_quote_file"

assert_rc 2 '--quote and --quote-file together is a usage error' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'conflict' --quote inline --quote-file "$quote_file"
assert_rc 2 'append requires --quote or --quote-file' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'missing quote'
assert_rc 2 '--quote-file rejects a symlink' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'symlinked quote-file' --quote-file "$tmp/skills-link"

# Command substitution cannot retain a NUL byte, so a quote file that contains
# one is refused loudly instead of being silently truncated/altered -- what is
# stored must be exactly what was supplied, and a NUL byte cannot honor that.
nul_quote_file="$tmp/nul-quote.txt"
printf 'approve\0deny\n' > "$nul_quote_file"
chmod 600 -- "$nul_quote_file"
nul_error=''
nul_rc=0
nul_error=$("$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'nul quote-file' --quote-file "$nul_quote_file" 2>&1) || nul_rc=$?
assert_eq 2 "$nul_rc" '--quote-file rejects a file containing a NUL byte'
assert_contains "$nul_error" 'NUL byte' \
    'the NUL-byte rejection names the reason'

# The length cap is unchanged by allowing newlines: a multi-line quote that
# exceeds MAX_TEXT_LENGTH is still rejected, whether it arrives inline or
# via --quote-file.
oversized_quote=$(printf 'line %03d\n' $(seq 1 600))
oversized_error=''
oversized_rc=0
oversized_error=$("$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'oversized inline quote' --quote "$oversized_quote" 2>&1) || oversized_rc=$?
assert_eq 2 "$oversized_rc" 'an oversized multiline --quote is rejected'
assert_contains "$oversized_error" 'too long' \
    'the oversized multiline --quote error names the length cap'
oversized_quote_file="$tmp/oversized-quote.txt"
printf '%s' "$oversized_quote" > "$oversized_quote_file"
chmod 600 -- "$oversized_quote_file"
assert_rc 2 'an oversized multiline --quote-file is rejected' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'oversized quote-file' --quote-file "$oversized_quote_file"

# A bare carriage return is a formatting artifact, not content: it is stripped
# rather than rejected, normalizing a CRLF quote to LF without changing wording.
assert_rc 0 'append accepts a CRLF quote' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'crlf grant' --quote $'line one\r\nline two\r'
assert_rc 0 'a stored CRLF quote is normalized to LF with no carriage returns' -- \
    jq -e 'select(.scope == "crlf grant") | .quote == "line one\nline two"' "$ledger"

# read round-trips a multi-line quote unchanged, and every record -- multiline
# quotes included -- stays exactly one NDJSON line per the existing fixtures.
reread_records=$("$script" read --ledger "$ledger" --run-id review-pr-24)
assert_rc 0 'read returns a multiline quote unchanged' -- \
    jq -e 'select(.scope == "multiline grant") | .quote == "line one\nline two"' \
        <<<"$reread_records"
assert_rc 0 'every stored record -- including multiline quotes -- is valid single-line JSON' -- \
    jq -c . "$ledger"

# --decision and --scope remain single-line tokens; only --quote widens.
decision_error=''
decision_rc=0
decision_error=$("$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision $'line one\nline two' \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'decision multiline' --quote fine 2>&1) || decision_rc=$?
assert_eq 2 "$decision_rc" '--decision rejects an embedded newline'
assert_contains "$decision_error" '--decision must be a single line' \
    '--decision multiline rejection names the offending flag'
assert_not_contains "$decision_error" 'collapse to one line' \
    'the obsolete collapse-to-one-line instruction is gone'
scope_error=''
scope_rc=0
scope_error=$("$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision steer \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope $'line one\nline two' --quote fine 2>&1) || scope_rc=$?
assert_eq 2 "$scope_rc" '--scope rejects an embedded newline'
assert_contains "$scope_error" '--scope must be a single line' \
    '--scope multiline rejection names the offending flag'

# A ledger is not a secret store. Reject common credential-shaped material in
# every human-controlled field before it reaches disk.
for secret in 'token=ghp_example' 'password: hunter2' 'Bearer abc123' \
    'Password: hunter2' '-----BEGIN PRIVATE KEY-----' 'github_pat_abc123'; do
    assert_rc 2 "append rejects secret-shaped quote: $secret" -- "$script" append \
        --ledger "$ledger" --run-id 'review-pr-24' --decision grant \
        --skills-path "$skills_path" --procedure-set parallel-issues \
        --scope 'secret check' --quote "$secret"
done
# The secret check applies to a multi-line quote too: a credential buried on
# any line of a longer grant must still be caught before it reaches disk.
assert_rc 2 'append rejects a secret-shaped multiline quote' -- "$script" append \
    --ledger "$ledger" --run-id 'review-pr-24' --decision grant \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --scope 'multiline secret check' \
    --quote $'line one\ntoken=ghp_exampleabc123\nline three'
assert_eq '5' "$(wc -l < "$ledger" | tr -d ' ')" 'secret-shaped input is never persisted'

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
assert_eq '8' "$(jq -s 'length' "$ledger")" 'concurrent appends preserve every record'
assert_eq '3' "$("$script" read --ledger "$ledger" --run-id concurrent | jq -s 'length')" \
    'read returns all concurrent decisions'

# The read path must serialize on the same lock the append path uses, so a
# read can never observe a torn NDJSON line mid-append. Prove it: hold the
# ledger lock from a background subshell, confirm a concurrent read blocks
# while it is held, then confirm the read completes once it is released.
lock_marker="$tmp/lock-held"
rm -f -- "$lock_marker"
(
    exec 9>"$ledger.lock"
    flock 9
    : >"$lock_marker"
    sleep 2
) &
lock_holder=$!
for _attempt in $(seq 1 50); do
    [[ -e $lock_marker ]] && break
    sleep 0.1
done
assert_rc 124 'read blocks while another process holds the ledger lock' -- \
    timeout 1 "$script" read --ledger "$ledger" --run-id concurrent
wait "$lock_holder"
assert_rc 0 'read completes once the ledger lock is released' -- \
    timeout 5 "$script" read --ledger "$ledger" --run-id concurrent

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
    'RUN_ID="parallel-issues-$(printf '\''%s'\'' "$run_inputs" | sha256sum | cut -c1-32)"' \
    'parallel run IDs hash the normalized invocation inputs'
assert_contains "$parallel_text" \
    'run_inputs="scope=$(normalize_run_input "$issue_scope");flags=$(normalize_run_input "$invocation_flags");repository=$(normalize_run_input "$repository");base=$(normalize_run_input "$base")"' \
    'parallel run IDs use only stable invocation inputs'
assert_not_contains "$parallel_text" 'starting_head=' \
    'parallel run IDs do not depend on mutable starting HEAD state'
assert_not_contains "$parallel_text" 'contract_head=' \
    'parallel run IDs do not depend on mutable contract state'
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
    local scope=$1 flags=$2 repository=$3 base=$4
    local inputs
    inputs="scope=$(normalize_run_input "$scope");flags=$(normalize_run_input "$flags");repository=$(normalize_run_input "$repository");base=$(normalize_run_input "$base")"
    printf 'parallel-issues-%s' "$(printf '%s' "$inputs" | sha256sum | cut -c1-32)"
}
scope_run_a=$(run_id_digest '57,54' 'yolo=false;auto-review=false' wrzonance/agent-kit main)
scope_run_b=$(run_id_digest '57,62' 'yolo=false;auto-review=false' wrzonance/agent-kit main)
flag_run_b=$(run_id_digest '57,54' 'yolo=false;auto-review=true' wrzonance/agent-kit main)
assert_eq 'different' "$([[ $scope_run_a != "$scope_run_b" ]] && printf different || printf same)" \
    'different issue scopes produce different parallel run IDs'
assert_eq 'different' "$([[ $scope_run_a != "$flag_run_b" ]] && printf different || printf same)" \
    'different authorization flags produce different parallel run IDs'

review_text=$(<"$root/agentkit/skills/review-remote-pr/SKILL.md")
assert_contains "$review_text" \
    'review_invocation_flags="auto-review=${auto_review:-false}"' \
    'review run IDs include the current invocation authorization flag'
assert_contains "$review_text" \
    'RUN_ID="review-pr-$(printf '\''%s'\'' "$review_run_inputs" | sha256sum | cut -c1-32)"' \
    'review run IDs hash invocation inputs'
review_run_id() {
    local flags=$1 inputs
    inputs="pr=203;repo=wrzonance/agent-kit;flags=$(normalize_run_input "$flags")"
    printf 'review-pr-%s' "$(printf '%s' "$inputs" | sha256sum | cut -c1-32)"
}
assert_eq 'different' "$([[ $(review_run_id auto-review=false) != $(review_run_id auto-review=true) ]] && printf different || printf same)" \
    'different review authorization flags produce different run IDs'

# covers: the once-per-run authorization check (issue #224 WS6). A recorded
# grant answers every later mutation of its class; an unrecorded one stops.
covers_ledger="$state/covers-ledger.ndjson"
covers_scope='worktree pushes, draft PRs, board moves'
assert_rc 1 'covers refuses before any grant is recorded' -- "$script" covers \
    --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --decision 'authorize:workflow-mutations' --scope "$covers_scope"
assert_rc 0 'covers fixture grant appends' -- "$script" append \
    --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --skills-path "$skills_path" --procedure-set parallel-issues \
    --decision 'authorize:workflow-mutations' --scope "$covers_scope" \
    --quote 'yolo fast-mode: publish the drafts without re-asking.'
covers_out=$("$script" covers --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --decision 'authorize:workflow-mutations' --scope "$covers_scope" 2>/dev/null)
covers_rc=$?
assert_eq 0 "$covers_rc" 'a recorded grant covers its exact decision and scope'
assert_contains "$covers_out" 'covered= run-id=parallel-issues-fast decision=authorize:workflow-mutations records=1' \
    'covers reports the matched grant as evidence'
assert_rc 2 'a scope-less covers check is a usage error, never a wildcard' -- "$script" covers \
    --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --decision 'authorize:workflow-mutations'
assert_rc 1 'a different decision token is not covered' -- "$script" covers \
    --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --decision 'authorize:ready-flip' --scope "$covers_scope"
assert_rc 1 'another run cannot borrow the grant' -- "$script" covers \
    --ledger "$covers_ledger" --run-id 'parallel-issues-other' \
    --decision 'authorize:workflow-mutations' --scope "$covers_scope"
assert_rc 1 'a scope mismatch is not covered' -- "$script" covers \
    --ledger "$covers_ledger" --run-id 'parallel-issues-fast' \
    --decision 'authorize:workflow-mutations' --scope 'merges to trunk'

ledger_section=$(awk '/^## Session decision ledger/{capture=1} /^### Diff-size facts/{capture=0} capture' \
    "$root/agentkit/skills/parallel-issues/SKILL.md")
assert_not_contains "$ledger_section" 'issue_number' \
    'parallel ledger identity does not use per-worker issue numbers'
assert_not_contains "$ledger_section" 'branch=' \
    'parallel ledger identity does not use per-worker branches'
assert_not_contains "$ledger_section" 'worktree=' \
    'parallel ledger identity does not use per-worker worktrees'

# --- ledger parent is created 0700 regardless of the ambient umask (#474) --
# A plain `mkdir -p` inherits the ambient umask; on a `umask 002` machine the
# directory prepare_parent just created came out group-writable, and
# validate_parent then refused the very directory the kit created. This
# fixture's parent does not exist yet (unlike $state above), so
# prepare_parent's own mkdir path actually fires.
fresh_parent="$tmp/fresh-umask/.agent"
fresh_ledger="$fresh_parent/session-ledger.ndjson"
(
    umask 002
    "$script" append --ledger "$fresh_ledger" --run-id 'issue474-fresh-parent' \
        --skills-path "$skills_path" --procedure-set parallel-issues \
        --decision 'umask regression' --scope 'fresh parent' --quote 'q'
)
assert_eq '0' "$?" 'append succeeds on a fresh, not-yet-existing parent under umask 002'
assert_eq '700' "$(stat -c '%a' -- "$fresh_parent" 2>/dev/null || printf '?')" \
    'the freshly created ledger parent is mode 700 under umask 002'

# --- a pre-existing group-writable parent is still refused, with a fix hint -
# (#474 acceptance) A directory the kit did not create this run must never be
# silently chmod'd into compliance -- only refused, naming the corrective
# chmod.
stale_parent="$tmp/stale/.agent"
mkdir -p -- "$stale_parent"
chmod 775 -- "$stale_parent"
stale_out=$("$script" append --ledger "$stale_parent/session-ledger.ndjson" \
    --run-id 'stale-check' --skills-path "$skills_path" \
    --procedure-set parallel-issues --decision 'stale regression' \
    --scope 'pre-existing parent' --quote 'q' 2>&1)
stale_rc=$?
assert_eq '1' "$stale_rc" 'append refuses a pre-existing group-writable parent'
assert_contains "$stale_out" "must not be group- or world-writable: $stale_parent" \
    'the refusal names the offending parent'
assert_contains "$stale_out" "fix: chmod 700 $stale_parent" \
    'the refusal message names the corrective chmod'
assert_eq '775' "$(stat -c '%a' -- "$stale_parent")" \
    'the pre-existing parent mode is left untouched, not auto-fixed'

finish
