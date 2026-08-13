#!/usr/bin/env bash
# Suite: cross-provider review consent is disclosed and session-scoped.
set -uo pipefail

TEST_NAME='cross-provider-consent'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skill="$root/agentkit/skills/review-remote-pr/references/adversarial-review.md"
skill_body="$root/agentkit/skills/review-remote-pr/SKILL.md"
review_refs_dir="$root/agentkit/skills/review-remote-pr/references"
readme="$root/README.md"
skill_text=$(cat -- "$skill")
readme_text=$(cat -- "$readme")
# Negative pins must cover the whole split skill (body + all references), not
# just this one reference file -- a banned phrase planted in SKILL.md or a
# sibling reference is just as much a regression as one in this file.
skill_union_text=$(cat -- "$skill_body" "$review_refs_dir"/*.md)

assert_not_contains "$skill_union_text" 'standing authorization for this cross-model review' \
    'repository ownership is not standing authorization'
assert_contains "$skill_text" 'Cross-provider consent — first send per session' \
    'the skill has a dedicated cross-provider consent gate'
assert_contains "$skill_text" 'Repository ownership' \
    'the gate rejects ownership as consent'
assert_contains "$skill_text" 'is not consent to disclose' \
    'the gate states ownership does not authorize disclosure'
assert_contains "$skill_text" 'destination provider' \
    'the disclosure names the destination provider'
assert_contains "$skill_text" 'first cross-provider send in a session' \
    'the gate applies before the first send in a session'
# shellcheck disable=SC2016  # the backticks are literal documentation text
assert_contains "$skill_text" 'cross_provider_consent=<provider>;scope=PR-diff;payload=<payload-id>;status=granted' \
    'approval record binds consent to the exact payload'
assert_contains "$skill_text" 'provider, PR, or diff changes' \
    'a changed PR or diff requires renewed consent'
assert_contains "$skill_text" 'Do not send the diff' \
    'missing or declined consent fails closed'
assert_contains "$readme_text" 'Cross-provider review privacy' \
    'README contains user-facing cross-provider disclosure'
assert_contains "$readme_text" 'Repository ownership is not' \
    'README warns that ownership does not authorize transfer'

# --- executable consent protocol -------------------------------------------
# The repository documents this protocol rather than shipping a consent
# implementation. These test doubles model the process boundary: a sender,
# its session state, and the exact record that authorizes one payload.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
diff_one="$tmp/diff-one"
diff_two="$tmp/diff-two"
printf '%s\n' 'first exact diff bytes' > "$diff_one"
printf '%s\n' 'changed exact diff bytes' > "$diff_two"

reset_consent_session() {
    CONSENT_RECORD=''
    RECORDING_AVAILABLE=yes
    TRANSMISSION_COUNT=0
    TRANSMITTED_PAYLOAD=''
    LAST_PROMPT=''
}

payload_id() {
    local pr=$1 diff=$2 digest
    digest=$(sha256sum -- "$diff" | cut -d ' ' -f1)
    printf '%s:%s' "$pr" "$digest"
}

consent_prompt() {
    local provider=$1 cli=$2
    printf 'This review will send the PR diff (including filenames and code) to %s via %s for the purpose: one adversarial review of that diff. Do you consent to that transfer for this session? (yes/no)' \
        "$provider" "$cli"
}

record_consent() {
    local provider=$1 payload=$2 status=$3
    [[ ${RECORDING_AVAILABLE:-no} == yes ]] || return 1
    [[ $status == granted ]] || return 1
    CONSENT_RECORD="cross_provider_consent=$provider;scope=PR-diff;payload=$payload;status=$status"
}

consent_matches() {
    local provider=$1 payload=$2 expected
    expected="cross_provider_consent=$provider;scope=PR-diff;payload=$payload;status=granted"
    [[ ${CONSENT_RECORD:-} == "$expected" ]]
}

mock_transmit() {
    local payload=$1
    TRANSMISSION_COUNT=$((TRANSMISSION_COUNT + 1))
    TRANSMITTED_PAYLOAD=$payload
}

mock_send_diff() {
    local provider=$1 cli=$2 pr=$3 diff=$4 response=$5 payload
    payload=$(payload_id "$pr" "$diff") || return 1
    LAST_PROMPT=''

    if consent_matches "$provider" "$payload"; then
        mock_transmit "$payload"
        return 0
    fi

    LAST_PROMPT=$(consent_prompt "$provider" "$cli")
    [[ $response == yes ]] || return 1
    record_consent "$provider" "$payload" granted || return 1
    consent_matches "$provider" "$payload" || return 1
    mock_transmit "$payload"
}

# Invalid consent is fail-closed: the sender is never reached.
for response in '' 'yes, send it' 'y' 'no'; do
    reset_consent_session
    rc=0
    mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" "$response" || rc=$?
    assert_eq '1' "$rc" "${response:-missing} consent is rejected"
    assert_eq '0' "$TRANSMISSION_COUNT" "${response:-missing} consent sends nothing"
    assert_eq '' "$CONSENT_RECORD" "${response:-missing} consent is not recorded"
done

# A positive answer cannot authorize transmission if the approval record cannot
# be persisted.
reset_consent_session
RECORDING_AVAILABLE=no
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" yes || rc=$?
assert_eq '1' "$rc" 'unrecordable consent fails closed'
assert_eq '0' "$TRANSMISSION_COUNT" 'unrecordable consent sends nothing'
assert_eq '' "$CONSENT_RECORD" 'unrecordable consent leaves no record'

# A valid first send discloses the source, destination, and purpose, then binds
# the recorded grant to the SHA-256 of the exact diff bytes.
reset_consent_session
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" yes || rc=$?
assert_eq '0' "$rc" 'an unambiguous affirmative answer is accepted'
assert_eq '1' "$TRANSMISSION_COUNT" 'valid consent permits one transmission'
assert_contains "$LAST_PROMPT" 'PR diff (including filenames and code)' \
    'the disclosure names the source payload'
assert_contains "$LAST_PROMPT" 'Anthropic via Claude' \
    'the disclosure names the destination provider and CLI'
assert_contains "$LAST_PROMPT" 'one adversarial review of that diff' \
    'the disclosure states the required purpose'
assert_contains "$LAST_PROMPT" '(yes/no)' \
    'the disclosure asks a direct yes-or-no question'
payload_one=$(payload_id '24' "$diff_one")
hash_one=${payload_one#*:}
assert_eq "24:$hash_one" "$payload_one" \
    'the payload identity binds the PR number to its SHA-256'
assert_eq \
    "cross_provider_consent=Anthropic;scope=PR-diff;payload=$payload_one;status=granted" \
    "$CONSENT_RECORD" 'the exact consent record is persisted'
assert_eq "$payload_one" "$TRANSMITTED_PAYLOAD" \
    'the sender receives the exact consent-bound payload'

# A retry for the same provider, scope, PR, and unchanged diff reuses the
# session record without asking again.
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" '' || rc=$?
assert_eq '0' "$rc" 'an exact same-payload retry reuses consent'
assert_eq '2' "$TRANSMISSION_COUNT" 'the exact same-payload retry transmits'
assert_eq '' "$LAST_PROMPT" 'the exact same-payload retry does not reprompt'

# A changed destination is not covered by the old grant.
rc=0
mock_send_diff 'OpenAI' 'Codex' '24' "$diff_one" '' || rc=$?
assert_eq '1' "$rc" 'a changed destination requires new consent'
assert_eq '2' "$TRANSMISSION_COUNT" 'a changed destination sends nothing without consent'
rc=0
mock_send_diff 'OpenAI' 'Codex' '24' "$diff_one" yes || rc=$?
assert_eq '0' "$rc" 'new consent permits the changed destination'
assert_eq '3' "$TRANSMISSION_COUNT" 'the newly consented destination transmits'

# A changed PR number is also a different payload identity, even when the
# diff bytes are unchanged.
reset_consent_session
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" yes
rc=0
mock_send_diff 'Anthropic' 'Claude' '25' "$diff_one" '' || rc=$?
assert_eq '1' "$rc" 'a changed PR requires renewed consent'
assert_eq '1' "$TRANSMISSION_COUNT" 'a changed PR sends nothing without consent'
rc=0
mock_send_diff 'Anthropic' 'Claude' '25' "$diff_one" yes || rc=$?
assert_eq '0' "$rc" 'renewed consent permits the changed PR'
assert_eq '2' "$TRANSMISSION_COUNT" 'the renewed PR transmits'
payload_pr_change=$(payload_id '25' "$diff_one")
if [[ $payload_one != "$payload_pr_change" ]]; then
    _pass 'changed PR numbers produce a different payload identity'
else
    _fail 'changed PR numbers produce a different payload identity' \
        "payload remained: $payload_one"
fi

# A changed diff gets a different SHA-256 binding and cannot reuse consent.
payload_two=$(payload_id '24' "$diff_two")
if [[ $payload_one != "$payload_two" ]]; then
    _pass 'changed diff bytes produce a different payload identity'
else
    _fail 'changed diff bytes produce a different payload identity' \
        "payload remained: $payload_one"
fi
reset_consent_session
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_one" yes
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_two" '' || rc=$?
assert_eq '1' "$rc" 'a changed payload requires renewed consent'
assert_eq '1' "$TRANSMISSION_COUNT" 'a changed payload sends nothing without consent'
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_two" yes || rc=$?
assert_eq '0' "$rc" 'renewed consent permits the changed payload'
assert_eq '2' "$TRANSMISSION_COUNT" 'the renewed payload transmits'
assert_eq "cross_provider_consent=Anthropic;scope=PR-diff;payload=$payload_two;status=granted" \
    "$CONSENT_RECORD" 'renewed consent records the changed payload'

# Consent is session-scoped: a new session cannot reuse the prior session's
# record, even for the same destination and exact payload.
reset_consent_session
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_two" '' || rc=$?
assert_eq '1' "$rc" 'a new session requires consent again'
assert_eq '0' "$TRANSMISSION_COUNT" 'a new session sends nothing without consent'
rc=0
mock_send_diff 'Anthropic' 'Claude' '24' "$diff_two" yes || rc=$?
assert_eq '0' "$rc" 'new-session consent permits the exact payload'
assert_eq '1' "$TRANSMISSION_COUNT" 'new-session consent transmits once'

finish
