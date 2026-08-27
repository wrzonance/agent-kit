#!/usr/bin/env bash
# Contract coverage for the one-spend adversarial-review receipt.
#
# The receipt/precheck RECIPE (exact heredoc shape, marker rendering, field
# placeholders, transport) now lives in scripts/post-receipt.sh and is pinned
# by tests/test-post-receipt.sh. This suite keeps only what the skill prose
# must still say (the WHAT: the gate exists, its ordering, its no-silent-skip
# guarantee, and that it delegates to post-receipt.sh) -- not how that script
# renders or posts the body.
# shellcheck disable=SC2016  # literal recipe placeholders are assertion data
set -uo pipefail

TEST_NAME='adversarial-review-receipt'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

review="$root/agentkit/skills/review-remote-pr/SKILL.md"
parallel="$root/agentkit/skills/parallel-issues/SKILL.md"
review_text=$(<"$review")
parallel_text=$(<"$parallel")

assert_receipt_contract() {
    local text=$1 label=$2 section normalized
    section=$(awk '
        /^### Adversarial-review receipt:/{capture=1; next}
        capture && /^```/{fenced=!fenced; print; next}
        capture && !fenced && /^#{1,6} /{exit}
        capture{print}
    ' <<<"$text")
    normalized=$(tr '\n' ' ' <<<"$section" | tr -s '[:space:]' ' ')

    assert_contains "$section" 'post-receipt.sh' "$label delegates rendering/posting to post-receipt.sh"
    assert_contains "$section" 'provider' "$label records the reviewer provider"
    assert_contains "$section" 'model' "$label records the reviewer model"
    assert_contains "$section" 'effort' "$label records the reviewer effort"
    assert_contains "$section" 'cross-provider' "$label records cross-provider mode"
    assert_contains "$section" 'blind fallback' "$label records blind fallback mode"
    assert_contains "$section" 'confirmed finding' "$label records confirmed findings"
    assert_contains "$section" 'P1' "$label records severity counts"
    assert_contains "$section" 'fix commit' "$label records fix commit SHAs"
    assert_contains "$section" 'decline rationale' "$label records decline rationale"
    assert_contains "$section" 'verified-skip rationale' "$label records verified skip rationale"
    assert_contains "$section" 'finding-ledger.sh add' "$label records ledger-first disposition capture"
    assert_contains "$section" '--findings-file' "$label publishes from the findings ledger"
    assert_contains "$section" '--require-pushed' "$label enforces pushed fixes at publication"
    assert_contains "$normalized" 'after fixes are pushed' "$label orders receipt after fixes"
    assert_contains "$normalized" 'before draft-phase-complete handoff' "$label orders receipt before handoff"

    # The receipt template itself no longer lives here -- post-receipt.sh
    # renders it, and "exactly one spent marker" is pinned against the rendered
    # body in test-post-receipt.sh ("publish body carries exactly one spent
    # marker") rather than against a heredoc in the prose.
    #
    # Every other script invocation in this tree is gated by the identical
    # two-line guard (see e.g. every gh-pr-state.sh call site), and
    # post-receipt.sh's invocation follows that same house convention rather
    # than re-deriving the full resolver inline. Matched as the COMPLETE guard
    # expression, never as its halves: the directory fragment also occurs inside
    # a helper invocation path and the sentinel can occur in a comment, so
    # matching them independently would accept a block that executes no guard.
    assert_contains "$section" '[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ]' "$label publication executes the full provenance guard"
    assert_contains "$section" 'agentkit unresolved: prepend THE CACHE REHYDRATION block' "$label publication fails loudly without cache rehydration"
}

assert_receipt_contract "$review_text" 'review-remote-pr receipt'
assert_receipt_contract "$parallel_text" 'parallel-issues receipt'

# -- the precheck gate: still mandated, still delegates to the script --------

assert_contains "$review_text" 'post-receipt.sh precheck' \
    'review-remote-pr precheck delegates to post-receipt.sh precheck'
assert_contains "$review_text" 'pr_${PR}_issue_comments.json' \
    'review-remote-pr checks fetched PR comments before launch'
assert_contains "$review_text" 'do not rerun' \
    'review-remote-pr marker precheck prevents double spend'
assert_contains "$review_text" 'no-silent-skip' \
    'review-remote-pr receipt contract rejects silent skips'
assert_contains "$review_text" 'fresh live comments' \
    'review-remote-pr requires fresh recovery evidence before retry'
assert_contains "$review_text" 'consent-record.sh" payload' \
    'review-remote-pr derives the current canonical diff payload before precheck'
assert_contains "$review_text" '--diff-payload "$current_diff_payload"' \
    'review-remote-pr passes the current diff payload into precheck'

assert_contains "$parallel_text" 'post-receipt.sh precheck' \
    'parallel-issues precheck delegates to post-receipt.sh precheck'
assert_contains "$parallel_text" 'pr_${PR}_issue_comments.json' \
    'parallel-issues checks fetched PR comments before launch'
assert_contains "$parallel_text" 'do not rerun' \
    'parallel-issues marker precheck prevents double spend'
assert_contains "$parallel_text" 'no-silent-skip' \
    'parallel-issues receipt contract rejects silent skips'
assert_contains "$parallel_text" 'fresh live comments' \
    'parallel-issues requires fresh recovery evidence before retry'
assert_contains "$parallel_text" 'consent-record.sh" payload' \
    'parallel-issues derives the current canonical diff payload before precheck'
assert_contains "$parallel_text" '--diff-payload "$current_diff_payload"' \
    'parallel-issues passes the current diff payload into precheck'

# Each precheck recipe is a fresh shell boundary. Every value supplied by an
# earlier setup step must therefore be guarded before it is interpolated into
# a helper invocation; an empty path or repository must fail closed.
assert_contains "$parallel_text" '${worktree:?set worktree}' \
    'parallel-issues guards the worktree before deriving the payload'
assert_contains "$parallel_text" '${REPO:?set REPO}' \
    'parallel-issues guards the repository before deriving the payload'
assert_contains "$parallel_text" '${base:?set base}' \
    'parallel-issues guards the base before deriving the payload'
assert_contains "$review_text" '${PR_WORKTREE:?set PR_WORKTREE}' \
    'review-remote-pr guards the worktree before deriving the payload'
assert_contains "$review_text" '${REPO:?set REPO}' \
    'review-remote-pr guards the repository before deriving the payload'
assert_contains "$review_text" '${BASE_BRANCH:?set BASE_BRANCH}' \
    'review-remote-pr guards the base before deriving the payload'

# -- publish delegates to post-receipt.sh publish -----------------------

assert_contains "$review_text" 'post-receipt.sh publish' \
    'review-remote-pr publication delegates to post-receipt.sh publish'
assert_contains "$parallel_text" 'post-receipt.sh publish' \
    'parallel-issues publication delegates to post-receipt.sh publish'

# The old markdown-structural anti-fallthrough check (two separate fenced
# blocks, with assertions that block 1 could not reach gh-comment.sh) pinned
# a safety property the SKILL.md recipe used to own by hand. post-receipt.sh
# publish now owns that property directly -- it runs its own precheck and
# refuses (exit 11) before ever rendering or posting when the marker is
# already present. See test-post-receipt.sh: "publish refuses when already
# spent" and "publish never calls gh-comment.sh when the receipt is already
# spent" for the stronger, code-level replacement of this coverage.

receipt_line=$(grep -n '^### Adversarial-review receipt:' "$review" | cut -d: -f1)
phase_b_line=$(grep -n '^## Step 3 (Phase B):' "$review" | cut -d: -f1)
if [[ $receipt_line =~ ^[0-9]+$ && $phase_b_line =~ ^[0-9]+$ && $receipt_line -lt $phase_b_line ]]; then
    _pass 'review-remote-pr receipt is before the Phase B handoff'
else
    _fail 'review-remote-pr receipt is before the Phase B handoff' \
        "receipt line=${receipt_line:-missing}, phase-b line=${phase_b_line:-missing}"
fi

# -- post-receipt.sh: RUN_DIR addresses the same run directory as ------------
# -- finding-ledger.sh (issue #300) ------------------------------------------
#
# finding-ledger.sh has always addressed the private run directory via the
# RUN_DIR environment variable. post-receipt.sh required an explicit
# --findings-file PATH instead, and a field run drifted between the two: an
# agent set RUN_DIR correctly for finding-ledger.sh, then built
# --findings-file from the wrong root on the very next call. post-receipt.sh
# now accepts RUN_DIR the same way, keeping --findings-file as an explicit
# override, and every existing findings-file validation (ownership,
# regular-file, symlink, JSON schema) still runs unchanged.

script="$root/agentkit/skills/review-remote-pr/scripts/post-receipt.sh"
rd_tmp=$(mktemp -d)
trap 'rm -rf -- "$rd_tmp"' EXIT

rd_marker='<!-- adversarial-review:spent -->'
rd_not_spent="$rd_tmp/not-spent.json"

reset_rd_not_spent() {
    printf '%s\n' '[{"id":1,"body":"just talk, no marker here"}]' >"$rd_not_spent"
}
reset_rd_not_spent

# A stub gh transport, mirroring test-post-receipt.sh's inline stub: echoes
# the posted payload back as the verification GET, so gh-comment.sh's
# byte-compare passes.
cat >"$rd_tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" --input - "* ]]; then
    cat >"$GH_PAYLOAD"
    jq --argjson id 601 --arg url 'https://example.invalid/comments/601' \
        '. + {id: $id, html_url: $url}' "$GH_PAYLOAD"
    exit 0
fi
jq '. + {id: 601}' "$GH_PAYLOAD"
EOF
chmod +x "$rd_tmp/gh"

run_rd_publish() {
    GH_COMMENT_GH="$rd_tmp/gh" GH_PAYLOAD="$rd_tmp/payload.json" "$script" publish "$@"
}

# A valid RUN_DIR: owned, not a symlink, mode 0700, carrying the completed
# adversarial-run.sh result validate_runner_provenance requires.
valid_run_dir="$rd_tmp/run-dir"
mkdir -p "$valid_run_dir"
chmod 700 "$valid_run_dir"
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"m","transcript":"t","verdict":{"verdict":"no_findings","findings":[]}}' \
    >"$valid_run_dir/adversarial.result.json"
chmod 600 -- "$valid_run_dir/adversarial.result.json"

# -- RUN_DIR-derived findings file resolves when --findings-file is omitted --

: >"$valid_run_dir/findings.ndjson"
chmod 600 -- "$valid_run_dir/findings.ndjson"
reset_rd_not_spent
rd_out=$(RUN_DIR="$valid_run_dir" run_rd_publish \
    --pr 301 --repo owner/repo --comments "$rd_not_spent" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5')
rd_rc=$?
assert_eq '0' "$rd_rc" 'publish resolves findings.ndjson from RUN_DIR when --findings-file is omitted'
assert_contains "$rd_out" 'posted id=601' 'RUN_DIR-derived publish reaches the transport'
rd_body=$(jq -r '.body' "$rd_tmp/payload.json")
assert_contains "$rd_body" "$rd_marker" 'RUN_DIR-derived publish body carries the spent marker'

# -- an explicit --findings-file still overrides and still validates --------

override_dir="$rd_tmp/override-dir"
mkdir -p "$override_dir"
chmod 600 "$override_dir" 2>/dev/null || true # deliberately not 0700; never consulted
override_findings="$rd_tmp/override-findings.ndjson"
: >"$override_findings"
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"m","transcript":"t","verdict":{"verdict":"no_findings","findings":[]}}' \
    >"$rd_tmp/adversarial.result.json"
chmod 600 -- "$rd_tmp/adversarial.result.json"
reset_rd_not_spent
override_out=$(RUN_DIR="$override_dir" run_rd_publish \
    --pr 302 --repo owner/repo --comments "$rd_not_spent" --findings-file "$override_findings" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5')
override_rc=$?
assert_eq '0' "$override_rc" \
    '--findings-file overrides a broken RUN_DIR and still passes validation'
assert_contains "$override_out" 'posted id=601' 'the override reaches the transport'
chmod 700 "$override_dir" 2>/dev/null || true

# -- a RUN_DIR failing ownership/symlink/mode checks is refused -------------

bad_mode_dir="$rd_tmp/bad-mode-dir"
mkdir -p "$bad_mode_dir"
chmod 755 "$bad_mode_dir"
reset_rd_not_spent
bad_mode_err=$(RUN_DIR="$bad_mode_dir" run_rd_publish \
    --pr 303 --repo owner/repo --comments "$rd_not_spent" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
bad_mode_rc=$?
assert_eq '1' "$bad_mode_rc" 'a RUN_DIR with the wrong mode is refused'
assert_contains "$bad_mode_err" 'RUN_DIR must have mode 0700' \
    'the wrong-mode refusal names the mode requirement'
assert_contains "$bad_mode_err" 'evidence unavailable' \
    'the wrong-mode refusal fails closed as evidence-unavailable'

symlink_target="$rd_tmp/symlink-target"
mkdir -p "$symlink_target"
chmod 700 "$symlink_target"
symlink_run_dir="$rd_tmp/symlink-dir"
ln -s "$symlink_target" "$symlink_run_dir"
reset_rd_not_spent
symlink_err=$(RUN_DIR="$symlink_run_dir" run_rd_publish \
    --pr 304 --repo owner/repo --comments "$rd_not_spent" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
symlink_rc=$?
assert_eq '1' "$symlink_rc" 'a symlinked RUN_DIR is refused'
assert_contains "$symlink_err" 'RUN_DIR is not an owned directory' \
    'the symlink refusal names the ownership/symlink requirement'
assert_contains "$symlink_err" 'evidence unavailable' \
    'the symlink refusal fails closed as evidence-unavailable'

# -- the refusal message names the expected path -----------------------------
# The field bug: RUN_DIR was set correctly, but --findings-file was built from
# the wrong root on the next call. The refusal must name the RUN_DIR-derived
# path it expected, turning "file not found" into "wrong worktree."

wrong_findings="$rd_tmp/wrong-root-findings.ndjson"
reset_rd_not_spent
wrong_root_err=$(RUN_DIR="$valid_run_dir" run_rd_publish \
    --pr 305 --repo owner/repo --comments "$rd_not_spent" --findings-file "$wrong_findings" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
wrong_root_rc=$?
assert_eq '1' "$wrong_root_rc" \
    'an explicit --findings-file that diverges from RUN_DIR is refused'
assert_contains "$wrong_root_err" "$wrong_findings" \
    'the refusal names the path actually given'
assert_contains "$wrong_root_err" "$valid_run_dir/findings.ndjson" \
    'the refusal names the RUN_DIR-derived path it expected'
assert_contains "$wrong_root_err" 'evidence unavailable' \
    'the wrong-root refusal fails closed as evidence-unavailable'

# -- neither RUN_DIR nor --findings-file is a usage error --------------------

reset_rd_not_spent
unset -v RUN_DIR
neither_err=$(run_rd_publish \
    --pr 306 --repo owner/repo --comments "$rd_not_spent" \
    --provider anthropic --model claude-opus-5 --effort high \
    --mode cross-provider --mode-reason ok --p1 0 --p2 0 \
    --agent-identity 'Claude Opus 5' 2>&1)
neither_rc=$?
assert_eq '2' "$neither_rc" 'publish with neither RUN_DIR nor --findings-file is a usage error'
assert_contains "$neither_err" '--findings-file or RUN_DIR is required' \
    'the usage error names both accepted sources'

finish
