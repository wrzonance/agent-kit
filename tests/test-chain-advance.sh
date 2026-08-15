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
{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}
JSON
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0,"ahead_by":1}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh"

output=$(GH_LOG="$tmp/gh.log" PATH="$tmp:$PATH" \
    bash "$advance" --retarget --repo owner/repo --pr 7 --base main 2>&1)
assert_contains "$output" 'retargeted pr #7' 'retarget reports a verified result'
assert_contains "$output" 'closing-issues=1' 'retarget reports linkage evidence'
log=$(<"$tmp/gh.log")
assert_contains "$log" 'pr edit 7 --repo owner/repo --base main' 'retarget edits the requested base'
assert_contains "$log" 'pr view 7 --repo owner/repo' 'retarget re-reads PR metadata'
assert_contains "$log" 'repos/owner/repo/compare/main...1111111111111111111111111111111111111111' \
    'retarget checks base-to-head ancestry'

cat >"$tmp/gh-sha" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"repos/owner/repo/compare/main...1111111111111111111111111111111111111111"*)
        printf '%s\n' '{"status":"ahead","behind_by":0,"ahead_by":1}'
        ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
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
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-empty"
set +e
empty_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-empty" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
empty_rc=$?
set -e
assert_eq '1' "$empty_rc" 'retarget fails when no CI checks are reported'
assert_contains "$empty_output" 'statusCheckRollup is empty' \
    'empty CI failure names the missing evidence'

cat >"$tmp/gh-stale" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"old-base","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-stale"
set +e
stale_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-stale" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
stale_rc=$?
set -e
assert_eq '1' "$stale_rc" 'retarget fails when GitHub leaves the old base'
assert_contains "$stale_output" 'baseRefName' 'stale base failure names the failed proof'

cat >"$tmp/gh-pending" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"IN_PROGRESS","startedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-pending"
set +e
pending_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-pending" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
pending_rc=$?
set -e
assert_eq '1' "$pending_rc" 'retarget fails when CI is stale or pending'
assert_contains "$pending_output" 'CI' 'pending CI failure is explicit'

cat >"$tmp/gh-old-approval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"2222222222222222222222222222222222222222"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-old-approval"
set +e
approval_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-old-approval" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
approval_rc=$?
set -e
assert_eq '1' "$approval_rc" 'retarget fails when approval is attached to an old head'
assert_contains "$approval_output" 'approval' 'stale approval remains a visible human judgment'

cat >"$tmp/gh-no-link" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2024-01-01T00:05:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-no-link"
set +e
link_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-no-link" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
link_rc=$?
set -e
assert_eq '1' "$link_rc" 'retarget fails when closing linkage is absent'
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
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2023-12-31T23:00:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2023-12-31T23:00:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-prestale"
set +e
prestale_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-prestale" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
prestale_rc=$?
set -e
assert_eq '1' "$prestale_rc" 'retarget refuses CI that predates the retarget on an unchanged head'
assert_contains "$prestale_output" 'predates the retarget' \
    'the refusal names pre-retarget evidence as the cause'
assert_not_contains "$prestale_output" 'retargeted pr #7' \
    'no success line is printed on pre-retarget evidence'

# The same residue on the approval alone is a human judgment, not an auto-pass.
cat >"$tmp/gh-preapproval" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" pr edit "*) exit 0 ;;
    *" pr view "*)
        printf '%s\n' '{"number":7,"baseRefName":"main","headRefName":"feat/child","headRefOid":"1111111111111111111111111111111111111111","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED","submittedAt":"2023-12-31T23:00:00Z","commit":{"oid":"1111111111111111111111111111111111111111"}}],"statusCheckRollup":[{"name":"tests","status":"COMPLETED","conclusion":"SUCCESS","completedAt":"2024-01-01T00:05:00Z"}],"closingIssuesReferences":[{"number":137}]}'
        ;;
    *"compare/main...1111111111111111111111111111111111111111"*) printf '%s\n' '{"status":"ahead","behind_by":0}' ;;
    *"/rate_limit"*) printf 'Date: Mon, 01 Jan 2024 00:00:00 GMT\n' ;;
    *) exit 23 ;;
esac
EOF
chmod +x "$tmp/gh-preapproval"
set +e
preapproval_output=$(PATH="$tmp:$PATH" CHAIN_ADVANCE_GH="$tmp/gh-preapproval" bash "$advance" \
    --retarget --repo owner/repo --pr 7 --base main 2>&1)
preapproval_rc=$?
set -e
assert_eq '1' "$preapproval_rc" 'retarget refuses an approval that predates the retarget'
assert_contains "$preapproval_output" 'human judgment' \
    'the approval residue is reported as a human judgment, not inherited'

finish
