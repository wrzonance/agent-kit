#!/usr/bin/env bash
# Suite: compose-pr-body.sh emits the fixed, file-backed PR body layout.
# shellcheck disable=SC2016  # literal body fixtures must stay unexpanded
set -uo pipefail

TEST_NAME='compose-pr-body'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

compose="$root/agentkit/skills/parallel-issues/scripts/compose-pr-body.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

why="$tmp/why.md"
what="$tmp/what.md"
decisions="$tmp/decisions.md"
testing="$tmp/testing.md"
output="$tmp/body.md"
expected="$tmp/expected.md"

printf '%s\n\n' 'Motivation with `bytes` and $(literal).' >"$why"
printf '%s\n' 'A terse outcome.' >"$what"
printf '%s\n' 'A pivot containing & and backslashes.' >"$decisions"
printf '%s\n' '- [ ] focused check' '- [x] full suite' >"$testing"

printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    '## Why' \
    '' \
    'Motivation with `bytes` and $(literal).' \
    '' \
    '## What' \
    '' \
    'A terse outcome.' \
    '' \
    '## Decisions' \
    '' \
    'A pivot containing & and backslashes.' \
    '' \
    '## Testing' \
    '' \
    '- [ ] focused check' \
    '- [x] full suite' \
    '' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' \
    '' \
    'Closes #137' >"$expected"

assert_rc 0 'composer emits the canonical body' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
if cmp -s "$expected" "$output"; then
    _pass 'canonical body bytes and section order are exact'
else
    _fail 'canonical body bytes and section order are exact' \
        "$(diff -u "$expected" "$output" | head -n 30)"
fi

assert_rc 0 'composer supports stdout output' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna'

blocker_output="$tmp/blocker-body.md"
blocker_file="$tmp/blockers.list"
printf '%s\0' 'addin/AGENTS.md' '.github/workflows/release.yml' \
    'secrets/with,comma.conf' 'secrets/with\slash.conf' >"$blocker_file"
assert_rc 0 'composer accepts protected blocker paths' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --blocker-file "$blocker_file" \
    --agent 'Codex gpt-5.6-luna' --output "$blocker_output"
blocker_text=$(<"$blocker_output")
assert_contains "$blocker_text" '## Operator action required' \
    'a partial-pushed PR body discloses the operator action section'
assert_contains "$blocker_text" '- `addin/AGENTS.md`' \
    'the blocker section names the first protected path'
assert_contains "$blocker_text" '- `.github/workflows/release.yml`' \
    'the blocker section names every protected path'
assert_contains "$blocker_text" '- `secrets/with,comma.conf`' \
    'the blocker section preserves a literal comma in one protected path'
assert_contains "$blocker_text" '- `secrets/with\slash.conf`' \
    'the blocker section preserves a literal backslash in one protected path'
assert_contains "$blocker_text" 'Verification limitation:' \
    'a partial-pushed PR body discloses that retained verification is unbound'
assert_contains "$blocker_text" 'may include the protected worktree paths above' \
    'the limitation states that protected bytes may have affected verification'
assert_rc 1 'composer rejects an unsafe blocker path' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --blocker '../outside' --agent 'Codex gpt-5.6-luna' --output "$output"

assert_rc 1 'composer rejects a zero issue number' -- bash "$compose" \
    --issue 0 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects a missing section file' -- bash "$compose" \
    --issue 137 --why-file "$tmp/missing" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects non-checkbox Testing content' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$what" \
    --agent 'Codex gpt-5.6-luna' --output "$output"
assert_rc 1 'composer rejects an empty agent identity' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --agent '' --output "$output"

# The composer owns the level-two headings. Each prose input must reject a
# caller-supplied heading wherever it appears, and the diagnostic must make the
# one-step repair unambiguous.
for prose_section in why what decisions; do
    heading_file="$tmp/$prose_section-with-heading.md"
    heading="## ${prose_section^}"
    printf '%s\n' 'Valid prose before the mistake.' "$heading" >"$heading_file"
    heading_why=$why
    heading_what=$what
    heading_decisions=$decisions
    printf -v "heading_$prose_section" '%s' "$heading_file"

    heading_err=$(bash "$compose" \
        --issue 137 --why-file "$heading_why" --what-file "$heading_what" \
        --decisions-file "$heading_decisions" --testing-file "$testing" \
        --agent 'Codex gpt-5.6-luna' --output "$output" 2>&1)
    heading_rc=$?
    assert_eq '1' "$heading_rc" \
        "composer rejects a caller-supplied heading in $prose_section prose"
    assert_contains "$heading_err" "$heading_file" \
        "the $prose_section heading refusal names the offending file"
    assert_contains "$heading_err" "$heading" \
        "the $prose_section heading refusal names the duplicated heading"
    assert_contains "$heading_err" 'remove the heading line; compose-pr-body.sh emits it' \
        "the $prose_section heading refusal explains the corrective action"
done

# A paragraph made only of consecutive key=value receipts is machine output,
# even when an earlier paragraph contains valid prose. A prose label in the
# same paragraph remains valid context, avoiding false positives for prose
# that intentionally discusses assignment-shaped values.
for prose_section in why what decisions; do
    metrics_file="$tmp/$prose_section-with-metrics.md"
    printf '%s\n' 'Valid prose before the machine block.' '' \
        'base=origin/main' 'files=3' 'total.insertions=135' >"$metrics_file"
    metrics_why=$why
    metrics_what=$what
    metrics_decisions=$decisions
    printf -v "metrics_$prose_section" '%s' "$metrics_file"

    metrics_err=$(bash "$compose" \
        --issue 137 --why-file "$metrics_why" --what-file "$metrics_what" \
        --decisions-file "$metrics_decisions" --testing-file "$testing" \
        --agent 'Codex gpt-5.6-luna' --output "$output" 2>&1)
    metrics_rc=$?
    assert_eq '1' "$metrics_rc" \
        "composer rejects an unlabelled metrics block in $prose_section prose"
    assert_contains "$metrics_err" "$metrics_file" \
        "the $prose_section metrics refusal names the offending file"
    assert_contains "$metrics_err" 'base=origin/main' \
        "the $prose_section metrics refusal names the first offending line"
    assert_contains "$metrics_err" 'replace the key=value block with prose or add a prose label' \
        "the $prose_section metrics refusal explains the corrective action"
done

labelled_diff_disclosure="$tmp/labelled-diff-disclosure.md"
printf '%s\n' 'A root-approved decision.' '' 'Diff-size disclosure:' \
    'base=origin/main' 'files=3' >"$labelled_diff_disclosure"
assert_rc 0 'composer accepts the canonical labelled diff-size disclosure' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$labelled_diff_disclosure" --testing-file "$testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"

# --- plain "- item" Testing bullets normalize to unchecked checkboxes ------
plain_testing="$tmp/plain-testing.md"
printf '%s\n' '- [x] already a checkbox' '- plain bullet one' '' '- plain bullet two' \
    >"$plain_testing"
normalized_output="$tmp/normalized-body.md"
assert_rc 0 'composer accepts plain "- item" Testing bullets' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$plain_testing" \
    --agent 'Codex gpt-5.6-luna' --output "$normalized_output"
normalized_text=$(<"$normalized_output")
assert_contains "$normalized_text" '- [x] already a checkbox' \
    'an existing checkbox line is passed through unchanged'
assert_contains "$normalized_text" '- [ ] plain bullet one' \
    'a plain bullet normalizes to an unchecked checkbox'
assert_contains "$normalized_text" '- [ ] plain bullet two' \
    'every plain bullet line normalizes independently'
assert_not_contains "$normalized_text" '- plain bullet one' \
    'the normalized line replaces the original plain bullet text'

# A genuinely non-list line mixed in with valid bullets still fails the whole
# composition -- normalization never silently drops or ignores an invalid line.
mixed_invalid_testing="$tmp/mixed-invalid-testing.md"
printf '%s\n' '- [ ] a real checkbox' 'prose that is not a list item at all' \
    >"$mixed_invalid_testing"
assert_rc 1 'a genuinely non-list line still fails composition' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$mixed_invalid_testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output"

# A malformed checkbox attempt (dash, space, bracket -- but not the strict
# "- [ ]"/"- [x]" form) must fail, not be silently normalized into a
# double-bracketed bullet like "- [ ] [z] weird".
malformed_checkbox_testing="$tmp/malformed-checkbox-testing.md"
printf '%s\n' '- [z] weird' >"$malformed_checkbox_testing"
malformed_checkbox_err=$(bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$malformed_checkbox_testing" \
    --agent 'Codex gpt-5.6-luna' --output "$output" 2>&1)
malformed_checkbox_rc=$?
assert_eq '1' "$malformed_checkbox_rc" \
    'a malformed checkbox-like bullet fails composition rather than being normalized'
assert_contains "$malformed_checkbox_err" 'markdown checkbox lines' \
    'the malformed-checkbox refusal names the checkbox requirement'

# A plain bullet whose text happens to start with a markdown link -- "- [text]
# (url)" -- must normalize like any other plain bullet, not trip the malformed-
# checkbox guard above: the bracket in "[CI run]" is link syntax, not a
# checkbox attempt, because it holds more than one character (#554 F3).
link_bullet_testing="$tmp/link-bullet-testing.md"
printf '%s\n' '- [CI run](https://example.test)' >"$link_bullet_testing"
link_bullet_output="$tmp/link-bullet-body.md"
assert_rc 0 'composer accepts a plain bullet starting with a markdown link' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$link_bullet_testing" \
    --agent 'Codex gpt-5.6-luna' --output "$link_bullet_output"
assert_contains "$(<"$link_bullet_output")" '- [ ] [CI run](https://example.test)' \
    'a link-prefixed bullet normalizes to an unchecked checkbox, link intact'

# A single-character bracket -- the actual malformed-checkbox shape -- still
# fails even when a second bracket pair follows on the same line.
malformed_checkbox_with_link="$tmp/malformed-checkbox-with-link-testing.md"
printf '%s\n' '- [z] [CI run](https://example.test)' >"$malformed_checkbox_with_link"
assert_rc 1 'a single-char malformed checkbox still fails, even followed by a link' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$malformed_checkbox_with_link" \
    --agent 'Codex gpt-5.6-luna' --output "$output"

# --- a section file named like an option is a file, not a flag -------------
# The validator hands the path straight to grep. Under GNU grep an unguarded
# `--help` operand is consumed as an option: grep exits 0 with usage text, so a
# whitespace-only Testing section passes validation and emits no checkbox. The
# argument itself must start with `--` to reproduce it, so this runs from the
# directory holding the file and passes a relative path.
optdir=$(mktemp -d "$tmp/optlike.XXXXXX")
printf '   \n' >"$optdir/--help"
cp -- "$why" "$optdir/why.md"
cp -- "$what" "$optdir/what.md"
cp -- "$decisions" "$optdir/decisions.md"
set +e
optlike_output=$(cd -- "$optdir" && bash "$compose" \
    --issue 137 --why-file why.md --what-file what.md \
    --decisions-file decisions.md --testing-file '--help' \
    --agent 'Codex gpt-5.6-luna' --output out.md 2>&1)
optlike_rc=$?
set -e
assert_eq '1' "$optlike_rc" 'a whitespace-only section named --help is rejected, not parsed as an option'
assert_not_contains "$optlike_output" 'Usage: grep' \
    'grep usage text never reaches the output'

# --- worker baseline exclusion is rendered inside Testing ------------------
exclusion="$tmp/baseline-exclusion.md"
printf '%s\n' '- [ ] Baseline exclusion: `demo-test` is unchanged and red on trunk `abc123` (evidence: `.agent/logs/demo-test.log`)' \
    >"$exclusion"
exclusion_body="$tmp/exclusion-body.md"
assert_rc 0 'composer accepts a worker baseline-exclusion file' -- bash "$compose" \
    --issue 137 --why-file "$why" --what-file "$what" \
    --decisions-file "$decisions" --testing-file "$testing" \
    --baseline-exclusion-file "$exclusion" \
    --agent 'Codex gpt-5.6-luna' --output "$exclusion_body"
exclusion_text=$(<"$exclusion_body")
assert_contains "$exclusion_text" '- [ ] Baseline exclusion: `demo-test`' \
    'the worker exclusion is an unchecked Testing box'
assert_contains "$exclusion_text" '`abc123`' \
    'the Testing box carries the chain-base SHA'
testing_idx=$(grep -n '^## Testing$' "$exclusion_body" | head -n1 | cut -d: -f1)
box_idx=$(grep -n 'Baseline exclusion:' "$exclusion_body" | head -n1 | cut -d: -f1)
if [[ -n $testing_idx && -n $box_idx ]] && ((box_idx > testing_idx)); then
    _pass 'the exclusion box is emitted inside the Testing section'
else
    _fail 'the exclusion box is emitted inside the Testing section' \
        "Testing line=$testing_idx exclusion line=$box_idx"
fi

# The normal publication path composes first, then edits the same file through
# gh-body's checkbox transport as verification progresses. Exercise that real
# boundary so a composed body cannot become untickable without this suite
# failing at the public helper.
fake_gh="$tmp/gh"
stored_body="$tmp/stored-body.md"
cat >"$fake_gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1-} == pr && ${2-} == edit ]]; then
    while (($#)); do
        if [[ $1 == --body-file ]]; then
            cp -- "$2" "$GH_STORED_BODY"
            exit 0
        fi
        shift
    done
fi
if [[ ${1-} == api ]]; then
    jq -Rs '{body: .}' <"$GH_STORED_BODY"
    exit 0
fi
exit 22
EOF
chmod +x -- "$fake_gh"
assert_rc 0 'a normal composed PR body is tickable through gh-body' -- \
    env GH_BODY_GH="$fake_gh" GH_STORED_BODY="$stored_body" \
    bash "$root/agentkit/skills/.shared/scripts/gh-body.sh" pr edit 41 \
    --repo owner/repo --body-file "$normalized_output" --tick 'plain bullet one'
assert_contains "$(<"$normalized_output")" '- [x] plain bullet one' \
    'the sanctioned transport ticks a composed Testing checkbox'

finish
