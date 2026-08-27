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

output=$(GH_LOG="$tmp/gh.log" PATH="$tmp:$PATH" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
assert_contains "$output" 'retargeted pr #7' 'retarget reports a verified result'
assert_contains "$output" 'closing-issues=1' 'retarget reports linkage evidence'
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
behind_output=$(GH_LOG="$tmp/gh-behind.log" PATH="$tmp:$PATH" \
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
sha_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-sha" bash "$advance" \
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
empty_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-empty" bash "$advance" \
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
edit_nonzero_output=$(EDIT_STATE="$tmp/edit-nonzero.state" PATH="$tmp:$PATH" \
    CHAIN_ADVANCE_GH="$tmp/gh-edit-nonzero" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
edit_nonzero_rc=$?
set -e
assert_eq '2' "$edit_nonzero_rc" \
    'a nonzero edit that applied the requested base reports mutation'
assert_contains "$edit_nonzero_output" 'applied base=main' \
    'ambiguous edit failure reports the live applied base'
set +e
edit_noop_output=$(EDIT_APPLIES=false EDIT_STATE="$tmp/edit-noop.state" PATH="$tmp:$PATH" \
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
stale_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-stale" bash "$advance" \
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
pending_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-pending" bash "$advance" \
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
approval_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-old-approval" bash "$advance" \
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
link_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-no-link" bash "$advance" \
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
prestale_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-prestale" bash "$advance" \
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
old_check_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-old-check-start" \
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
boundary_output=$(EDIT_STATE="$tmp/boundary-after-edit.state" PATH="$tmp:$PATH" \
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
preapproval_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-preapproval" bash "$advance" \
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
split_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-splitapproval" bash "$advance" \
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
pr440_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-pr440" bash "$advance" \
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
unreadable_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-unreadable-reviews" bash "$advance" \
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
first_idempotent=$(EDIT_STATE="$tmp/idempotent.state" GH_LOG="$tmp/idempotent.log" \
    PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-idempotent" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
first_idempotent_rc=$?
second_idempotent=$(EDIT_STATE="$tmp/idempotent.state" GH_LOG="$tmp/idempotent.log" \
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

finish
