#!/usr/bin/env bash
# Suite: chain-advance.sh resolves refs and proves a safe PR retarget.
set -uo pipefail

TEST_NAME='chain-advance'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

advance="$root/agentkit/skills/parallel-issues/scripts/chain-advance.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
printf '%s\n' seed >"$repo/file"
git -C "$repo" add file
git -C "$repo" commit -qm seed
expected_sha=$(git -C "$repo" rev-parse HEAD)
resolved=$(cd -- "$repo" && bash "$advance" --resolve-base HEAD)
assert_eq "$expected_sha" "$resolved" 'resolve-base delegates SHA expansion to Git'

set +e
invalid_resolve=$(cd -- "$repo" && bash "$advance" --resolve-base missing-ref 2>&1)
invalid_resolve_rc=$?
set -e
assert_eq '1' "$invalid_resolve_rc" 'resolve-base fails for an unknown ref'
assert_not_contains "$invalid_resolve" '0000000000000000000000000000000000000000' \
    'resolve-base never invents a SHA'

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n ${GH_CWD_LOG:-} ]]; then
    printf '%s\n' "$PWD" >>"$GH_CWD_LOG"
fi
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) printf '%s\n' 'https://github.com/owner/repo/pull/7' ;;
    *" pr view "*)
        cat <<'JSON'
{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}
JSON
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0,"ahead_by":1}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh"

output=$(cd -- "$repo" && GH_CWD_LOG="$tmp/gh-cwd.log" GH_LOG="$tmp/gh.log" PATH="$tmp:$PATH" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
assert_contains "$output" 'retargeted pr #7' 'retarget reports a verified result'
assert_contains "$output" 'closing-issues=1' 'retarget reports linkage evidence'
assert_eq "$repo" "$(sed -n '1p' "$tmp/gh-cwd.log")" \
    'retarget runs the fixture forge from the fixture repository'
log=$(<"$tmp/gh.log")
assert_not_contains "$log" 'pr edit 7 --repo owner/repo --base main' \
    'retarget skips the already-correct base'
assert_contains "$log" 'pr view 7 --repo owner/repo' 'retarget re-reads PR metadata'
assert_contains "$log" 'repos/owner/repo/compare/main...1111111111111111111111111111111111111111' \
    'retarget checks base-to-head ancestry'

cat >"$tmp/gh-behind" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"parent","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"behind","behind_by":3,"ahead_by":0}'
        ;;
    *" pr edit "*) printf '%s\n' 'edit must not run' >&2; exit 24 ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-behind"
set +e
behind_output=$(cd -- "$repo" && GH_LOG="$tmp/gh-behind.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-behind" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
behind_rc=$?
set -e
assert_eq '1' "$behind_rc" 'behind retarget refuses before mutation'
assert_contains "$behind_output" 'behind_by=3' 'behind refusal reports the failed precondition'
behind_log=$(<"$tmp/gh-behind.log")
assert_not_contains "$behind_log" 'pr edit' 'behind retarget never edits the PR base'

cat >"$tmp/gh-sha" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"repos/owner/repo/compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0,"ahead_by":1}'
        ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-sha"
set +e
sha_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-sha" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
sha_rc=$?
set -e
assert_eq '0' "$sha_rc" 'retarget compares ancestry against the immutable head SHA'
assert_contains "$sha_output" 'ancestry=verified' 'SHA ancestry proof completes'

cat >"$tmp/gh-empty" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main..."*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-empty"
set +e
empty_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-empty" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
empty_rc=$?
set -e
assert_eq '1' "$empty_rc" 'already-correct base proof failure has the non-mutated exit status'
assert_contains "$empty_output" 'statusCheckRollup is empty' \
    'empty CI failure names the missing evidence'
assert_not_contains "$empty_output" 'applied base=main' \
    'already-correct base proof failure reports no mutation'

cat >"$tmp/gh-edit-nonzero" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*)
        [[ ${EDIT_APPLIES:-true} != true ]] || : >"$EDIT_STATE"
        exit 19
        ;;
    *" pr view "*)
        base=old-base
        [[ ! -e $EDIT_STATE ]] || base=main
        printf '{"number":7,"baseRefName":"%s","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[],"statusCheckRollup":[],"closingIssuesReferences":[]}\n' "$base"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-edit-nonzero"
set +e
edit_nonzero_output=$(cd -- "$repo" && EDIT_STATE="$tmp/edit-nonzero.state" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-edit-nonzero" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
edit_nonzero_rc=$?
set -e
assert_eq '2' "$edit_nonzero_rc" \
    'a nonzero edit that applied the requested base reports mutation'
assert_contains "$edit_nonzero_output" 'applied base=main' \
    'ambiguous edit failure reports the live applied base'
set +e
edit_noop_output=$(cd -- "$repo" && EDIT_APPLIES=false EDIT_STATE="$tmp/edit-noop.state" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-edit-nonzero" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
edit_noop_rc=$?
set -e
assert_eq '1' "$edit_noop_rc" 'a nonzero edit with the old live base reports no mutation'
assert_not_contains "$edit_noop_output" 'applied base=' \
    'unapplied edit failure does not claim a requested base'

cat >"$tmp/gh-stale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"old-base","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-stale"
set +e
stale_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-stale" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
stale_rc=$?
set -e
assert_eq '2' "$stale_rc" 'retarget reports mutation when GitHub leaves the old base'
assert_contains "$stale_output" 'baseRefName' 'stale base failure names the failed proof'
assert_contains "$stale_output" 'requested=main' 'stale base failure names the requested base'
assert_contains "$stale_output" 'actual=old-base' 'stale base failure names the live base'

cat >"$tmp/gh-pending" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"IN_PROGRESS","startedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-pending"
set +e
pending_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-pending" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
pending_rc=$?
set -e
assert_eq '1' "$pending_rc" 'already-correct base reports no mutation when CI is stale or pending'
assert_contains "$pending_output" 'CI' 'pending CI failure is explicit'

# Approval is provider policy, not mechanical base safety (issue #455): an
# approval attached to a different head is residue, reported but never a
# block, since ancestry/CI/closing-linkage are otherwise all satisfied.
cat >"$tmp/gh-old-approval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"2222222222222222222222222222222222222222"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-old-approval"
set +e
approval_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-old-approval" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
approval_rc=$?
set -e
assert_eq '0' "$approval_rc" 'an approval attached to an old head never blocks the retarget'
assert_contains "$approval_output" 'approval=residue:stale' \
    'an approval on a different head is reported as residue, not counted current'

cat >"$tmp/gh-no-link" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-no-link"
set +e
link_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-no-link" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
link_rc=$?
set -e
assert_eq '1' "$link_rc" 'already-correct base reports no mutation when closing linkage is absent'
assert_contains "$link_output" 'closingIssuesReferences' \
    'missing linkage failure names the machine proof'

# --- same head, evidence from before the retarget --------------------------
# `gh pr edit --base` does not move headRefOid, and the workflow does not re-run
# on a base change, so a green rollup and an approval produced against the OLD
# base stay attached to this exact head and satisfy every head-bound test. The
# helper must refuse them: chains.md requires CI to run against the new base and
# calls a stale digest a stop signal, not a green result.
cat >"$tmp/gh-prestale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2023-12-31T23:00:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2023-12-31T23:00:00Z","completedAt":"2023-12-31T23:00:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-prestale"
set +e
prestale_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-prestale" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
prestale_rc=$?
set -e
assert_eq '1' "$prestale_rc" 'already-correct base reports no mutation for stale CI on an unchanged head'
assert_contains "$prestale_output" 'predates the retarget' \
    'the refusal names pre-retarget evidence as the cause'
assert_not_contains "$prestale_output" 'retargeted pr #7' \
    'no success line is printed on pre-retarget evidence'

cat >"$tmp/gh-old-check-start" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2023-12-31T23:55:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-old-check-start"
set +e
old_check_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-old-check-start" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
old_check_rc=$?
set -e
assert_eq '1' "$old_check_rc" 'a pre-retarget check remains stale after completing later'
assert_contains "$old_check_output" 'predates the retarget' \
    'CI freshness is classified by check origin, not completion'

cat >"$tmp/gh-boundary-after-edit" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2024-01-01T00:15:00Z","completedAt":"2024-01-01T00:20:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:10:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-boundary-after-edit"
set +e
boundary_output=$(cd -- "$repo" && EDIT_STATE="$tmp/boundary-after-edit.state" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-boundary-after-edit" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
boundary_rc=$?
set -e
assert_eq '0' "$boundary_rc" 'an approval submitted before edit completion never blocks the retarget'
assert_contains "$boundary_output" 'approval=residue:stale' \
    'freshness boundary is captured only after the edit succeeds, so pre-edit approval is residue'

# The same residue on the approval alone is reported, never inherited as current.
cat >"$tmp/gh-preapproval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2023-12-31T23:00:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-preapproval"
set +e
preapproval_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-preapproval" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
preapproval_rc=$?
set -e
assert_eq '0' "$preapproval_rc" 'an approval that predates the retarget never blocks the retarget'
assert_contains "$preapproval_output" 'approval=residue:stale' \
    'the approval residue is reported explicitly, never silently inherited as current'

# --- a split approval never adds up to a current one -----------------------
# Two separate reviews must not satisfy the two halves between them: a stale
# approval OF the current head, plus a fresh approval of some OLDER commit,
# leaves no single review that is both current-head and post-retarget. Since
# an APPROVED review exists, the token is still residue -- not none.
cat >"$tmp/gh-splitapproval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2023-12-31T23:00:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}},{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"2222222222222222222222222222222222222222"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-splitapproval"
set +e
split_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-splitapproval" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
split_rc=$?
set -e
assert_eq '0' "$split_rc" 'a post-edit split approval never blocks the retarget'
assert_contains "$split_output" 'retargeted pr #7' 'the split-approval retarget still succeeds'
assert_contains "$split_output" 'approval=residue:stale' \
    'a split approval (no single review both current-head and post-retarget) reports residue'

# --- PR #440 ordering regression: merge-down, retarget, fresh CI, no approval yet ---
# This is the exact live failure from issue #455: the successor merged the new
# default branch, retargeted, and proved fresh CI, but no provider review can
# exist yet because the ready/provider transition that could produce one only
# runs after this proof. The retarget must complete with `approval=none`, not
# block waiting for a review the procedure itself has not yet allowed.
cat >"$tmp/gh-pr440" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":440,"baseRefName":"main","headRefName":"feat/child","headRefOid":"fd1400424e6617826deb7974dddcda3cb521a051","reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":427}]}'
        ;;
    *"compare/main...fd1400424e6617826deb7974dddcda3cb521a051"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-pr440"
set +e
pr440_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-pr440" bash "$advance" \
    --retarget --repo owner/repo --pr 440 --base main 2>&1)
pr440_rc=$?
set -e
assert_eq '0' "$pr440_rc" \
    'the PR #440 ordering (merge-down, retarget, fresh CI, no review yet) completes the retarget'
assert_contains "$pr440_output" 'approval=none' \
    'no review evidence at all is reported as none, never treated as a block'
assert_contains "$pr440_output" 'closing-issues=1' \
    'the PR #440 fixture still proves closing linkage'

# --- unreadable review evidence reports unknown, never blocks -------------
cat >"$tmp/gh-unreadable-reviews" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":"not-an-array","statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-unreadable-reviews"
set +e
unreadable_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-unreadable-reviews" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
unreadable_rc=$?
set -e
assert_eq '0' "$unreadable_rc" 'unreadable review evidence never blocks the retarget'
assert_contains "$unreadable_output" 'approval=unknown' \
    'malformed review evidence is reported as unknown, not silently treated as none or current'

# --- retarget is idempotent and uses the durable forge timeline boundary ---
# The first invocation applies the base and the second observes that the live
# base is already correct. Both proofs must use the same timeline event, and
# the second invocation must not issue another base edit or consult a clock.
cat >"$tmp/gh-idempotent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        base=parent
        [[ -e $EDIT_STATE ]] && base=main
        printf '%s\n' "{\"number\":7,\"baseRefName\":\"$base\",\"headRefName\":\"feat/child\",\"headRefOid\":\"1111111111111111111111111111111111111111\",\"reviewDecision\":null,\"reviews\":[],\"statusCheckRollup\":[{\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"startedAt\":\"2024-01-01T00:05:00Z\",\"completedAt\":\"2024-01-01T00:05:00Z\"}],\"closingIssuesReferences\":[{\"number\":137}]}"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*)
        printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:01:00Z"}]'
        ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-idempotent"
set +e
first_idempotent=$(cd -- "$repo" && EDIT_STATE="$tmp/idempotent.state" GH_LOG="$tmp/idempotent.log" \
    PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-idempotent" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
first_idempotent_rc=$?
second_idempotent=$(cd -- "$repo" && EDIT_STATE="$tmp/idempotent.state" GH_LOG="$tmp/idempotent.log" \
    PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-idempotent" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
second_idempotent_rc=$?
set -e
assert_eq '0' "$first_idempotent_rc" 'timeline-backed first retarget proves the current head'
assert_eq '0' "$second_idempotent_rc" 'already-retargeted PR proves idempotently'
assert_contains "$first_idempotent" 'boundarySource=timeline' \
    'first proof records its timeline boundary source'
assert_contains "$second_idempotent" 'boundarySource=timeline' \
    'repeat proof records the same timeline boundary source'
assert_eq "$first_idempotent" "$second_idempotent" \
    'repeat proof is byte-for-byte stable'
idempotent_log=$(<"$tmp/idempotent.log")
assert_eq '1' "$(grep -c 'pr edit 7 --repo owner/repo --base main' "$tmp/idempotent.log")" \
    'repeat retarget does not issue another base edit'
assert_not_contains "$idempotent_log" '/rate_limit' \
    'timeline-backed retarget never stamps the boundary from the current clock'

# --- issue #518: refresh code-scanning after a retarget --------------------
# A head-associated workflow run can be safely re-run through the Actions API;
# the helper must never close/reopen the PR to synthesize a pull_request event.
cat >"$tmp/gh-refresh-rerun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        base=parent
        [[ -e $EDIT_STATE ]] && base=main
        printf '%s\n' "{\"number\":7,\"baseRefName\":\"$base\",\"headRefName\":\"feat/child\",\"headRefOid\":\"1111111111111111111111111111111111111111\",\"reviewDecision\":\"APPROVED\",\"reviews\":[],\"statusCheckRollup\":[{\"name\":\"CodeQL\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\",\"createdAt\":\"2024-01-01T00:05:00Z\"}],\"closingIssuesReferences\":[{\"number\":137}]}"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:01:00Z"}]' ;;
    *"actions/runs?head_sha=1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"workflow_runs":[{"id":42,"name":"CodeQL","status":"completed","conclusion":"skipped","head_sha":"1111111111111111111111111111111111111111"}]}'
        ;;
    *"actions/runs/42/rerun"*) : ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-refresh-rerun"
set +e
refresh_rerun_output=$(EDIT_STATE="$tmp/refresh-rerun.state" GH_LOG="$tmp/refresh-rerun.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-refresh-rerun" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
refresh_rerun_rc=$?
set -e
assert_eq '0' "$refresh_rerun_rc" 'a head workflow run can be refreshed after retarget'
assert_contains "$refresh_rerun_output" 'analysis-refresh=rerun workflow=CodeQL' \
    'retarget reports the rerun used to refresh CodeQL'
refresh_rerun_log=$(<"$tmp/refresh-rerun.log")
assert_contains "$refresh_rerun_log" 'actions/runs/42/rerun' \
    'refresh uses the Actions rerun API'
assert_not_contains "$refresh_rerun_log" 'pr close' \
    'refresh never closes the PR to retrigger CodeQL'
assert_not_contains "$refresh_rerun_log" 'pr reopen' \
    'refresh never reopens the PR to retrigger CodeQL'

# A path-filtered workflow with no existing run cannot be manufactured by an
# agent. It must name the missing dispatch capability and the exact human step.
cat >"$tmp/gh-refresh-missing" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        base=parent
        [[ -e $EDIT_STATE ]] && base=main
        printf '%s\n' "{\"number\":7,\"baseRefName\":\"$base\",\"headRefName\":\"feat/child\",\"headRefOid\":\"1111111111111111111111111111111111111111\",\"reviewDecision\":\"APPROVED\",\"reviews\":[],\"statusCheckRollup\":[{\"name\":\"CodeQL\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\",\"createdAt\":\"2024-01-01T00:05:00Z\"}],\"closingIssuesReferences\":[{\"number\":137}]}"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:01:00Z"}]' ;;
    *"actions/runs?head_sha=1111111111111111111111111111111111111111"*) printf '%s\n' '{"workflow_runs":[]}' ;;
    *"actions/workflows/43/dispatches"*) printf '{"message":"workflow does not support workflow_dispatch","status":422}\n' >&2; exit 1 ;;
    *"actions/workflows"*) printf '%s\n' '{"workflows":[{"id":43,"name":"CodeQL","path":".github/workflows/codeql.yml","state":"active"}]}' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-refresh-missing"
set +e
refresh_missing_output=$(EDIT_STATE="$tmp/refresh-missing.state" GH_LOG="$tmp/refresh-missing.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-refresh-missing" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
refresh_missing_rc=$?
set -e
assert_eq '2' "$refresh_missing_rc" 'an untriggerable workflow stops after the retarget mutation'
assert_contains "$refresh_missing_output" 'cannot-trigger: CodeQL has no dispatch' \
    'missing dispatch capability is named explicitly'
assert_contains "$refresh_missing_output" 'human action:' \
    'missing dispatch reports the exact human action'
refresh_missing_log=$(<"$tmp/refresh-missing.log")
assert_not_contains "$refresh_missing_log" 'pr close' \
    'an untriggerable scan never closes the PR'
assert_not_contains "$refresh_missing_log" 'pr reopen' \
    'an untriggerable scan never reopens the PR'
# --- REST timeline events may omit the changed ref -------------------------
# The REST representation of a base_ref_changed event carries the event kind
# and timestamp, but not always the ref. A ref-less event is still authoritative
# for this retarget; when a ref is present, timeline_boundary must continue to
# require the requested base.
cat >"$tmp/gh-rest-ref-less" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0}'
        ;;
    *"timeline"*)
        # This mirrors the REST payload: no base_ref/base_ref_name field.
        printf '%s\n' '[{"event":"base_ref_changed","created_at":"2024-01-01T00:00:00Z","performed_via_github_app":null}]'
        ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-rest-ref-less"
set +e
ref_less_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-rest-ref-less" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
ref_less_rc=$?
set -e
assert_eq '0' "$ref_less_rc" 'a REST base_ref_changed event without a ref proves the retarget boundary'
assert_contains "$ref_less_output" 'boundarySource=timeline' \
    'a ref-less REST event is accepted as the authoritative boundary'
metadata_evidence=$(git -C "$repo" rev-parse --path-format=absolute --git-path chain-advance-evidence)/chain-advance-pr-7-base-main.json
assert_eq 'yes' "$( [[ -f $metadata_evidence && ! -L $metadata_evidence ]] && printf yes || printf no )" \
    'retarget evidence is persisted as a regular file under Git metadata'
assert_eq 'no' "$( [[ -e $repo/.agent/evidence/chain-advance-pr-7-base-main.json ]] && printf yes || printf no )" \
    'successful retarget evidence is not written beneath the caller-controlled worktree'

# --- unlabeled CI evidence cannot disappear into an empty diagnostic ----------
cat >"$tmp/gh-unnamed-check" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":9,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":null,"reviews":[],"statusCheckRollup":[{"status":"COMPLETED","conclusion":"SUCCESS"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-unnamed-check"
set +e
unnamed_check_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-unnamed-check" \
    bash "$advance" --retarget --repo owner/repo --pr 9 --base main 2>&1)
unnamed_check_rc=$?
set -e
assert_eq '1' "$unnamed_check_rc" \
    'a timestamp-less unlabeled CI rollup entry blocks the retarget'
assert_contains "$unnamed_check_output" 'unnamed check' \
    'unlabeled CI evidence receives a nonempty diagnostic label'

# --- current-head checks still require a post-retarget timestamp ------------
cat >"$tmp/gh-current-head-stale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"tests","headSha":"1111111111111111111111111111111111111111","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2023-12-31T23:00:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-current-head-stale"
set +e
current_head_stale_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-current-head-stale" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
current_head_stale_rc=$?
set -e
assert_eq '1' "$current_head_stale_rc" \
    'a check tied to the current head is stale when its timestamp predates retarget'
assert_contains "$current_head_stale_output" 'predates the retarget' \
    'current-head stale CI reports its timestamp provenance'

# Empty timestamp fields must not mask a later populated fallback field.
cat >"$tmp/gh-empty-start-fresh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":null,"reviews":[],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"","createdAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","created_at":"2024-01-01T00:00:00Z"}]' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-empty-start-fresh"
set +e
empty_start_fresh_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-empty-start-fresh" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
empty_start_fresh_rc=$?
set -e
assert_eq '0' "$empty_start_fresh_rc" \
    'a later populated CI timestamp remains fresh when an earlier field is empty'
assert_contains "$empty_start_fresh_output" 'retargeted pr #7' \
    'fresh fallback timestamp permits the retarget proof to complete'

# --- worktree-controlled .agent evidence cannot substitute for metadata ------
mkdir -p "$repo/.agent/evidence"
cat >"$repo/.agent/evidence/chain-advance-pr-8-base-main.json" <<'EOF'
{"pr":8,"base":"main","headSha":"1111111111111111111111111111111111111111","boundaryEpoch":4102444800}
EOF
# A zero epoch is not a valid forge timestamp and cannot be used as retry
# provenance, even when it is placed under Git metadata.
metadata_zero=$(git -C "$repo" rev-parse --path-format=absolute --git-path chain-advance-evidence)/chain-advance-pr-8-base-main.json
mkdir -p "${metadata_zero%/*}"
printf '%s\n' '{"pr":8,"base":"main","headSha":"1111111111111111111111111111111111111111","boundaryEpoch":0}' >"$metadata_zero"
# Even if an attacker commits the worktree-controlled evidence, it remains
# outside Git's metadata and must not become a persisted boundary.
git -C "$repo" add -f .agent/evidence/chain-advance-pr-8-base-main.json
git -C "$repo" commit -qm attacker-evidence
cat >"$tmp/gh-no-timeline" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr view "*)
        printf '%s\n' '{"number":8,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","createdAt":"2024-01-01T00:05:00Z"}],"reviews":[],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) exit 23 ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-no-timeline"
set +e
worktree_evidence_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-no-timeline" \
    bash "$advance" --retarget --repo owner/repo --pr 8 --base main 2>&1)
worktree_evidence_rc=$?
set -e
assert_eq '1' "$worktree_evidence_rc" \
    'a committed or worktree .agent evidence file cannot replace forge provenance'
assert_contains "$worktree_evidence_output" 'evidence provenance is unavailable' \
    'untrusted worktree evidence is ignored when the timeline is unavailable'

# Existing metadata evidence paths are also a trust boundary: a symlink there
# must not redirect persistence into an attacker-controlled directory.
metadata_dir=${metadata_evidence%/*}
mv -- "$metadata_dir" "$tmp/metadata-backup"
ln -s -- "$tmp/attacker-evidence" "$metadata_dir"
set +e
metadata_symlink_output=$(cd -- "$repo" && PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-rest-ref-less" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
metadata_symlink_rc=$?
set -e
assert_eq '1' "$metadata_symlink_rc" \
    'metadata evidence persistence fails closed at a symlink boundary'
assert_contains "$metadata_symlink_output" 'could not persist the retarget boundary evidence' \
    'symlinked metadata evidence names the persistence failure'
rm -- "$metadata_dir"
mv -- "$tmp/metadata-backup" "$metadata_dir"

# --- PR #536 F1/F2: stale scan evidence drives refresh across retries -------
# A skipped CodeQL check from before the retarget boundary is not post-retarget
# evidence. The first invocation refreshes it, then rejects the unchanged
# stale proof; a second invocation (with RETARGET_APPLIED reset) must make the
# same refresh decision from the durable stale evidence rather than bypassing it.
cat >"$tmp/gh-stale-scan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        base=parent
        [[ -e $EDIT_STATE ]] && base=main
        printf '%s\n' "{\"number\":7,\"baseRefName\":\"$base\",\"headRefName\":\"feat/child\",\"headRefOid\":\"1111111111111111111111111111111111111111\",\"reviewDecision\":null,\"reviews\":[],\"statusCheckRollup\":[{\"name\":\"CodeQL\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\",\"createdAt\":\"2024-01-01T00:00:00Z\"},{\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"createdAt\":\"2024-01-01T00:05:00Z\"}],\"closingIssuesReferences\":[{\"number\":137}]}"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:01:00Z"}]' ;;
    *"actions/runs?head_sha=1111111111111111111111111111111111111111"*) printf '%s\n' '{"workflow_runs":[{"id":42,"name":"CodeQL","status":"completed","conclusion":"skipped","head_sha":"1111111111111111111111111111111111111111"}]}' ;;
    *"actions/runs/42/rerun"*) : ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-stale-scan"
: >"$tmp/stale-scan.log"
set +e
stale_first_out=$(EDIT_STATE="$tmp/stale-scan.state" GH_LOG="$tmp/stale-scan.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-stale-scan" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
stale_first_rc=$?
stale_second_out=$(EDIT_STATE="$tmp/stale-scan.state" GH_LOG="$tmp/stale-scan.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-stale-scan" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
stale_second_rc=$?
set -e
assert_eq '2' "$stale_first_rc" 'pre-retarget skipped scan evidence blocks after refresh'
assert_contains "$stale_first_out" 'CI evidence predates the retarget' \
    'stale skipped scan names the missing post-boundary evidence'
assert_eq '1' "$stale_second_rc" 'a retry remains blocked until post-boundary scan evidence exists'
assert_contains "$stale_second_out" 'CI evidence predates the retarget' \
    'retry reports the same stale scan proof failure'
assert_eq '1' "$(grep -c 'pr edit 7 --repo owner/repo --base main' "$tmp/stale-scan.log")" \
    'the stale-scan retry does not re-edit an already-retargeted PR'
assert_eq '2' "$(grep -c 'actions/runs/42/rerun' "$tmp/stale-scan.log")" \
    'durable stale evidence refreshes the scan on both invocations'

# --- PR #536 F3: refresh diagnostics stay off the proof stdout --------------
cat >"$tmp/gh-refresh-output" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
case " $* " in
    *" pr edit "*) : >"$EDIT_STATE" ;;
    *" pr view "*)
        base=parent
        [[ -e $EDIT_STATE ]] && base=main
        printf '%s\n' "{\"number\":7,\"baseRefName\":\"$base\",\"headRefName\":\"feat/child\",\"headRefOid\":\"1111111111111111111111111111111111111111\",\"reviewDecision\":null,\"reviews\":[],\"statusCheckRollup\":[{\"name\":\"CodeQL\",\"status\":\"COMPLETED\",\"conclusion\":\"SKIPPED\",\"createdAt\":\"2024-01-01T00:05:00Z\"},{\"name\":\"tests\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\",\"createdAt\":\"2024-01-01T00:05:00Z\"}],\"closingIssuesReferences\":[{\"number\":137}]}"
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"timeline"*) printf '%s\n' '[{"event":"base_ref_changed","base_ref":"main","created_at":"2024-01-01T00:01:00Z"}]' ;;
    *"actions/runs?head_sha=1111111111111111111111111111111111111111"*) printf '%s\n' '{"workflow_runs":[{"id":42,"name":"CodeQL\\u001b[31m\\nInjected","status":"completed","conclusion":"skipped","head_sha":"1111111111111111111111111111111111111111"}]}' ;;
    *"actions/runs/42/rerun"*) : ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-refresh-output"
set +e
refresh_output_rc=0
EDIT_STATE="$tmp/refresh-output.state" GH_LOG="$tmp/refresh-output.log" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-refresh-output" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main \
    1>"$tmp/refresh-output.stdout" 2>"$tmp/refresh-output.stderr" || refresh_output_rc=$?
set -e
refresh_stdout=$(<"$tmp/refresh-output.stdout")
refresh_stderr=$(<"$tmp/refresh-output.stderr")
assert_eq '0' "$refresh_output_rc" 'successful refresh preserves the retarget proof'
assert_eq '1' "$(wc -l <"$tmp/refresh-output.stdout")" \
    'retarget proof stdout remains exactly one line'
assert_not_contains "$refresh_stdout" 'analysis-refresh=' \
    'refresh diagnostics never appear on proof stdout'
assert_contains "$refresh_stderr" 'analysis-refresh=rerun workflow=' \
    'refresh diagnostics are available on stderr'
assert_not_contains "$refresh_stderr" $'\033' \
    'workflow names are sanitized before diagnostic output'

# --- issue #564: --recover-closed repairs a base_ref_deleted-then-closed PR -

RECOVER_BASE_SHA='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
RECOVER_HEAD_SHA='cafebabecafebabecafebabecafebabecafebabe'

cat >"$tmp/gh-recover" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"
read_state() { grep '^state=' "$RECOVER_STATE_FILE" | cut -d= -f2; }
read_base()  { grep '^base='  "$RECOVER_STATE_FILE" | cut -d= -f2; }
write_state() { sed -i "s/^state=.*/state=$1/" "$RECOVER_STATE_FILE"; }
write_base()  { sed -i "s/^base=.*/base=$1/" "$RECOVER_STATE_FILE"; }
case " $* " in
*" api repos/owner/repo/pulls/20 "*)
    printf '{"number":20,"merged":%s,"state":"%s","head":{"sha":"%s","ref":"feat/issue-548"},"base":{"ref":"%s","sha":"%s"}}\n' \
        "${RECOVER_MERGED:-false}" "$(read_state)" "$RECOVER_HEAD_SHA" \
        "$(read_base)" "$RECOVER_BASE_SHA"
    ;;
*" api --method POST repos/owner/repo/git/refs "*)
    if [[ " $* " == *' -f ref=refs/heads/feat/issue-546 '* &&
          " $* " == *" -f sha=$RECOVER_BASE_SHA "* ]]; then
        if [[ ${RECOVER_REF_EXISTS:-0} == 1 ]]; then
            printf 'Reference already exists\n' >&2
            exit 1
        fi
        printf '{"ref":"refs/heads/feat/issue-546"}\n'
    else
        printf 'unexpected ref create args: %s\n' "$*" >&2
        exit 1
    fi
    ;;
*" api repos/owner/repo/git/ref/heads/feat/issue-546 "*)
    printf '{"object":{"sha":"%s"}}\n' "$RECOVER_BASE_SHA"
    ;;
*" api --method PATCH repos/owner/repo/pulls/20 -f state=open "*)
    write_state open
    printf '{}\n'
    ;;
*" api --method PATCH repos/owner/repo/pulls/20 -f base=main "*)
    write_base main
    printf '{}\n'
    ;;
*" api --method DELETE repos/owner/repo/git/refs/heads/feat/issue-546 "*)
    printf '{}\n'
    ;;
*)
    printf 'unexpected gh call: %s\n' "$*" >&2
    exit 23
    ;;
esac
EOF
chmod +x "$tmp/gh-recover"

printf 'state=closed\nbase=feat/issue-546\n' >"$tmp/recover-state"
recover_out=$(RECOVER_STATE_FILE="$tmp/recover-state" RECOVER_HEAD_SHA="$RECOVER_HEAD_SHA" \
    RECOVER_BASE_SHA="$RECOVER_BASE_SHA" GH_LOG="$tmp/gh-recover.log" \
    CHAIN_ADVANCE_GH="$tmp/gh-recover" bash "$advance" \
    --recover-closed --repo owner/repo --pr 20 --base main)
assert_eq "recovered pr #20 base=main head=feat/issue-548 sha=$RECOVER_HEAD_SHA" "$recover_out" \
    'recover-closed reports the recovered PR, base, head, and SHA'
recover_log=$(<"$tmp/gh-recover.log")
assert_contains "$recover_log" 'git/refs -f ref=refs/heads/feat/issue-546' \
    'recover-closed recreates the deleted base ref at its recorded name'
assert_contains "$recover_log" '--method PATCH repos/owner/repo/pulls/20 -f state=open' \
    'recover-closed reopens the PR against the recreated base'
assert_contains "$recover_log" '--method PATCH repos/owner/repo/pulls/20 -f base=main' \
    'recover-closed retargets the reopened PR to the merge target'
assert_contains "$recover_log" '--method DELETE repos/owner/repo/git/refs/heads/feat/issue-546' \
    'recover-closed deletes the temporary ref once retargeted'
assert_eq 'open' "$(grep '^state=' "$tmp/recover-state" | cut -d= -f2)" \
    'the recovered PR ends up open'
assert_eq 'main' "$(grep '^base=' "$tmp/recover-state" | cut -d= -f2)" \
    'the recovered PR ends up based on the merge target'

# Idempotent: already open on the target base is a no-op success, never a
# second round of ref-recreate/reopen/retarget/delete calls.
printf 'state=open\nbase=main\n' >"$tmp/recover-state"
: >"$tmp/gh-recover.log"
already_open_out=$(RECOVER_STATE_FILE="$tmp/recover-state" RECOVER_HEAD_SHA="$RECOVER_HEAD_SHA" \
    RECOVER_BASE_SHA="$RECOVER_BASE_SHA" GH_LOG="$tmp/gh-recover.log" \
    CHAIN_ADVANCE_GH="$tmp/gh-recover" bash "$advance" \
    --recover-closed --repo owner/repo --pr 20 --base main)
assert_eq "recovered pr #20 base=main head=feat/issue-548 sha=$RECOVER_HEAD_SHA already-open" \
    "$already_open_out" 'an already-recovered PR reports a no-op success'
assert_eq '0' "$(grep -c 'git/refs' "$tmp/gh-recover.log" || true)" \
    'an already-open PR on the target base makes no mutating calls'

# An open PR based on something other than the requested target is not a
# recover-closed case at all (it may be mid-flight for an unrelated reason);
# refuse rather than guess at a destructive retarget/delete.
printf 'state=open\nbase=feat/issue-546\n' >"$tmp/recover-state"
: >"$tmp/gh-recover.log"
set +e
open_wrong_base_out=$(RECOVER_STATE_FILE="$tmp/recover-state" RECOVER_HEAD_SHA="$RECOVER_HEAD_SHA" \
    RECOVER_BASE_SHA="$RECOVER_BASE_SHA" GH_LOG="$tmp/gh-recover.log" \
    CHAIN_ADVANCE_GH="$tmp/gh-recover" bash "$advance" \
    --recover-closed --repo owner/repo --pr 20 --base main 2>&1)
open_wrong_base_rc=$?
set -e
assert_eq '1' "$open_wrong_base_rc" \
    'an open PR based on something other than the target refuses'
assert_contains "$open_wrong_base_out" 'is open but based on feat/issue-546, not main' \
    'the refusal names the unexpected live base'
assert_eq '0' "$(grep -c 'git/refs' "$tmp/gh-recover.log" || true)" \
    'an open-but-wrong-base PR makes no mutating calls'

# A merged PR is never a recover-closed candidate.
printf 'state=closed\nbase=feat/issue-546\n' >"$tmp/recover-state"
: >"$tmp/gh-recover.log"
set +e
merged_recover_out=$(RECOVER_STATE_FILE="$tmp/recover-state" RECOVER_HEAD_SHA="$RECOVER_HEAD_SHA" \
    RECOVER_BASE_SHA="$RECOVER_BASE_SHA" RECOVER_MERGED=true \
    GH_LOG="$tmp/gh-recover.log" CHAIN_ADVANCE_GH="$tmp/gh-recover" bash "$advance" \
    --recover-closed --repo owner/repo --pr 20 --base main 2>&1)
merged_recover_rc=$?
set -e
assert_eq '1' "$merged_recover_rc" 'recovery refuses an already-merged PR'
assert_contains "$merged_recover_out" 'already merged' \
    'the merged refusal names the reason'
assert_eq '0' "$(grep -c 'git/refs' "$tmp/gh-recover.log" || true)" \
    'an already-merged PR makes no mutating calls'

# A retried recreate that hits an existing ref reuses it only when the
# existing ref already points at the recorded SHA -- never a naming collision
# silently overwritten.
printf 'state=closed\nbase=feat/issue-546\n' >"$tmp/recover-state"
: >"$tmp/gh-recover.log"
retry_create_out=$(RECOVER_STATE_FILE="$tmp/recover-state" RECOVER_HEAD_SHA="$RECOVER_HEAD_SHA" \
    RECOVER_BASE_SHA="$RECOVER_BASE_SHA" RECOVER_REF_EXISTS=1 \
    GH_LOG="$tmp/gh-recover.log" CHAIN_ADVANCE_GH="$tmp/gh-recover" bash "$advance" \
    --recover-closed --repo owner/repo --pr 20 --base main)
assert_eq "recovered pr #20 base=main head=feat/issue-548 sha=$RECOVER_HEAD_SHA" "$retry_create_out" \
    'recreating an already-existing ref at the same recorded SHA still succeeds'

# -- issue #567 fix batch #2: the retarget lineage hook's review-ledger.sh
#    cover call site -- F3 (restrict coverage to the adversarial entry) and
#    F4 (flatten multi-page gh api output into one JSON array). The hook's
#    own gh/script resolution makes a full functional stub impractical here
#    (its sibling-script path is hardcoded, not overridable), so this pins
#    the exact recipe shape the way this suite's other cross-file contracts
#    already do.
# shellcheck disable=SC2016  # single-quoted on purpose: these are literal
# sed patterns matching the shell metacharacters in the source text itself,
# never meant to expand here.
cover_call_block=$(sed -n '/"\$script" cover/,/repo-root "\$repo_root"/p' "$advance" | tr '\n' ' ')
assert_contains "$cover_call_block" '--kind adversarial' \
    'F3: the cover_retarget_lineage cover call restricts coverage to the adversarial-kind entry'
# shellcheck disable=SC2016
gh_comments_call_block=$(sed -n '/"\$GH_BIN" api "repos\/\$repo\/issues\/\$pr\/comments"/,/Accept: application\/vnd.github+json/p' "$advance" | tr '\n' ' ')
assert_contains "$gh_comments_call_block" '--slurp' \
    'F4: the retarget lineage hook slurps every gh api page into one wrapper array'
assert_contains "$gh_comments_call_block" "--jq 'add'" \
    "F4: the retarget lineage hook flattens the slurped pages with gh's own jq add"

finish
