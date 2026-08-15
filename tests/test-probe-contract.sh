#!/usr/bin/env bash
# Contract coverage for capability probes at the review boundary.
set -uo pipefail

TEST_NAME='probe contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"
receipt="$root/agentkit/skills/review-remote-pr/scripts/post-receipt.sh"
reference="$root/agentkit/skills/review-remote-pr/references/adversarial-review.md"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

for helper in "$claude" "$codex"; do
    name=${helper##*/}
    help=$("$helper" --help)
    assert_contains "$help" '--no-payload' "$name help names the explicit probe marker"
    assert_contains "$help" 'synthetic snippet' "$name help describes the synthetic probe payload"
    assert_contains "$help" 'no PR diff' "$name help says probes send no PR diff"

    probe_dir="$tmp/$name"
    mkdir -- "$probe_dir"
    chmod 700 -- "$probe_dir"

    missing_marker_err="$tmp/$name.missing-marker.err"
    missing_marker_rc=0
    if [[ $name == *claude* ]]; then
        bash "$helper" --mode probe --model claude-test \
            --transcript "$probe_dir/missing-marker" --claude /definitely/missing/claude \
            >/dev/null 2>"$missing_marker_err" || missing_marker_rc=$?
    else
        bash "$helper" --mode probe --model gpt-test \
            --transcript "$probe_dir/missing-marker" --codex /definitely/missing/codex \
            >/dev/null 2>"$missing_marker_err" || missing_marker_rc=$?
    fi
    assert_eq 1 "$missing_marker_rc" "$name rejects an unmarked probe invocation"
    assert_contains "$(<"$missing_marker_err")" '--no-payload is required' \
        "$name explains that probes require the explicit marker"

    diff_path="$probe_dir/real.diff"
    printf '%s\n' 'diff --git a/secret b/secret' '+real PR payload' >"$diff_path"
    payload_err="$tmp/$name.payload.err"
    payload_rc=0
    if [[ $name == *claude* ]]; then
        bash "$helper" --mode probe --no-payload --model claude-test \
            --transcript "$probe_dir/payload" --diff "$diff_path" \
            --claude /definitely/missing/claude >/dev/null 2>"$payload_err" || payload_rc=$?
    else
        bash "$helper" --mode probe --no-payload --model gpt-test \
            --transcript "$probe_dir/payload" --diff "$diff_path" \
            --codex /definitely/missing/codex >/dev/null 2>"$payload_err" || payload_rc=$?
    fi
    assert_eq 1 "$payload_rc" "$name rejects a PR diff attached to a probe"
    assert_contains "$(<"$payload_err")" 'cannot include PR review arguments' \
        "$name explains that probes cannot carry a PR diff"

    metadata_err="$tmp/$name.metadata.err"
    metadata_rc=0
    if [[ $name == *claude* ]]; then
        bash "$helper" --mode probe --no-payload --model claude-test \
            --transcript "$probe_dir/metadata" --pr 124 \
            --claude /definitely/missing/claude >/dev/null 2>"$metadata_err" || metadata_rc=$?
    else
        bash "$helper" --mode probe --no-payload --model gpt-test \
            --transcript "$probe_dir/metadata" --pr 124 \
            --codex /definitely/missing/codex >/dev/null 2>"$metadata_err" || metadata_rc=$?
    fi
    assert_eq 1 "$metadata_rc" "$name rejects PR metadata attached to a probe"
    assert_contains "$(<"$metadata_err")" 'cannot include PR review arguments' \
        "$name explains that probes cannot be PR-bound"

    review_err="$tmp/$name.review.err"
    review_rc=0
    if [[ $name == *claude* ]]; then
        bash "$helper" --mode review --no-payload --model claude-test \
            --transcript "$probe_dir/review" --claude /definitely/missing/claude \
            >/dev/null 2>"$review_err" || review_rc=$?
    else
        bash "$helper" --mode review --no-payload --model gpt-test \
            --transcript "$probe_dir/review" --codex /definitely/missing/codex \
            >/dev/null 2>"$review_err" || review_rc=$?
    fi
    assert_eq 1 "$review_rc" "$name rejects the probe marker on a real review"
    assert_contains "$(<"$review_err")" 'only valid in probe mode' \
        "$name explains that real reviews cannot use the probe marker"
done

comments="$tmp/comments.json"
printf '%s\n' '[]' >"$comments"
findings="$tmp/findings.ndjson"
: >"$findings"
receipt_err="$tmp/receipt.err"
receipt_rc=0
"$receipt" publish --pr 150 --repo owner/repo --comments "$comments" \
    --findings-file "$findings" --provider anthropic --model claude-opus-5 \
    --effort high --mode probe --p1 0 --p2 0 --agent-identity 'test' \
    >/dev/null 2>"$receipt_err" || receipt_rc=$?
assert_eq 2 "$receipt_rc" 'receipt publication rejects probe mode'
assert_contains "$(<"$receipt_err")" 'probes never count against the one-review-per-PR budget' \
    'receipt rejection explains that probes do not spend the review budget'

reference_text=$(<"$reference")
assert_contains "$reference_text" '--mode probe --no-payload' \
    'review reference makes probe invocations visibly distinct'
assert_contains "$reference_text" 'only a synthetic snippet' \
    'review reference states the probe payload is synthetic only'
assert_contains "$reference_text" 'no PR diff' \
    'review reference states probes send no PR diff'
assert_contains "$reference_text" 'never count against the one-review-per-PR budget' \
    'review reference states probes do not spend the review budget'

finish
