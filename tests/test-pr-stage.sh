#!/usr/bin/env bash
# Suite: resumable one-call PR publication bookkeeping.
# shellcheck disable=SC2016  # assertions match literal skill recipe variables
set -uo pipefail

TEST_NAME='pr-stage'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

helper="$root/agentkit/skills/parallel-issues/scripts/pr-stage.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

assert_eq 0 "$([[ -x $helper ]] && printf 0 || printf 1)" \
    'the PR stage composer is shipped executable'
helper_text=$(cat "$helper")
assert_contains "$helper_text" 'gh-pr-state.sh' 'finalize delegates the fresh digest to the existing helper'
assert_contains "$helper_text" 'post-receipt.sh' 'finalize delegates exact-once publication to the existing helper'
assert_not_contains "$helper_text" 'adversarial-run.sh' 'bookkeeping never launches an adversarial review'
assert_not_contains "$helper_text" 'agent-run.sh' 'bookkeeping never launches tests'
assert_not_contains "$helper_text" 'finding-ledger.sh" add' 'bookkeeping never adjudicates findings'

parallel_text=$(cat "$root/agentkit/skills/parallel-issues/SKILL.md")
worker_prompt_text=$(cat "$root/agentkit/skills/parallel-issues/references/worker-prompts.md")
review_text=$(cat "$root/agentkit/skills/review-remote-pr/SKILL.md")
assert_contains "$parallel_text" 'pr-stage.sh" "${finalize_args[@]}"' \
    'parallel finalization uses the one-call stage recipe'
assert_contains "$parallel_text" '--run-repo-root "$repository_root"' \
    'parallel finalization preserves the restored primary run-state identity beside the PR worktree'
assert_contains "$worker_prompt_text" 'pr-stage.sh" open --run-id "$RUN_ID"' \
    'parallel draft creation uses the one-call stage recipe'
assert_contains "$review_text" 'pr-stage.sh" "${finalize_args[@]}"' \
    'standalone review uses the explicit-context one-call finalizer'

mkdir -p "$tmp/bin" "$tmp/repo" "$tmp/run/state" "$tmp/outside"
git -C "$tmp/repo" init -q
git -C "$tmp/repo" config user.email test@example.com
git -C "$tmp/repo" config user.name Test
printf 'fixture\n' >"$tmp/repo/file"
git -C "$tmp/repo" add file
git -C "$tmp/repo" commit -qm fixture
git -C "$tmp/repo" worktree add -q -b fix/issue-908 "$tmp/worker"

for section in why what decisions testing; do
    printf '%s section\n' "$section" >"$tmp/$section.md"
done
printf '%s\n' '- [x] focused verification' >"$tmp/testing.md"
printf '%s\n' '{"entries":[{"issue":908,"publicationTarget":"fix/issue-909"}]}' >"$tmp/plan.json"
chmod 600 "$tmp/plan.json"

cat >"$tmp/bin/run-dir" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$TEST_RUN_DIR"
EOF

cat >"$tmp/bin/compose" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'compose' >>"$TEST_CALLS"
out=''; why=''
while (($#)); do
    case $1 in
        --output) out=$2; shift 2 ;;
        --why-file) why=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '\n' >>"$TEST_CALLS"
cat >"$out" <<BODY
This was written agentically; verify its assertions:
## Why
$(cat "$why")
## What
what section
## Decisions
decisions section
## Testing
- [x] focused verification
🤖 Co-authored by Codex.

Closes #908
BODY
EOF

cat >"$tmp/bin/run-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action=$1; shift
path=''; json=''; value=''; repo_root=''
while (($#)); do
    case $1 in
        --path) path=$2; shift 2 ;;
        --json) json=$2; shift 2 ;;
        --value) value=$2; shift 2 ;;
        --repo-root) repo_root=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf 'run-state %s %s root=%s\n' "$action" "$path" "$repo_root" >>"$TEST_CALLS"
state=$TEST_STATE
[[ -e $state ]] || printf '{}\n' >"$state"
case $action in
    get)
        jq -er --arg p "$path" 'getpath($p|split(".")) // empty' "$state" || exit 11
        ;;
    set)
        [[ -n $json ]] || json=$(jq -nc --arg v "$value" '$v')
        staged=$state.tmp
        jq --arg p "$path" --argjson v "$json" 'setpath($p|split(".");$v)' "$state" >"$staged"
        mv "$staged" "$state"
        ;;
    append-unique|record-summary)
        if [[ $action == record-summary && $path == opened_prs && ${TEST_REGISTER_FAIL_ONCE:-0} == 1 && ! -e $TEST_REGISTER_MARKER ]]; then
            : >"$TEST_REGISTER_MARKER"
            exit 1
        fi
        if [[ $action == record-summary && ${TEST_SUMMARY_FAIL_ONCE:-0} == 1 && ! -e $TEST_SUMMARY_MARKER ]]; then
            : >"$TEST_SUMMARY_MARKER"
            exit 1
        fi
        staged=$state.tmp
        jq --arg p "$path" --argjson v "$json" \
            'setpath($p|split("."); ((getpath($p|split(".")) // []) + [$v] | unique))' \
            "$state" >"$staged"
        mv "$staged" "$state"
        ;;
    *) exit 2 ;;
esac
EOF

cat >"$tmp/bin/gh-body" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh-body\n' >>"$TEST_CALLS"
if [[ ${TEST_GH_BODY_MODE:-success} == lost ]]; then
    printf 'response lost\n' >&2
    exit 1
fi
printf '%s\n' '{"number":44,"html_url":"https://github.com/owner/repo/pull/44","closing_issue":{"issue":908,"state":"deferred","reason":"stacked"}}'
EOF

cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh-lookup %s\n' "$*" >>"$TEST_CALLS"
count=0
[[ ! -e $TEST_LOOKUP_COUNT ]] || count=$(cat "$TEST_LOOKUP_COUNT")
count=$((count + 1)); printf '%s\n' "$count" >"$TEST_LOOKUP_COUNT"
if ((count == 1)); then
    printf '%s\n' "${TEST_PR_LIST_BEFORE:-[]}"
else
    printf '%s\n' "${TEST_PR_LIST_AFTER:-${TEST_PR_LIST:-[]}}"
fi
EOF

cat >"$tmp/bin/board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'board\n' >>"$TEST_CALLS"
if [[ ${TEST_BOARD_FAIL_ONCE:-0} == 1 && ! -e $TEST_BOARD_MARKER ]]; then
    : >"$TEST_BOARD_MARKER"
    exit 1
fi
printf '%s\n' 'moved #908 -> "In review" on project #1 "Test" (board.json, 1 call)'
EOF

cat >"$tmp/bin/gh-pr-state" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh-pr-state\n' >>"$TEST_CALLS"
printf 'gh-pr-state-pwd %s\n' "$PWD" >>"$TEST_CALLS"
digest=''; state_dir=''; pr=''
while (($#)); do
    case $1 in
        --digest-out) digest=$2; shift 2 ;;
        --tmpdir) state_dir=$2; shift 2 ;;
        --pr) pr=$2; shift 2 ;;
        *) shift ;;
    esac
done
mkdir -p "$state_dir"
if [[ -n ${TEST_REMOTE_COMMENTS:-} && -e $TEST_REMOTE_COMMENTS ]]; then
    cp "$TEST_REMOTE_COMMENTS" "$state_dir/pr_${pr}_issue_comments.json"
else
    printf '%s\n' "${TEST_COMMENTS:-[]}" >"$state_dir/pr_${pr}_issue_comments.json"
fi
head=$(git -C "$TEST_REPO" rev-parse HEAD)
cat >"$digest" <<DIGEST
pr=$pr draft=true mergeable=MERGEABLE head=fix/issue-908 sha=$head
base: ref=fix/issue-909 behind=0 stale=no
ci=1/1 green pending=0 failing=0
DIGEST
printf '%s\n' 'finding-classification: cq=known icf=known' >>"$digest"
chmod 600 "$digest"
cat "$digest"
EOF

cat >"$tmp/bin/post-receipt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
action=$1; shift
printf 'post-receipt %s\n' "$action" >>"$TEST_CALLS"
printf 'post-receipt-pwd %s\n' "$PWD" >>"$TEST_CALLS"
printf 'post-args %s\n' "$*" >>"$TEST_CALLS"
case $action in
    publish)
        [[ -f $RUN_DIR/accepted-findings.ndjson ]] || exit 1
        [[ ${TEST_POST_MODE:-success} == success ]] || exit 1
        if [[ ${TEST_POST_ONCE:-0} == 1 ]]; then
            [[ ! -e $TEST_POST_MARKER ]] || exit 11
            : >"$TEST_POST_MARKER"
            printf 'post-mutation\n' >>"$TEST_CALLS"
        fi
        comments=''; digest=''; reviewed=''; payload=''
        while (($#)); do
            case $1 in
                --issue-comments) comments=$2; shift 2 ;;
                --pr-state-digest) digest=$2; shift 2 ;;
                --head-sha) reviewed=$2; shift 2 ;;
                --diff-payload) payload=$2; shift 2 ;;
                *) shift ;;
            esac
        done
        final=$(sed -nE 's/^.* sha=([0-9a-f]{40})$/\1/p' "$digest")
        body="<!-- review-remote-pr:agent-doc -->
- Reviewed head: $reviewed
- Diff payload: $payload
- Final verified head: $final
<!-- adversarial-review:spent -->"
        jq --arg body "$body" '. + [{id:71,body:$body}]' "$comments" >"$comments.next"
        mv "$comments.next" "$comments"
        if [[ -n ${TEST_REMOTE_COMMENTS:-} ]]; then cp "$comments" "$TEST_REMOTE_COMMENTS"; fi
        ;;
    status) printf '%s\n' "${TEST_RECEIPT_STATUS:-receipt=adversarial}" ;;
esac
EOF
chmod +x "$tmp/bin"/*

common_env=(
    TEST_RUN_DIR="$tmp/run" TEST_STATE="$tmp/state.json" TEST_CALLS="$tmp/calls"
    TEST_REPO="$tmp/worker" TEST_LOOKUP_COUNT="$tmp/lookup.count"
    TEST_REMOTE_COMMENTS="$tmp/remote-comments.json" PR_STAGE_RUN_DIR_SH="$tmp/bin/run-dir"
    PR_STAGE_RUN_STATE_SH="$tmp/bin/run-state" PR_STAGE_COMPOSE_SH="$tmp/bin/compose"
    PR_STAGE_GH_BODY_SH="$tmp/bin/gh-body" PR_STAGE_BOARD_SH="$tmp/bin/board"
    PR_STAGE_GH_PR_STATE_SH="$tmp/bin/gh-pr-state"
    PR_STAGE_POST_RECEIPT_SH="$tmp/bin/post-receipt" PR_STAGE_GH="$tmp/bin/gh"
)

open_args=(open --run-id wave --repo-root "$tmp/repo" --dispatch-plan "$tmp/plan.json"
    --issue 908 --repo owner/repo --head fix/issue-908 --title 'Fix publication'
    --why-file "$tmp/why.md" --what-file "$tmp/what.md"
    --decisions-file "$tmp/decisions.md" --testing-file "$tmp/testing.md"
    --agent Codex)

: >"$tmp/calls"
rm -f "$tmp/lookup.count"
open_output=$(env "${common_env[@]}" "$helper" "${open_args[@]}")
assert_contains "$open_output" 'stage=open pr=44 completed=compose,create,register,board outstanding=none' \
    'open emits one compact completed status'
assert_eq 1 "$(grep -c '^gh-body$' "$tmp/calls")" 'open creates the PR once'
assert_eq 1 "$(grep -c '^board$' "$tmp/calls")" 'open moves the board once'
assert_eq 'owner/repo' "$(jq -r '.pr_stage.issue_908.open.intent.repo' "$tmp/state.json")" \
    'open persists repository intent before mutation'
assert_eq 'fix/issue-908' "$(jq -r '.pr_stage.issue_908.open.intent.head' "$tmp/state.json")" \
    'open persists exact head intent before mutation'
assert_eq 64 "$(jq -r '.pr_stage.issue_908.open.intent.body_sha256 | length' "$tmp/state.json")" \
    'open persists the intended body digest before mutation'
assert_eq 'fix/issue-909' "$(jq -r '.pr_stage.issue_908.open.intent.base' "$tmp/state.json")" \
    'open persists the intended publication target before mutation'
assert_eq "$(git -C "$tmp/worker" rev-parse HEAD)" \
    "$(jq -r '.pr_stage.issue_908.open.intent.head_sha' "$tmp/state.json")" \
    'open persists the actual intended head commit before mutation'

repeat_output=$(env "${common_env[@]}" "$helper" "${open_args[@]}")
assert_contains "$repeat_output" 'outstanding=none' 'completed open repeats as a truthful no-op'
assert_eq 1 "$(grep -c '^gh-body$' "$tmp/calls")" 'completed open does not recreate the PR'
assert_eq 1 "$(grep -c '^board$' "$tmp/calls")" 'completed open does not repeat the board move'

# A failure after creation keeps the saved PR identity. Resume finishes the
# remaining registration/board work without another create mutation.
rm -f "$tmp/state.json" "$tmp/register.marker" "$tmp/lookup.count"
: >"$tmp/calls"
register_rc=0
env "${common_env[@]}" TEST_REGISTER_FAIL_ONCE=1 TEST_REGISTER_MARKER="$tmp/register.marker" \
    "$helper" "${open_args[@]}" >"$tmp/register.out" 2>"$tmp/register.err" || register_rc=$?
assert_eq 1 "$register_rc" 'a registration interruption remains visible'
assert_contains "$(cat "$tmp/register.err")" 'outstanding=register,board failure=registration' \
    'the partial open names registration as outstanding'
saved_body=$(cat "$tmp/run/pr-stage-908-body.md")
printf 'changed section\n' >"$tmp/why.md"
changed_resume_rc=0
env "${common_env[@]}" TEST_REGISTER_FAIL_ONCE=1 TEST_REGISTER_MARKER="$tmp/register.marker" \
    "$helper" "${open_args[@]}" >"$tmp/changed-resume.out" 2>"$tmp/changed-resume.err" || changed_resume_rc=$?
assert_eq 1 "$changed_resume_rc" 'resume refuses changed body inputs'
assert_eq "$saved_body" "$(cat "$tmp/run/pr-stage-908-body.md")" \
    'resume preserves the original composed body before detecting changed inputs'
printf 'why section\n' >"$tmp/why.md"
register_resume=$(env "${common_env[@]}" TEST_REGISTER_FAIL_ONCE=1 \
    TEST_REGISTER_MARKER="$tmp/register.marker" "$helper" "${open_args[@]}")
assert_contains "$register_resume" 'outstanding=none' 'registration interruption resumes to completion'
assert_eq 1 "$(grep -c '^gh-body$' "$tmp/calls")" 'registration resume does not recreate the PR'

rm -f "$tmp/state.json" "$tmp/board.marker" "$tmp/lookup.count"
: >"$tmp/calls"
board_rc=0
env "${common_env[@]}" TEST_BOARD_FAIL_ONCE=1 TEST_BOARD_MARKER="$tmp/board.marker" \
    "$helper" "${open_args[@]}" >"$tmp/board.out" 2>"$tmp/board.err" || board_rc=$?
assert_eq 1 "$board_rc" 'a board interruption remains visible'
assert_contains "$(cat "$tmp/board.err")" 'outstanding=board failure=board-move' 'the partial open names the board failure'
board_resume=$(env "${common_env[@]}" TEST_BOARD_FAIL_ONCE=1 TEST_BOARD_MARKER="$tmp/board.marker" \
    "$helper" "${open_args[@]}")
assert_contains "$board_resume" 'outstanding=none' 'board interruption resumes to completion'
assert_eq 1 "$(grep -c '^gh-body$' "$tmp/calls")" 'board resume does not recreate the PR'
assert_eq 2 "$(grep -c '^board$' "$tmp/calls")" 'board resume retries only the idempotent failed move'

# A lost create response adopts only the one PR whose exact head and body match
# the durable pre-mutation intent.
rm -f "$tmp/state.json" "$tmp/lookup.count"
: >"$tmp/calls"
head_sha=$(git -C "$tmp/worker" rev-parse HEAD)
preexisting=$(jq -nc --arg sha "$head_sha" --rawfile body "$tmp/run/pr-stage-908-body.md" \
    '[{number:54,url:"https://github.com/owner/repo/pull/54",state:"OPEN",isDraft:true,title:"Fix publication",
       baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body}]')
pr_list=$(jq -nc --arg sha "$head_sha" --rawfile body "$tmp/run/pr-stage-908-body.md" \
    '[{number:50,url:"https://github.com/owner/repo/pull/50",state:"CLOSED",isDraft:true,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body},
      {number:51,url:"https://github.com/owner/repo/pull/51",state:"OPEN",isDraft:false,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body},
      {number:52,url:"https://github.com/owner/repo/pull/52",state:"OPEN",isDraft:true,title:"Fix publication",baseRefName:"main",headRefName:"fix/issue-908",headRefOid:$sha,body:$body},
      {number:53,url:"https://github.com/owner/repo/pull/53",state:"OPEN",isDraft:true,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:"0000000000000000000000000000000000000000",body:$body},
      {number:54,url:"https://github.com/owner/repo/pull/54",state:"OPEN",isDraft:true,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body},
      {number:55,url:"https://github.com/owner/repo/pull/55",state:"OPEN",isDraft:true,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body}]')
lost_output=$(env "${common_env[@]}" TEST_GH_BODY_MODE=lost \
    TEST_PR_LIST_BEFORE="$preexisting" TEST_PR_LIST_AFTER="$pr_list" \
    "$helper" "${open_args[@]}")
assert_contains "$lost_output" 'stage=open pr=55 completed=compose,recover,register,board outstanding=none' \
    'lost create response recovers the unique intended PR'
assert_eq 1 "$(grep -c '^gh-body$' "$tmp/calls")" 'lost-response recovery does not retry creation'
assert_eq 2 "$(grep -c '^gh-lookup ' "$tmp/calls")" \
    'lost-response recovery snapshots pre-existing candidates then makes one recovery lookup'
assert_contains "$(grep '^gh-lookup ' "$tmp/calls")" '--state open' \
    'recovery lookup is limited to open PRs'

rm -f "$tmp/state.json" "$tmp/lookup.count"
: >"$tmp/calls"
ambiguous=$(jq -nc --arg sha "$head_sha" --rawfile body "$tmp/run/pr-stage-908-body.md" \
    '[61,62] | map({number:.,url:("https://github.com/owner/repo/pull/" + tostring),state:"OPEN",isDraft:true,title:"Fix publication",baseRefName:"fix/issue-909",headRefName:"fix/issue-908",headRefOid:$sha,body:$body})')
ambiguous_rc=0
env "${common_env[@]}" TEST_GH_BODY_MODE=lost TEST_PR_LIST_BEFORE='[]' TEST_PR_LIST_AFTER="$ambiguous" \
    "$helper" "${open_args[@]}" >"$tmp/ambiguous.out" 2>"$tmp/ambiguous.err" || ambiguous_rc=$?
assert_eq 1 "$ambiguous_rc" 'ambiguous lost-response recovery refuses'
assert_contains "$(cat "$tmp/ambiguous.err")" 'ambiguous' 'ambiguous recovery names its cause'
assert_eq 0 "$(grep -c '^board$' "$tmp/calls" || true)" 'ambiguous recovery never moves the board'

# Finalization derives review metadata and counts from existing evidence, takes
# one fresh PR-state digest, publishes, classifies, and records the summary.
rm -f "$tmp/state.json" "$tmp/remote-comments.json"
binding=$(jq -nc --arg root "$tmp/repo" \
    '{binding:{run_id:"wave",activation_session:"session",repository_root:$root,
      decision_ledger:($root + "/.agent/session-ledger.ndjson"),
      worker_ledger:($root + "/.agent/runs/active-workers.ndjson")}}')
printf '%s\n' "$binding" >"$tmp/state.json"
: >"$tmp/remote-comments.json"
printf '[]\n' >"$tmp/remote-comments.json"
: >"$tmp/calls"
printf '%s\n' '{"provider":"claude","model":"fable","effort":"high","mode":"cross-provider","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":"sha256:test"}' \
    >"$tmp/run/state/review-attempt.json"
: >"$tmp/run/findings.ndjson"
rm -f "$tmp/run/accepted-findings.ndjson"
missing_accepted_rc=0
(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex) \
    >"$tmp/missing-accepted.out" 2>"$tmp/missing-accepted.err" || missing_accepted_rc=$?
assert_eq 1 "$missing_accepted_rc" 'missing accepted-finding classification blocks finalization'
assert_eq 0 "$(grep -c '^post-receipt publish$' "$tmp/calls" || true)" \
    'missing accepted-finding classification never publishes a receipt'
: >"$tmp/run/accepted-findings.ndjson"
: >"$tmp/calls"
wrong_run_root_rc=0
(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/worker" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex) \
    >"$tmp/wrong-run-root.out" 2>"$tmp/wrong-run-root.err" || wrong_run_root_rc=$?
assert_eq 1 "$wrong_run_root_rc" 'finalize refuses a run-state root outside the restored binding tuple'
assert_contains "$(cat "$tmp/wrong-run-root.err")" 'refusing a second run record' \
    'run-state root mismatch names the duplicate-record hazard'
assert_eq 0 "$(grep -c '^gh-pr-state$' "$tmp/calls" || true)" \
    'run-state root mismatch stops before checkout evidence or publication'
: >"$tmp/calls"
final_output=$(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex)
assert_contains "$final_output" 'stage=finalize pr=44 receipt=adversarial completed=digest,publish,classify,summary outstanding=none' \
    'finalize emits one compact completed status'
assert_eq $'gh-pr-state\npost-receipt publish\npost-receipt status\nrun-state record-summary receipt_prs' \
    "$(grep -E '^(gh-pr-state$|post-receipt (publish|status)$|run-state record-summary)' "$tmp/calls" | sed 's/ root=.*//')" \
    'finalize keeps fresh digest, publication, classification, and summary in order'
assert_contains "$(grep '^post-args ' "$tmp/calls" | head -n1)" \
    '--head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --diff-payload sha256:test' \
    'finalize preserves the original reviewed head and payload beside the fresh final-head digest'
assert_contains "$(cat "$tmp/calls")" "gh-pr-state-pwd $tmp/worker" \
    'finalize runs fresh checkout evidence from the intended PR worktree'
assert_contains "$(cat "$tmp/calls")" "post-receipt-pwd $tmp/worker" \
    'finalize binds receipt validation to the intended PR worktree'
assert_contains "$(cat "$tmp/calls")" "run-state record-summary receipt_prs root=$tmp/repo" \
    'finalize writes the already-bound run record in the primary repository'

repeat_final=$(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex)
assert_contains "$repeat_final" 'outstanding=none' 'completed finalize repeats as a truthful no-op'
assert_eq 1 "$(grep -c '^gh-pr-state$' "$tmp/calls")" 'completed finalize does not refresh or republish'
assert_eq 1 "$(grep -c '^post-receipt publish$' "$tmp/calls")" 'completed finalize does not duplicate the receipt'

# Completion is bound to the exact repository, final head, and paid review
# payload. A later commit invalidates the no-op and requires fresh evidence.
printf 'later\n' >>"$tmp/worker/file"
git -C "$tmp/worker" add file
git -C "$tmp/worker" commit -qm later
changed_head_output=$(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex)
assert_contains "$changed_head_output" 'outstanding=none' 'changed final head is freshly finalized'
assert_eq 2 "$(grep -c '^gh-pr-state$' "$tmp/calls")" \
    'changed final head invalidates the saved completion before the no-op'
assert_eq "$(git -C "$tmp/worker" rev-parse HEAD)" \
    "$(jq -r '.pr_stage.pr_44.finalize.input.final_head' "$tmp/state.json")" \
    'saved completion binds the final verified head'

printf '%s\n' '{"provider":"claude","model":"fable","effort":"high","mode":"cross-provider","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":"sha256:changed"}' \
    >"$tmp/run/state/review-attempt.json"
changed_payload_output=$(cd "$tmp/outside" && env "${common_env[@]}" "$helper" finalize --run-id wave \
    --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo --agent-identity Codex)
assert_contains "$changed_payload_output" 'outstanding=none' 'changed review payload is freshly finalized'
assert_eq 3 "$(grep -c '^gh-pr-state$' "$tmp/calls")" \
    'changed review payload invalidates the saved completion before the no-op'
assert_eq 'sha256:changed' "$(jq -r '.pr_stage.pr_44.finalize.input.review_payload' "$tmp/state.json")" \
    'saved completion binds the paid review payload'

# A receipt may land before summary recording fails. The existing receipt
# helper's marker reconciliation owns the retry, so only one remote post occurs.
printf '%s\n' '{"provider":"claude","model":"fable","effort":"high","mode":"cross-provider","head":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","payload":"sha256:test"}' \
    >"$tmp/run/state/review-attempt.json"
rm -f "$tmp/state.json" "$tmp/summary.marker" "$tmp/post.marker" "$tmp/remote-comments.json"
printf '%s\n' "$binding" >"$tmp/state.json"
printf '[]\n' >"$tmp/remote-comments.json"
: >"$tmp/calls"
summary_rc=0
env "${common_env[@]}" TEST_POST_ONCE=1 TEST_POST_MARKER="$tmp/post.marker" \
    TEST_SUMMARY_FAIL_ONCE=1 TEST_SUMMARY_MARKER="$tmp/summary.marker" \
    "$helper" finalize --run-id wave --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo \
    --agent-identity Codex >"$tmp/summary.out" 2>"$tmp/summary.err" || summary_rc=$?
assert_eq 1 "$summary_rc" 'a post-publication summary failure remains visible'
assert_contains "$(cat "$tmp/summary.err")" 'outstanding=summary failure=summary-recording' \
    'the partial finalize names summary recording as outstanding'
summary_resume=$(env "${common_env[@]}" TEST_POST_ONCE=1 TEST_POST_MARKER="$tmp/post.marker" \
    TEST_SUMMARY_FAIL_ONCE=1 TEST_SUMMARY_MARKER="$tmp/summary.marker" \
    "$helper" finalize --run-id wave --run-repo-root "$tmp/repo" --repo-root "$tmp/worker" --pr 44 --repo owner/repo \
    --agent-identity Codex)
assert_contains "$summary_resume" 'outstanding=none' 'summary interruption resumes to completion'
assert_eq 1 "$(grep -c '^post-mutation$' "$tmp/calls")" \
    'summary resume relies on receipt reconciliation and does not duplicate the remote post'

finish
