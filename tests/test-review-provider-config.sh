#!/usr/bin/env bash
# Suite: provider capability resolution and safe fallback behavior.
set -uo pipefail

TEST_NAME='review-provider-config'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

resolver="$root/agentkit/skills/.shared/scripts/review-provider-config.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local value=$1 repo=$tmp/repo
    rm -rf -- "$repo"
    mkdir -p -- "$repo/.agent"
    if [[ $value != __missing__ ]]; then
        printf 'AGENT_REVIEW_PROVIDERS=%s\n' "$value" > "$repo/.agent/config.env"
    fi
    printf '%s' "$repo"
}

repo=$(make_repo 'coderabbit,github-code-quality')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq $'provider=coderabbit mode=triggerable source=declared\nprovider=github-code-quality mode=observe-only source=declared' \
    "$out" 'declared providers resolve to their capability modes'
assert_eq '' "$(<"$tmp/err")" 'valid declarations are silent'

repo=$(make_repo 'coderabbit,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'duplicate providers fall back to one disabled plan'

repo=$(make_repo none)
out=$(bash "$resolver" --repo-root "$repo")
assert_eq 'provider=none mode=disabled source=declared' "$out" \
    'none is an explicit disabled plan'

repo=$(make_repo 'none,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'mixed none declarations fall back to a disabled plan'
assert_contains "$(<"$tmp/err")" 'invalid value for AGENT_REVIEW_PROVIDERS' \
    'mixed none declarations explain the rejection'

repo=$(make_repo 'coderabbit,')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a trailing delimiter is rejected rather than silently dropped'

repo=$(make_repo 'none,')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a trailing delimiter after none is rejected rather than silently dropped'

repo=$(make_repo ',coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a leading delimiter is rejected'

repo=$(make_repo 'coderabbit,,coderabbit')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'a repeated delimiter is rejected'

repo=$(make_repo 'unknown-provider')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'unknown providers cannot select a trigger'

repo=$(make_repo __missing__)
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=missing' "$out" \
    'missing configuration uses the safe disabled plan'
assert_contains "$(<"$tmp/err")" 'using effective none' \
    'missing configuration warns without blocking'

marker=$tmp/should-not-exist
repo=$(make_repo "coderabbit;touch $marker")
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=none mode=disabled source=invalid' "$out" \
    'shell-looking declarations are rejected as data'
assert_rc 1 'invalid declarations never execute shell-looking payloads' -- test -e "$marker"

assert_rc 2 'unknown options are usage errors' -- bash "$resolver" --unexpected

# --- --probe: GitHub Code Quality reachability (issue #403) ----------------
#
# AGENT_REVIEW_PROVIDERS=github-code-quality used to be accepted at plan
# time even when Code Quality was disabled for the repository, and the
# downstream findings fetch then died mid-gate with a raw 403. --probe
# decides reachability once and, only on a confirmed not-enabled answer,
# downgrades that provider's plan line. Any other probe outcome must never
# downgrade it -- fail closed.

make_repo_with_slug() {
    local providers=$1 slug=${2:-o/r} repo=$tmp/repo-probe
    rm -rf -- "$repo"
    mkdir -p -- "$repo/.agent"
    printf 'AGENT_REVIEW_PROVIDERS=%s\nAGENT_REPO_SLUG=%s\n' "$providers" "$slug" \
        > "$repo/.agent/config.env"
    printf '%s' "$repo"
}

fake_quality() {
    cat > "$tmp/fake-quality.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' '$1'
EOF
    chmod +x "$tmp/fake-quality.sh"
}

repo=$(make_repo_with_slug 'github-code-quality')
fake_quality 'state=not-enabled'
out=$(REVIEW_PROVIDER_CONFIG_CODE_QUALITY_STATE="$tmp/fake-quality.sh" \
    bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq 'provider=github-code-quality mode=none source=declared reason=not-enabled' "$out" \
    'a confirmed not-enabled probe downgrades the plan line and names the reason'

repo=$(make_repo_with_slug 'coderabbit,github-code-quality')
fake_quality 'state=not-enabled'
out=$(REVIEW_PROVIDER_CONFIG_CODE_QUALITY_STATE="$tmp/fake-quality.sh" \
    bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq $'provider=coderabbit mode=triggerable source=declared\nprovider=github-code-quality mode=none source=declared reason=not-enabled' \
    "$out" 'a not-enabled downgrade touches only the github-code-quality line, never a co-declared provider'

repo=$(make_repo_with_slug 'github-code-quality')
fake_quality 'state=enabled'
out=$(REVIEW_PROVIDER_CONFIG_CODE_QUALITY_STATE="$tmp/fake-quality.sh" \
    bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq 'provider=github-code-quality mode=observe-only source=declared' "$out" \
    'an enabled probe leaves the plan line unchanged'

repo=$(make_repo_with_slug 'github-code-quality')
fake_quality 'state=unknown reason=network failure'
out=$(REVIEW_PROVIDER_CONFIG_CODE_QUALITY_STATE="$tmp/fake-quality.sh" \
    bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq 'provider=github-code-quality mode=observe-only source=declared' "$out" \
    'an inconclusive probe never downgrades the plan line -- fail closed, not proof of disablement'
assert_contains "$(<"$tmp/err")" 'could not be determined' \
    'an inconclusive probe is warned about, not silently absorbed'

repo=$(make_repo 'coderabbit,github-code-quality')
out=$(bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq $'provider=coderabbit mode=triggerable source=declared\nprovider=github-code-quality mode=observe-only source=declared' \
    "$out" 'a repo with no declared AGENT_REPO_SLUG skips the probe safely'
assert_contains "$(<"$tmp/err")" 'AGENT_REPO_SLUG is not declared' \
    'the missing-slug fallback explains itself'

repo=$(make_repo_with_slug 'github-code-quality')
out=$(bash "$resolver" --repo-root "$repo" 2> "$tmp/err")
assert_eq 'provider=github-code-quality mode=observe-only source=declared' "$out" \
    'without --probe the plan resolver output is byte-for-byte unchanged, even with a repo slug declared'
assert_eq '' "$(<"$tmp/err")" 'without --probe, resolving the plan stays silent (no probe attempted)'

# End-to-end through the real code-quality-state.sh with a stubbed gh 403 --
# proves the wiring, not just the probe_code_quality() contract in isolation.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gh: Code quality is not enabled for this repository (HTTP 403)' >&2
exit 1
EOF
chmod +x "$tmp/bin/gh"
repo=$(make_repo_with_slug 'github-code-quality')
out=$(PATH="$tmp/bin:$PATH" bash "$resolver" --repo-root "$repo" --probe 2> "$tmp/err")
assert_eq 'provider=github-code-quality mode=none source=declared reason=not-enabled' "$out" \
    'end-to-end through the real code-quality-state.sh: a stubbed 403 downgrades the plan line'

finish
