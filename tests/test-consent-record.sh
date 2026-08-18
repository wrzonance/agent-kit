#!/usr/bin/env bash
# Boundary coverage for the executable cross-provider consent record.
set -uo pipefail

TEST_NAME='consent-record'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

state_dir="$tmp/state"
mkdir -- "$state_dir"
chmod 700 -- "$state_dir"
diff_one="$tmp/diff-one"
diff_two="$tmp/diff-two"
printf '%s\n' 'exact diff bytes one' >"$diff_one"
printf '%s\n' 'exact diff bytes two' >"$diff_two"

payload_one="acme/widget:24:$(sha256sum -- "$diff_one" | awk '{print $1}')"
payload_two="acme/widget:24:$(sha256sum -- "$diff_two" | awk '{print $1}')"
state="$state_dir/record"

# Payload identity is derived from the repository, PR number and exact diff bytes.
out=$(/bin/bash "$script" payload --repo acme/widget --pr 24 --diff "$diff_one")
assert_eq "$payload_one" "$out" 'payload derives the repo, PR and exact diff hash'
assert_not_contains "$out" "$payload_two" 'changed diff bytes change the payload identity'

# PR numbers are only unique within one repository. Identical bytes under the
# same number in a second repository must NOT derive the same payload, or a
# reused record would satisfy check for a repository never disclosed.
other_repo_payload=$(/bin/bash "$script" payload --repo acme/other --pr 24 --diff "$diff_one")
assert_eq differ \
    "$( [[ $out != "$other_repo_payload" ]] && printf differ || printf same )" \
    'the same PR number and diff bytes in another repository derive a different payload'
# Granted for acme/widget in its own record, so the rejection below can only be
# the repository mismatch -- not a missing state file and not a changed digest.
cross_state="$state_dir/cross-repo-record"
/bin/bash "$script" grant --state "$cross_state" --provider anthropic \
    --payload "$out" --source interactive >/dev/null
assert_rc 10 'consent granted for one repository does not check out for another' -- \
    /bin/bash "$script" check --state "$cross_state" --provider anthropic \
    --payload "$other_repo_payload"
missing_repo_error=''
missing_repo_rc=0
missing_repo_error=$(/bin/bash "$script" payload --pr 24 --diff "$diff_one" 2>&1) || missing_repo_rc=$?
assert_eq 2 "$missing_repo_rc" 'payload refuses a missing repository'
assert_contains "$missing_repo_error" 'Usage:' \
    'missing repository rejection includes a copyable payload recipe'
assert_rc 2 'payload refuses a repository carrying the payload delimiter' -- \
    /bin/bash "$script" payload --repo 'acme/wid:get' --pr 24 --diff "$diff_one"

# Disclosure is informational only and cannot create consent state.
disclosure=$(/bin/bash "$script" disclose --payload "$payload_one" \
    --destination 'Anthropic via Claude' --purpose 'one adversarial review of that diff')
assert_contains "$disclosure" "payload=$payload_one" 'disclose prints the source payload'
assert_contains "$disclosure" 'destination=Anthropic via Claude' 'disclose prints the destination'
assert_contains "$disclosure" 'purpose=one adversarial review of that diff' 'disclose prints the purpose'
assert_eq no "$( [[ ! -e $state ]] && printf no || printf yes )" \
    'disclose has no state side effect'

# Grant accepts only an explicit source and persists a secure exact record.
grant=$(/bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --source interactive)
expected="cross_provider_consent=anthropic;scope=PR-diff;payload=$payload_one;status=granted;source=interactive"
assert_eq "$expected" "$(<"$state")" 'grant persists the exact consent record'
assert_eq 600 "$(stat -c %a -- "$state")" 'grant secures the record at mode 0600'
assert_eq "$expected" "$grant" 'grant prints the persisted record'

assert_rc 0 'check accepts an exact provider and payload' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_one"
assert_rc 10 'check rejects a changed payload' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_two"
assert_rc 10 'check rejects a changed provider' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_one"

# A second explicit grant may use the orchestrator's invocation-line source.
grant=$(/bin/bash "$script" grant --state "$state" --provider openai \
    --payload "$payload_two" --source auto-review-flag)
assert_contains "$grant" 'source=auto-review-flag' 'auto-review source is recorded explicitly'
assert_rc 0 'check accepts the explicitly granted replacement payload' -- \
    /bin/bash "$script" check --state "$state" --provider openai --payload "$payload_two"
assert_rc 10 'the prior payload is not reusable after replacement' -- \
    /bin/bash "$script" check --state "$state" --provider anthropic --payload "$payload_one"

# There is no implicit yes/auto-grant path, and invalid source values do not
# alter an existing record.
before=$(<"$state")
invalid_source_error=''
invalid_source_rc=0
invalid_source_error=$(/bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --source yes 2>&1) || invalid_source_rc=$?
assert_eq 2 "$invalid_source_rc" 'grant rejects an unrecognized source'
assert_contains "$invalid_source_error" 'Usage:' \
    'invalid source rejection includes a copyable grant recipe'
assert_eq "$before" "$(<"$state")" 'invalid source leaves the existing record unchanged'
assert_rc 2 'grant rejects a --yes shortcut' -- \
    /bin/bash "$script" grant --state "$state" --provider anthropic \
    --payload "$payload_one" --yes

# State failures fail closed and never become a valid check.
missing_state="$state_dir/missing/prN/state/record"
assert_rc 10 'check fails closed when state is unavailable' -- \
    /bin/bash "$script" check --state "$missing_state" --provider openai --payload "$payload_two"
missing_grant=''
missing_grant_rc=0
old_umask=$(umask)
umask 022
missing_grant=$(/bin/bash "$script" grant --state "$missing_state" --provider openai \
    --payload "$payload_two" --source interactive) || missing_grant_rc=$?
umask "$old_umask"
assert_eq 0 "$missing_grant_rc" 'grant creates missing nested private state parents'
assert_contains "$missing_grant" 'source=interactive' \
    'grant reports the newly persisted nested state record'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing")" \
    'grant secures the first missing state parent despite umask'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing/prN")" \
    'grant secures the second missing state parent despite umask'
assert_eq 700 "$(stat -c %a -- "$state_dir/missing/prN/state")" \
    'grant secures the nested state parent despite umask'
assert_eq 600 "$(stat -c %a -- "$missing_state")" \
    'grant secures the consent record after creating its parent'

symlink_state="$state_dir/symlink-record"
ln -s -- "$state" "$symlink_state"
assert_rc 10 'check rejects a state symlink' -- \
    /bin/bash "$script" check --state "$symlink_state" --provider openai --payload "$payload_two"
assert_rc 1 'grant rejects writing through a state symlink' -- \
    /bin/bash "$script" grant --state "$symlink_state" --provider openai \
    --payload "$payload_two" --source interactive

assert_rc 2 'grant rejects field-delimiter injection' -- \
    /bin/bash "$script" grant --state "$state" --provider 'openai;forged' \
    --payload "$payload_two" --source interactive

# The review launchers enforce the check before they can invoke either provider.
launch_dir="$tmp/launch"
mkdir -- "$launch_dir"
chmod 700 -- "$launch_dir"
counter="$launch_dir/provider-invoked"
cat >"$launch_dir/fake-provider" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
touch -- "$FAKE_PROVIDER_MARKER"
EOF
chmod 755 -- "$launch_dir/fake-provider"
for helper in "$claude" "$codex"; do
    launch_err="$launch_dir/$(basename "$helper").err"
    launch_rc=0
    if [[ $helper == *claude* ]]; then
        CLAUDE_EXECUTABLE="$launch_dir/fake-provider" \
            FAKE_PROVIDER_MARKER="$counter" /bin/bash "$helper" \
            --mode review --model claude-test --repo acme/widget --pr 24 --diff "$diff_one" \
            --consent-state "$launch_dir/missing/record" \
            --transcript "$launch_dir/claude.transcript" > /dev/null 2>"$launch_err" || launch_rc=$?
    else
        CODEX_EXECUTABLE="$launch_dir/fake-provider" \
            FAKE_PROVIDER_MARKER="$counter" /bin/bash "$helper" \
            --mode review --model gpt-test --repo acme/widget --pr 24 --diff "$diff_one" \
            --consent-state "$launch_dir/missing/record" \
            --transcript "$launch_dir/codex.transcript" > /dev/null 2>"$launch_err" || launch_rc=$?
    fi
    assert_eq 1 "$launch_rc" "$(basename "$helper") refuses a missing consent check"
    assert_contains "$(<"$launch_err")" 'consent' \
        "$(basename "$helper") reports the consent boundary"
done
assert_eq no "$( [[ ! -e $counter ]] && printf no || printf yes )" \
    'a refused launch never invokes the provider'

finish
