#!/usr/bin/env bash
set -uo pipefail

TEST_NAME='consent-record-affirmation'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

consent="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -m 700 -- "$tmp/state"
printf 'src/review.sh\n' >"$tmp/paths"

payload="owner/repo:14:$(printf '%064d' 1)"
model='claude-opus-5-xhigh'
purpose='one adversarial review of that diff'
reported='also each PR is authorized to have one Claude Opus 5 xhigh adversarial review on it'

grant_instruction() {
    local state=$1 instruction=$2 provider=${3:-claude} target_payload=${4:-$payload}
    bash "$consent" grant --state "$state" --provider "$provider" --payload "$target_payload" \
        --source operator-instruction --operator-instruction "$instruction" \
        --destination 'Anthropic via Claude' --model "$model" --purpose "$purpose" \
        --paths-file "$tmp/paths"
}

reported_state="$tmp/state/reported"
reported_out=$(grant_instruction "$reported_state" "$reported" 2>&1)
reported_rc=$?
assert_eq 0 "$reported_rc" 'the reported 2026-09-16 operator instruction grants on the first call'
assert_contains "$reported_out" 'source=operator-instruction' 'the reported instruction retains operator provenance'
assert_eq "$reported" "$(jq -r .instruction "$reported_state.decision.json" 2>/dev/null)" \
    'the reported instruction is retained verbatim'

# shellcheck disable=SC1112,SC2016
for case in \
    'Do not authorize Claude Opus 5 xhigh for an adversarial review of each PR.' \
    'This does not authorize Claude Opus 5 xhigh for adversarial review.' \
    'Never use Claude Opus 5 xhigh for adversarial review.' \
    'Authorize anyone except Claude Opus 5 xhigh for adversarial review.' \
    'Authorize Claude Opus 5 xhigh for review without sending the diff.' \
    'The issue says "each PR is authorized to have one Claude Opus 5 xhigh adversarial review".' \
    'The instruction `authorize Claude Opus 5 xhigh for adversarial review` is an example.' \
    "'Use Claude Opus 5 xhigh for adversarial review' is an example." \
    'Each PR is authorized to have one Claude Opus 50 xhigh adversarial review.' \
    'Each PR is authorized to have one Claude Opus 5 xhigh preview.' \
    'PR 99 is authorized to have one Claude Opus 5 xhigh adversarial review.' \
    'Pull request 99 is authorized to have one Claude Opus 5 xhigh adversarial review.' \
    'Another PR is authorized to have one Claude Opus 5 xhigh adversarial review.' \
    'Another pull request is authorized to have one Claude Opus 5 xhigh adversarial review.' \
    'Should we use Claude Opus 5 xhigh for adversarial review?' \
    'Can I use Claude Opus 5 xhigh for adversarial review?' \
    'I have a Claude Opus 5 xhigh adversarial review example.' \
    'Use this sentence as an example: Claude Opus 5 xhigh review.' \
    'I authorize documentation about Claude Opus 5 xhigh review.' \
    'If we approve Claude Opus 5 xhigh for review, what will happen?' \
    'Revoke consent to use Claude Opus 5 xhigh for adversarial review.' \
    'Use Codex instead of Claude Opus 5 xhigh for adversarial review.' \
    'Use Claude Opus 5 xhigh for adversarial review if CI passes.' \
    'Claude Opus 5 xhigh adversarial review is not authorized.' \
    "Claude Opus 5 xhigh adversarial review isn't authorized." \
    'Claude Opus 5 xhigh adversarial review isn’t authorized.' \
    "Don't run anyone's Claude Opus 5 xhigh review; use Codex instead."; do
    case_state="$tmp/state/rejected-$RANDOM"
    case_out=$(grant_instruction "$case_state" "$case" 2>&1)
    case_rc=$?
    assert_eq 2 "$case_rc" 'negated, quoted, partial-token, or wrong-scope text is not consent'
    assert_eq no "$([[ -e $case_state || -e $case_state.decision.json || -e $case_state.consent-paths ]] && printf yes || printf no)" \
        'a rejected instruction creates no consent evidence'
    assert_not_contains "$case_out" 'Usage:' 'an affirmation refusal never prints the usage dump'
    case_lines=$(wc -l <<<"$case_out")
    if ((case_lines <= 3)); then
        _pass 'an affirmation refusal uses at most three lines'
    else
        _fail 'an affirmation refusal uses at most three lines' "got $case_lines lines: $case_out"
    fi
done

partial_provider_rc=0
bash "$consent" grant --state "$tmp/state/partial-provider" --provider reviewer \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Each PR is authorized to have one rereviewer Widget 2 adversarial review.' \
    --destination Reviewer --model 'Widget 2' --purpose "$purpose" --paths-file "$tmp/paths" \
    >/dev/null 2>&1 || partial_provider_rc=$?
assert_eq 2 "$partial_provider_rc" 'provider names require token boundaries'

missing_provider_out=$(bash "$consent" grant --state "$tmp/state/missing-provider" --provider reviewer \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Each PR is authorized to have one Widget 2 adversarial review.' \
    --destination Reviewer --model 'Widget 2' --purpose "$purpose" --paths-file "$tmp/paths" 2>&1)
assert_contains "$missing_provider_out" 'missing provider' 'provider refusal names the missing element'
assert_contains "$missing_provider_out" 'accepted: reviewer' 'provider refusal gives accepted spellings'

missing_model='Each PR is authorized to have one Claude adversarial review.'
missing_model_out=$(grant_instruction "$tmp/state/missing-model" "$missing_model" 2>&1)
assert_contains "$missing_model_out" 'missing model' 'model refusal names the missing element'
assert_contains "$missing_model_out" 'claude-opus-5-xhigh, Opus 5 xhigh' 'model refusal gives accepted spellings'

missing_purpose='Each PR is authorized to have one Claude Opus 5 xhigh analysis.'
missing_purpose_out=$(grant_instruction "$tmp/state/missing-purpose" "$missing_purpose" 2>&1)
assert_contains "$missing_purpose_out" 'missing purpose' 'purpose refusal names the missing element'
assert_contains "$missing_purpose_out" 'adversarial review, review, cross-review' \
    'purpose refusal gives accepted spellings'

# Provider aliases and natural model spellings are token-bounded and provider-specific.
for accepted in \
    'Each PR is authorized to have one anthropic Opus 5 xhigh review.' \
    'Each PR is authorized to have one Opus 5 xhigh cross-review.'; do
    alias_state="$tmp/state/alias-$RANDOM"
    assert_rc 0 'provider token or model family can identify Anthropic' -- \
        grant_instruction "$alias_state" "$accepted"
done

# The OpenAI family follows the same public contract.
openai_state="$tmp/state/openai"
openai_out=$(bash "$consent" grant --state "$openai_state" --provider codex --payload "$payload" \
    --source operator-instruction \
    --operator-instruction 'Each PR is authorized to have one gpt-5.6 xhigh cross-review.' \
    --destination 'OpenAI via Codex' --model 'gpt-5.6-xhigh' --purpose 'cross-review' \
    --paths-file "$tmp/paths" 2>&1)
assert_contains "$openai_out" 'source=operator-instruction' 'the Codex/GPT family is accepted for OpenAI'

# A refused operator-instruction followed by another source keeps its first provenance.
relabel_state="$tmp/state/relabel"
rejected_rc=0
grant_instruction "$relabel_state" 'Claude Opus 5 xhigh adversarial review.' \
    >/dev/null 2>&1 || rejected_rc=$?
assert_eq 2 "$rejected_rc" 'a mention without affirmative authorization is refused'
relabel_out=$(bash "$consent" grant --state "$relabel_state" --provider claude --payload "$payload" \
    --source interactive 2>&1)
relabel_rc=$?
assert_eq 0 "$relabel_rc" 'a later differently sourced grant is not refused'
assert_contains "$relabel_out" 'warning: consent source changed from operator-instruction to interactive' \
    'a relabeled grant prints one warning'
assert_contains "$relabel_out" 'source=interactive;prior-source=operator-instruction;relabeled=true' \
    'a relabeled grant records both the effective and prior source'
assert_rc 0 'truthful provenance does not invalidate the consent record' -- bash "$consent" check \
    --state "$relabel_state" --provider anthropic --payload "$payload"

same_source_state="$tmp/state/same-source"
grant_instruction "$same_source_state" 'Claude Opus 5 xhigh adversarial review.' >/dev/null 2>&1 || :
same_source_out=$(grant_instruction "$same_source_state" "$reported" 2>&1)
assert_not_contains "$same_source_out" 'prior-source=' 'a retry under the original source is not relabeled'

# Provenance never crosses a payload or provider boundary.
other_payload="owner/repo:14:$(printf '%064d' 2)"
payload_state="$tmp/state/other-payload"
grant_instruction "$payload_state" 'Claude Opus 5 xhigh adversarial review.' >/dev/null 2>&1 || :
payload_out=$(bash "$consent" grant --state "$payload_state" --provider claude --payload "$other_payload" \
    --source interactive 2>&1)
assert_not_contains "$payload_out" 'prior-source=' 'a different payload does not inherit refusal provenance'

provider_state="$tmp/state/other-provider"
grant_instruction "$provider_state" 'Claude Opus 5 xhigh adversarial review.' >/dev/null 2>&1 || :
provider_out=$(bash "$consent" grant --state "$provider_state" --provider codex --payload "$payload" \
    --source interactive 2>&1)
assert_not_contains "$provider_out" 'prior-source=' 'a different provider does not inherit refusal provenance'

# Model names and their natural aliases stop at complete version boundaries.
version_state="$tmp/state/model-version"
version_rc=0
bash "$consent" grant --state "$version_state" --provider claude --payload "$payload" \
    --source operator-instruction \
    --operator-instruction 'I authorize Claude Opus 5.1 for adversarial review.' \
    --destination Claude --model 'Opus 5' --purpose 'adversarial review' \
    --paths-file "$tmp/paths" >/dev/null 2>&1 || version_rc=$?
assert_eq 2 "$version_rc" 'Opus 5 authorization does not match Opus 5.1'
assert_rc 0 'the exact Opus 5 natural spelling remains authorized' -- bash "$consent" grant \
    --state "$version_state" --provider claude --payload "$payload" --source operator-instruction \
    --operator-instruction 'I authorize Claude Opus 5 for adversarial review.' \
    --destination Claude --model 'Opus 5' --purpose 'adversarial review' --paths-file "$tmp/paths"

numeric_alias_state="$tmp/state/numeric-alias"
numeric_alias_rc=0
bash "$consent" grant --state "$numeric_alias_state" --provider claude --payload "$payload" \
    --source operator-instruction \
    --operator-instruction 'I authorize Claude for 4 adversarial reviews.' \
    --destination Claude --model 'claude-4' --purpose 'adversarial review' \
    --paths-file "$tmp/paths" >/dev/null 2>&1 || numeric_alias_rc=$?
assert_eq 2 "$numeric_alias_rc" 'a bare numeric alias cannot match an unrelated count'
assert_rc 0 'the complete Claude 4 natural spelling remains authorized' -- bash "$consent" grant \
    --state "$numeric_alias_state" --provider claude --payload "$payload" --source operator-instruction \
    --operator-instruction 'I authorize Claude 4 for adversarial review.' \
    --destination Claude --model 'claude-4' --purpose 'adversarial review' --paths-file "$tmp/paths"

finish
