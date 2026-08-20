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

cat >"$tmp/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
endpoint=''
for arg in "\$@"; do [[ \$arg == repos/* ]] && endpoint=\$arg; done
printf 'gh %s\n' "\$*" >>"\$MERGE_LOG"
case \$endpoint in
repos/owner/repo/pulls/9)
    mergeable=\${PR_MERGEABLE:-true}
    draft=\${PR_DRAFT:-false}
    state=\${PR_STATE:-open}
    sha=\${PR_HEAD_SHA:-$HEAD_SHA}
    base=\${PR_BASE:-main}
    printf '{"number":9,"state":"%s","draft":%s,"head":{"sha":"%s","ref":"feat/demo"},"base":{"ref":"%s"},"mergeable":%s}\n' \\
        "\$state" "\$draft" "\$sha" "\$base" "\$mergeable"
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
    if [[ \${DELETE_REFUSE:-0} == 1 ]]; then
        printf 'refused: ref protected\n' >&2
        exit 1
    fi
    printf '{}\n'
    ;;
*) printf 'unexpected endpoint %s\n' "\$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

run_merge() {
    MERGE_LOG="$tmp/merge.log" MERGE_PR_GH="$tmp/gh" bash "$merge_pr" \
        --repo owner/repo --pr 9 --head-sha "$HEAD_SHA" --base main \
        --merge-method "${MERGE_METHOD:-squash}" "$@"
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
out=$(run_merge --delete-branch)
assert_contains "$out" 'branch_delete=ok ref=feat/demo' \
    '--delete-branch removes the head ref on success'

: >"$tmp/merge.log"
set +e
out=$(DELETE_REFUSE=1 run_merge --delete-branch 2>&1)
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
out=$(PR_HEAD_SHA='cccccccccccccccccccccccccccccccccccccccc' run_merge 2>&1)
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

finish
