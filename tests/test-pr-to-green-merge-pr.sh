#!/usr/bin/env bash
# Verified serial merge contract for --auto-merge.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='pr to green: merge pr'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
merge_pr="$root/agentkit/skills/pr-to-green/scripts/merge-pr.sh"

readonly HEAD_SHA='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
readonly MERGE_SHA='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
readonly OTHER_SHA='cccccccccccccccccccccccccccccccccccccccc'

cat >"$tmp/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for arg in "\$@"; do [[ \$arg == repos/* ]] && endpoint=\$arg; done
printf 'gh %s\n' "\$*" >>"\$MERGE_LOG"
is_delete=0
[[ " \$* " == *' -X DELETE '* ]] && is_delete=1
case \$endpoint in
repos/owner/repo/pulls/9)
    mergeable=\${PR_MERGEABLE:-true}
    draft=\${PR_DRAFT:-false}
    state=\${PR_STATE:-open}
    sha=\${PR_HEAD_SHA:-$HEAD_SHA}
    base=\${PR_BASE:-main}
    head_repo=\${PR_HEAD_REPO:-owner/repo}
    printf '{"number":9,"state":"%s","draft":%s,"head":{"sha":"%s","ref":"feat/demo","repo":{"full_name":"%s"}},"base":{"ref":"%s"},"mergeable":%s}\n' \\
        "\$state" "\$draft" "\$sha" "\$head_repo" "\$base" "\$mergeable"
    ;;
repos/owner/repo)
    printf '{"allow_squash_merge":%s,"allow_merge_commit":%s,"allow_rebase_merge":%s}\n' \\
        "\${ALLOW_SQUASH:-true}" "\${ALLOW_MERGE:-true}" "\${ALLOW_REBASE:-true}"
    ;;
repos/owner/repo/pulls/9/merge)
    if [[ \${MERGE_REFUSE:-0} == 1 ]]; then
        printf 'refused: at least 1 approving review is required\n' >&2
        exit 1
    fi
    printf '{"merged":true,"sha":"%s","message":"ok"}\n' "$MERGE_SHA"
    ;;
repos/owner/repo/git/refs/heads/feat/demo)
    # Plural route -- DELETE only. Must never be used for the GET ref-check
    # (see the singular endpoint below): the plural route prefix-matches and
    # returns an ARRAY when this branch name prefixes another branch, which
    # is exactly the bug F2 fixes.
    if ((is_delete)); then
        if [[ \${DELETE_REFUSE:-0} == 1 ]]; then
            printf 'refused: ref protected\n' >&2
            exit 1
        fi
        printf '{}\n'
    else
        printf '[{"object":{"sha":"prefix-match-array-should-never-be-read"}}]\n'
    fi
    ;;
repos/owner/repo/git/ref/heads/feat/demo)
    # Singular route -- GET only, exact match, one object.
    if [[ \${REF_CHECK_MISSING:-0} == 1 ]]; then
        printf 'not found\n' >&2
        exit 1
    fi
    printf '{"object":{"sha":"%s"}}\n' "\${REF_CHECK_SHA:-$HEAD_SHA}"
    ;;
*) printf 'unexpected endpoint %s\n' "\$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

write_auth() {
    local delete_branch_json=$1
    jq -n --arg method "${MERGE_METHOD:-squash}" --argjson deleteBranch "$delete_branch_json" \
        --arg sha "$HEAD_SHA" '{
      repository:"owner/repo", autoMerge:true, mergeMethod:$method, deleteBranch:$deleteBranch,
      queue:[{pr:9,state:"RUNNABLE",headSha:$sha,base:"main"}]
    }' >"$tmp/auth.json"
}

write_gate() {
    local sha=${1:-$HEAD_SHA}
    printf 'gate=PASS pr=9 sha=%s\n' "$sha" >"$tmp/gate.txt"
}

run_merge() {
    write_auth "${AUTH_DELETE_BRANCH:-false}"
    write_gate "${GATE_SHA:-$HEAD_SHA}"
    MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
        --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main \
        --merge-method "${MERGE_METHOD:-squash}" \
        --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" "$@"
}

: >"$tmp/merge.log"
out=$(run_merge)
assert_contains "$out" "pr=9 merged=true method=squash merge_sha=$MERGE_SHA" \
    'a clean confirmed merge reports the merge SHA'
assert_contains "$out" 'branch_delete=skipped' \
    'branch deletion is skipped by default'
assert_eq '0' "$(grep -c 'git/refs/heads' "$tmp/merge.log" || true)" \
    'no delete call is made without --delete-branch'

: >"$tmp/merge.log"
out=$(AUTH_DELETE_BRANCH=true run_merge --delete-branch)
assert_contains "$out" 'branch_delete=ok ref=feat/demo' \
    '--delete-branch removes the head ref on success'

: >"$tmp/merge.log"
set +e
out=$(AUTH_DELETE_BRANCH=true DELETE_REFUSE=1 run_merge --delete-branch 2>&1)
rc=$?
set -e
assert_eq '0' "$rc" 'a failed branch deletion does not undo the completed merge'
assert_contains "$out" 'branch_delete=failed' \
    'a failed branch deletion is reported, not silently dropped'
assert_contains "$out" 'merged=true' \
    'the merge success line is still reported alongside the deletion failure'

: >"$tmp/merge.log"
set +e
out=$(MERGE_REFUSE=1 run_merge 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a branch-protection refusal is a named stop, never bypassed'
assert_contains "$out" 'merge refused by the forge' 'the refusal names the forge as the source'
assert_contains "$out" 'approving review is required' \
    'the exact forge refusal message is surfaced verbatim'

: >"$tmp/merge.log"
set +e
out=$(PR_HEAD_SHA="$OTHER_SHA" run_merge 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a head that moved since authorization blocks the merge attempt'
assert_contains "$out" 'stale evidence' 'the stale-head refusal names stale evidence'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'a stale head is caught before any merge call is made'

: >"$tmp/merge.log"
set +e
out=$(PR_DRAFT=true run_merge 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a draft PR cannot be merged'
assert_contains "$out" 'still a draft' 'the draft refusal is named'

: >"$tmp/merge.log"
set +e
out=$(PR_MERGEABLE=false run_merge 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a non-mergeable PR blocks the merge attempt'
assert_contains "$out" 'not mergeable' 'the not-mergeable refusal is named'

: >"$tmp/merge.log"
set +e
out=$(ALLOW_SQUASH=false run_merge 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a merge method the repository does not allow blocks the merge attempt'
assert_contains "$out" 'does not allow the configured merge method' \
    'the disallowed-method refusal is named'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'a disallowed method is caught before any merge call is made'

# --- F1 (P1): the guard belongs at the point of mutation ---------------------

: >"$tmp/merge.log"
rm -f "$tmp/auth.json"
set +e
write_gate "$HEAD_SHA"
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a direct invocation with no authorization record refuses'
assert_contains "$out" 'authorization file must be an owned regular file' \
    'the missing-authorization refusal names the missing record'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent without an authorization record'

: >"$tmp/merge.log"
jq -n --arg sha "$HEAD_SHA" '{
  repository:"owner/repo", autoMerge:true, mergeMethod:"squash", deleteBranch:false,
  queue:[{pr:9,state:"WAITING_FOR_MERGE",headSha:$sha,base:"main"}]
}' >"$tmp/auth.json"
write_gate "$HEAD_SHA"
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a queue item that is not RUNNABLE (outside the confirmed merge point) refuses'
assert_contains "$out" 'authorization does not confirm this repository, PR, head, base, merge method, and delete-branch setting' \
    'the non-RUNNABLE refusal names the authorization mismatch'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent for a queue item authorization does not confirm RUNNABLE'

: >"$tmp/merge.log"
rm -f "$tmp/gate.txt"
write_auth false
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a direct invocation with no gate-result record refuses'
assert_contains "$out" 'gate-result file must be an owned regular file' \
    'the missing-gate-result refusal names the missing record'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent without a gate-result record'

: >"$tmp/merge.log"
write_auth false
printf 'gate=BLOCKED pr=9\nblocked reason=CI is not fully green\n' >"$tmp/gate.txt"
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" 'a BLOCKED gate result refuses the merge'
assert_contains "$out" 'not authorized by a passed review-completion gate' \
    'the blocked-gate refusal names the missing pass'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent for a BLOCKED gate result'

: >"$tmp/merge.log"
write_auth false
write_gate "$OTHER_SHA"
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
assert_eq '1' "$rc" "a gate result for a different head does not authorize this head's merge"
assert_contains "$out" 'not authorized by a passed review-completion gate' \
    'the mismatched-head gate refusal names the missing pass'

# --- F1 (accepted): group/other-writable evidence files are rejected --------

: >"$tmp/merge.log"
write_auth false
write_gate "$HEAD_SHA"
chmod 664 "$tmp/auth.json"
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
chmod 600 "$tmp/auth.json"
assert_eq '1' "$rc" 'a group-writable authorization file is refused'
assert_contains "$out" 'authorization file must not be group- or world-writable' \
    'the group-writable authorization refusal is named'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent for a group-writable authorization file'

: >"$tmp/merge.log"
write_auth false
write_gate "$HEAD_SHA"
chmod 646 "$tmp/gate.txt"
set +e
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth.json" --gate-result "$tmp/gate.txt" 2>&1)
rc=$?
set -e
chmod 600 "$tmp/gate.txt"
assert_eq '1' "$rc" 'a world-writable gate-result file is refused'
assert_contains "$out" 'gate-result file must not be group- or world-writable' \
    'the world-writable gate-result refusal is named'
assert_eq '0' "$(grep -c 'pulls/9/merge' "$tmp/merge.log" || true)" \
    'no merge request is sent for a world-writable gate-result file'

# --- F2 (P2): --delete-branch never targets the wrong branch -----------------

: >"$tmp/merge.log"
out=$(AUTH_DELETE_BRANCH=true PR_HEAD_REPO='contributor/repo' run_merge --delete-branch)
assert_contains "$out" 'branch_delete=skipped ref=feat/demo reason=head-repository-is-not-the-target-repository' \
    'a fork PR never deletes a same-named branch in the target repository'
assert_eq '0' "$(grep -c 'git/refs/heads' "$tmp/merge.log" || true)" \
    'a fork head never even reads the target repository ref before skipping'

: >"$tmp/merge.log"
out=$(AUTH_DELETE_BRANCH=true REF_CHECK_SHA="$OTHER_SHA" run_merge --delete-branch)
assert_contains "$out" 'branch_delete=skipped ref=feat/demo reason=branch-no-longer-points-at-the-merged-head' \
    'a branch that moved since the merge is never deleted'
assert_eq '0' "$(grep -c -- '-X DELETE' "$tmp/merge.log" || true)" \
    'no delete call is made once the branch tip no longer matches the merged head'

# --- F2 (P1): a branch name that prefixes another branch still deletes -------
# The plural "refs/heads/<name>" route prefix-matches and returns an ARRAY
# when <name> is a prefix of another existing branch (e.g. feat/issue-3 vs
# feat/issue-333). The GET ref-check MUST use the singular "ref/heads/<name>"
# route so it gets exactly one object. This fixture must fail if the GET
# route reverts to plural: the array response makes .object.sha empty, which
# never equals HEAD_SHA, so the delete would be (wrongly) skipped instead of
# proceeding.
cat >"$tmp/gh-prefix" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for arg in "\$@"; do [[ \$arg == repos/* ]] && endpoint=\$arg; done
printf 'gh %s\n' "\$*" >>"\$MERGE_LOG"
is_delete=0
[[ " \$* " == *' -X DELETE '* ]] && is_delete=1
case \$endpoint in
repos/owner/repo/pulls/9)
    printf '{"number":9,"state":"open","draft":false,"head":{"sha":"$HEAD_SHA","ref":"feat/issue-3","repo":{"full_name":"owner/repo"}},"base":{"ref":"main"},"mergeable":true}\n'
    ;;
repos/owner/repo)
    printf '{"allow_squash_merge":true,"allow_merge_commit":true,"allow_rebase_merge":true}\n'
    ;;
repos/owner/repo/pulls/9/merge)
    printf '{"merged":true,"sha":"$MERGE_SHA","message":"ok"}\n'
    ;;
repos/owner/repo/git/refs/heads/feat/issue-3)
    # Prefix match against feat/issue-333 -- the real forge returns an ARRAY
    # here, never a single object.
    if ((is_delete)); then
        printf '{}\n'
    else
        printf 'unexpected: plural route used for the GET ref-check\n' >&2
        exit 1
    fi
    ;;
repos/owner/repo/git/ref/heads/feat/issue-3)
    printf '{"object":{"sha":"$HEAD_SHA"}}\n'
    ;;
*) printf 'unexpected endpoint %s\n' "\$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh-prefix"

jq -n --arg sha "$HEAD_SHA" '{
  repository:"owner/repo", autoMerge:true, mergeMethod:"squash", deleteBranch:true,
  queue:[{pr:9,state:"RUNNABLE",headSha:$sha,base:"main"}]
}' >"$tmp/auth-prefix.json"
write_gate "$HEAD_SHA"
: >"$tmp/merge.log"
out=$(MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh-prefix" bash "$merge_pr" \
    --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main --merge-method squash \
    --authorization-file "$tmp/auth-prefix.json" --gate-result "$tmp/gate.txt" --delete-branch)
assert_contains "$out" 'branch_delete=ok ref=feat/issue-3' \
    'a branch name that prefixes another branch still deletes via the singular GET route'

# --- issue #404: the one merge rule, enforced against this script's own call
# The PreToolUse merge guard (agentkit/hooks/lib/guard-lib.sh) refuses BOTH the
# `gh pr merge` porcelain verb AND the direct REST/GraphQL mutation it sends
# -- an adversarial review found the REST form (exactly the call this script
# itself makes -- see its `"$GH_BIN" api -X PUT "repos/$repo/pulls/$pr/merge"
# --input "$merge_body_file"` call above) was an unrefused bypass when an
# AGENT typed it directly, since it shares no `gh pr merge` token sequence.
#
# That refusal is scoped to the agent's own Bash command line, never to a
# helper script's internals: the hook inspects only the command an agent
# actually runs, and merge-pr.sh's own `gh` invocation happens inside ITS
# subprocess, on a command line this hook never sees. The `run_merge` tests
# throughout this file already prove that internal call succeeds end to end
# (the stub `gh` above receives and answers it); what remains to prove here is
# that the SAME call, typed directly as an agent's Bash command instead of
# dispatched through this script, is refused -- exactly the shape the P1
# finding reported.
hooks="$root/agentkit/hooks"
guard_repo=$(mktemp -d "$tmp/guard-repo.XXXXXX")
git -C "$guard_repo" init -q

guard_decision() {
    local cmd=$1 out
    out=$(jq -nc --arg cwd "$guard_repo" --arg cmd "$cmd" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:"s-issue-404",tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd}}' | "$hooks/pre-tool-use.sh" 2>/dev/null)
    jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$out"
}

assert_eq 'deny' \
    "$(guard_decision 'gh api -X PUT repos/owner/repo/pulls/9/merge --input /tmp/merge-body.json')" \
    "an agent typing this script's own REST mutation directly is refused, not a bypass (issue #404)"
assert_eq 'deny' "$(guard_decision 'gh pr merge 9 --squash')" \
    'the same guard still refuses the gh pr merge porcelain verb (issue #404)'
assert_eq 'allow' \
    "$(guard_decision "$merge_pr --repo owner/repo --pr 9 --head-sha $HEAD_SHA --base main --merge-method squash --authorization-file /tmp/auth.json --gate-result /tmp/gate.txt")" \
    'invoking this script itself -- the sanctioned entry point -- is never denied (issue #404)'

finish
