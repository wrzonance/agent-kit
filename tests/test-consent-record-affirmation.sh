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
    local destination=${5:-'Anthropic via Claude'} grant_purpose=${6:-$purpose}
    bash "$consent" grant --state "$state" --provider "$provider" --payload "$target_payload" \
        --source operator-instruction --operator-instruction "$instruction" \
        --destination "$destination" --model "$model" --purpose "$grant_purpose" \
        --paths-file "$tmp/paths"
}

reported_state="$tmp/state/reported"
reported_out=$(grant_instruction "$reported_state" "$reported" 2>&1)
reported_rc=$?
assert_eq 0 "$reported_rc" 'the reported 2026-09-16 operator instruction grants on the first call'
assert_contains "$reported_out" 'source=operator-instruction' 'the reported instruction retains operator provenance'
assert_eq "$reported" "$(jq -r .instruction "$reported_state.decision.json" 2>/dev/null)" \
    'the reported instruction is retained verbatim'

for mismatch in destination purpose; do
    mismatch_state="$tmp/state/mismatched-$mismatch"
    mismatch_destination='Anthropic via Claude'
    mismatch_purpose=$purpose
    [[ $mismatch == destination ]] && mismatch_destination='Anthropic via Codex'
    [[ $mismatch == purpose ]] && mismatch_purpose='publish the payload to an unrelated destination'
    mismatch_rc=0
    grant_instruction "$mismatch_state" "$reported" claude "$payload" \
        "$mismatch_destination" "$mismatch_purpose" >/dev/null 2>&1 || mismatch_rc=$?
    assert_eq 2 "$mismatch_rc" "a conflicting persisted $mismatch is not authorized"
    assert_eq no "$([[ -e $mismatch_state || -e $mismatch_state.decision.json || -e $mismatch_state.consent-paths ]] && printf yes || printf no)" \
        "a conflicting persisted $mismatch creates no grant evidence"
done

contradictory_state="$tmp/state/contradictory-purpose"
contradictory_rc=0
grant_instruction "$contradictory_state" "$reported" claude "$payload" 'Anthropic via Claude' \
    'adversarial review then publish the payload elsewhere' >/dev/null 2>&1 || contradictory_rc=$?
assert_eq 2 "$contradictory_rc" 'an isolated review token does not validate a contradictory persisted purpose'
assert_eq no "$([[ -e $contradictory_state || -e $contradictory_state.decision.json || -e $contradictory_state.consent-paths ]] && printf yes || printf no)" \
    'a contradictory review-token purpose creates no grant evidence'

assert_rc 0 'configured and versioned destination text retains valid provider/CLI identity' -- \
    grant_instruction "$tmp/state/configured-destination" "$reported" claude "$payload" \
        'Anthropic via Claude Code 2.1 configured reviewer' "$purpose"

# Curly single quotes delimit quoted instructions just like straight quotes.
# Use the exact configured model in the quoted text so this regression can
# fail only at quote stripping, not at the model matcher.
curly_open=$'\u2018' curly_close=$'\u2019'
curly_quote_state="$tmp/state/curly-quoted-instruction"
curly_quote_rc=0
curly_quote_out=$(bash "$consent" grant --state "$curly_quote_state" --provider claude \
    --payload "$payload" --source operator-instruction \
    --operator-instruction "${curly_open}Use Claude Opus 5 for adversarial review.${curly_close}" \
    --destination 'Anthropic via Claude' --model 'Claude Opus 5' --purpose "$purpose" \
    --paths-file "$tmp/paths" 2>&1) || curly_quote_rc=$?
assert_eq 2 "$curly_quote_rc" 'a curly-single-quoted instruction is not executable consent'
assert_contains "$curly_quote_out" 'missing model' \
    'the matching model is absent only after the curly-quoted segment is stripped'
assert_eq no "$([[ -e $curly_quote_state || -e $curly_quote_state.decision.json || -e $curly_quote_state.consent-paths ]] && printf yes || printf no)" \
    'a curly-single-quoted refusal creates no consent evidence'

curly_negation_state="$tmp/state/curly-apostrophe-negation"
curly_negation_rc=0
bash "$consent" grant --state "$curly_negation_state" --provider claude --payload "$payload" \
    --source operator-instruction --operator-instruction "Don${curly_close}t use Claude Opus 5 for adversarial review." \
    --destination 'Anthropic via Claude' --model 'Claude Opus 5' --purpose "$purpose" \
    --paths-file "$tmp/paths" >/dev/null 2>&1 || curly_negation_rc=$?
assert_eq 2 "$curly_negation_rc" 'a curly apostrophe in a negation remains visible to the safety grammar'
assert_eq no "$([[ -e $curly_negation_state || -e $curly_negation_state.decision.json || -e $curly_negation_state.consent-paths ]] && printf yes || printf no)" \
    'a curly-apostrophe negation creates no consent evidence'

curly_model="Claude${curly_close}s Opus 5"
curly_apostrophe_state="$tmp/state/curly-apostrophe-model"
assert_rc 0 'a curly apostrophe between alphanumeric model characters remains valid data' -- \
    bash "$consent" grant --state "$curly_apostrophe_state" --provider claude --payload "$payload" \
        --source operator-instruction --operator-instruction "Use $curly_model for adversarial review." \
        --destination 'Anthropic via Claude' --model "$curly_model" --purpose "$purpose" \
        --paths-file "$tmp/paths"

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

# #896: an imperative turn with ordinary filler words between provider, model
# and purpose grants -- it must not be misdiagnosed as a missing purpose.
issue896_state="$tmp/state/issue-896"
issue896_out=$(bash "$consent" grant --state "$issue896_state" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Have the local codex harness with gpt-6-astra at xhigh effort perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1)
issue896_rc=$?
assert_eq 0 "$issue896_rc" 'the #896 verbatim operator turn grants despite filler words'
assert_contains "$issue896_out" 'source=operator-instruction' 'the #896 grant retains operator provenance'

# The same sentence negated still refuses.
issue896_negated_state="$tmp/state/issue-896-negated"
issue896_negated_rc=0
bash "$consent" grant --state "$issue896_negated_state" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Have the local codex harness with gpt-6-astra at xhigh effort do not perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" >/dev/null 2>&1 || issue896_negated_rc=$?
assert_eq 2 "$issue896_negated_rc" 'a negated form of the #896 turn is still refused'
assert_eq no \
    "$([[ -e $issue896_negated_state || -e $issue896_negated_state.decision.json || -e $issue896_negated_state.consent-paths ]] && printf yes || printf no)" \
    'the negated #896 turn creates no grant evidence'

# #896 fix round: a second real operator turn, with a doubled "have" and no
# clause opener the grammar recognizes at all, must also grant -- the ordered
# check has to work over the whole instruction, not just a stripped clause.
issue896b_state="$tmp/state/issue-896b"
issue896b_out=$(bash "$consent" grant --state "$issue896b_state" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'make sure you have codex have gpt-6-astra xhigh perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1)
issue896b_rc=$?
assert_eq 0 "$issue896b_rc" 'a real turn with a doubled "have" and no recognized opener still grants'
assert_contains "$issue896b_out" 'source=operator-instruction' 'the #896 fix-round grant retains operator provenance'

# The same sentence negated still refuses.
issue896b_negated_state="$tmp/state/issue-896b-negated"
issue896b_negated_rc=0
bash "$consent" grant --state "$issue896b_negated_state" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'make sure you do not have codex have gpt-6-astra xhigh perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" >/dev/null 2>&1 || issue896b_negated_rc=$?
assert_eq 2 "$issue896b_negated_rc" 'a negated form of the second #896 turn is still refused'
assert_eq no \
    "$([[ -e $issue896b_negated_state || -e $issue896b_negated_state.decision.json || -e $issue896b_negated_state.consent-paths ]] && printf yes || printf no)" \
    'the negated second #896 turn creates no grant evidence'

# When provider, model and purpose are all present but out of order, the
# refusal names the real cause instead of misreporting a missing purpose.
unparseable_out=$(bash "$consent" grant --state "$tmp/state/issue-896-unparseable" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Perform an adversarial review using gpt-6-astra hosted via codex' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1)
assert_contains "$unparseable_out" 'could not parse an authorization clause; found provider, model and purpose' \
    'an out-of-order but complete instruction names the real refusal cause'

# #896 P1 (adversarial review): naming provider/model/purpose in order is not
# itself an instruction -- an explanation request must still refuse even
# though every element is present in order.
explain_state="$tmp/state/issue-896-explain"
explain_rc=0
explain_out=$(bash "$consent" grant --state "$explain_state" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'Use codex with gpt-6-astra to explain how to request consent for an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1) || explain_rc=$?
assert_eq 2 "$explain_rc" 'an explanation request is refused even with provider, model and purpose in order'
assert_contains "$explain_out" 'instruction asks for an explanation, not a review' \
    'the explanation refusal names its real cause'
assert_eq no \
    "$([[ -e $explain_state || -e $explain_state.decision.json || -e $explain_state.consent-paths ]] && printf yes || printf no)" \
    'the explanation refusal creates no grant evidence'

# A second explanation phrasing ("tell me how you would do X") also refuses
# with the same message, even though it also contains the performative verb
# "do" -- the inquiry check wins.
tellme_rc=0
tellme_out=$(bash "$consent" grant --state "$tmp/state/issue-896-tellme" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'codex with gpt-6-astra, tell me how you would do an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1) || tellme_rc=$?
assert_eq 2 "$tellme_rc" '"tell me how you would do X" is still an explanation request, not an instruction'
assert_contains "$tellme_out" 'instruction asks for an explanation, not a review' \
    'the "tell me how you would do X" refusal names the same explanation cause'

# A negated form of the doubled-"have" turn refuses with an affirmative-
# specific message, not a misleading "missing purpose" -- ordering and the
# performative verb ("perform") are still present, only the negation blocks it.
not_affirmative_rc=0
not_affirmative_out=$(bash "$consent" grant --state "$tmp/state/issue-896-not-affirmative" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'make sure you have codex have gpt-6-astra xhigh do not perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1) || not_affirmative_rc=$?
assert_eq 2 "$not_affirmative_rc" 'a negated doubled-"have" turn refuses'
assert_contains "$not_affirmative_out" 'instruction is not affirmative' \
    'the negated refusal names its real cause instead of a missing purpose'
assert_eq no \
    "$([[ -e $tmp/state/issue-896-not-affirmative || -e $tmp/state/issue-896-not-affirmative.decision.json \
        || -e $tmp/state/issue-896-not-affirmative.consent-paths ]] && printf yes || printf no)" \
    'the negated refusal creates no grant evidence'

# CodeRabbit (PR #898): deferral or retrospective wording BEFORE the performative verb
# is not a present instruction; a time reference AFTER the verb still is.
deferred_rc=0
deferred_out=$(bash "$consent" grant --state "$tmp/state/issue-896-deferred" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'when we are ready, have codex with gpt-6-astra perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1) || deferred_rc=$?
assert_eq 2 "$deferred_rc" 'a deferred "when we are ready" turn refuses'
assert_contains "$deferred_out" 'instruction is conditional or not a present request' \
    'the deferred refusal names its cause'
retro_rc=0
retro_out=$(bash "$consent" grant --state "$tmp/state/issue-896-retro" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'last time we had codex with gpt-6-astra perform an adversarial review' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths" 2>&1) || retro_rc=$?
assert_eq 2 "$retro_rc" 'a retrospective "last time" turn refuses'
assert_contains "$retro_out" 'instruction is conditional or not a present request' \
    'the retrospective refusal names its cause'
assert_rc 0 'a present request with a time reference after the verb still grants' -- \
    bash "$consent" grant --state "$tmp/state/issue-896-tomorrow" --provider codex \
    --payload "$payload" --source operator-instruction \
    --operator-instruction 'have codex with gpt-6-astra perform an adversarial review tomorrow' \
    --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
    --purpose 'adversarial review' --paths-file "$tmp/paths"

# The two prior #896 grants still hold with the performative-verb bound in place.
assert_rc 0 'the doubled-"have" #896 turn still grants under the performative-verb bound' -- \
    bash "$consent" grant --state "$tmp/state/issue-896b-reverify" --provider codex \
        --payload "$payload" --source operator-instruction \
        --operator-instruction 'make sure you have codex have gpt-6-astra xhigh perform an adversarial review' \
        --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
        --purpose 'adversarial review' --paths-file "$tmp/paths"
assert_rc 0 'the original #896 turn still grants under the performative-verb bound' -- \
    bash "$consent" grant --state "$tmp/state/issue-896-reverify" --provider codex \
        --payload "$payload" --source operator-instruction \
        --operator-instruction 'Have the local codex harness with gpt-6-astra at xhigh effort perform an adversarial review' \
        --destination 'OpenAI via the local codex CLI (gpt-6-astra)' --model gpt-6-astra \
        --purpose 'adversarial review' --paths-file "$tmp/paths"

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
