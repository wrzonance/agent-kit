#!/usr/bin/env bash
# Suite: gh-auth-state.sh names WHICH auth failure this is.
#
# Every case below looks identical from the outside -- "gh is not authenticated"
# -- and has a different fix. The one that motivated the script is
# keyring-unreadable: a token in the OS keyring is reachable from a login shell
# and not from wherever an agent's commands run, so the operator's terminal and
# the agent's failure are both telling the truth.
#
# gh is stubbed per case. A real gh consults the OS keyring regardless of
# GH_CONFIG_DIR, so the interesting failures cannot be produced on a machine
# where auth actually works -- which is every machine anyone would run this on.
set -uo pipefail

TEST_NAME='gh-auth-state'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/gh-auth-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# A gh whose behaviour is driven by two files, so each case is explicit about
# what it is claiming the real gh would do.
make_gh() {
    local dir="$tmp/bin.$1" api_rc=$2 token_rc=$3
    mkdir -p "$dir"
    cat > "$dir/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
    "api user") exit $api_rc ;;
    "auth token") exit $token_rc ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$dir/gh"
    printf '%s' "$dir"
}

run_state() {
    local bin=$1 cfg=$2
    shift 2
    env PATH="$bin:$PATH" GH_CONFIG_DIR="$cfg" AGENTKIT_NET_PROBE="${AGENTKIT_NET_PROBE:-ok}" \
        GH_TOKEN="${FAKE_GH_TOKEN:-}" GITHUB_TOKEN="" "$@" "$script"
}

with_account() {
    local d="$tmp/cfg.$1"
    mkdir -p "$d"
    printf 'github.com:\n    users:\n        someone: {}\n    user: someone\n' > "$d/hosts.yml"
    printf '%s' "$d"
}

empty_cfg() {
    local d="$tmp/cfg-empty.$1"
    mkdir -p "$d"
    printf '%s' "$d"
}

# --- the happy path --------------------------------------------------------
out=$(run_state "$(make_gh ok 0 0)" "$(with_account ok)")
assert_contains "$out" 'state=ok' 'a working gh reports ok'
assert_not_contains "$out" 'remedy' 'and offers no remedy for a non-problem'

# --- the case this exists for ----------------------------------------------
# An account is configured, no token can be read, and the API call fails: the
# token is in the keyring and this process cannot reach it.
out=$(AGENTKIT_NET_PROBE=ok run_state "$(make_gh keyring 1 1)" "$(with_account keyring)")
assert_contains "$out" 'state=keyring-unreadable' 'an unreadable keyring token is named as such'
assert_contains "$out" 'insecure-storage' 'and the remedy moves the token to a file'
assert_contains "$out" 'remedy=' 'and the remedy is machine-readable'

# --- the network case must WIN over every token verdict ---------------------
# gh validates a token by calling the API, so an unreachable API is reported as
# an invalid token. Blaming the token sends the operator to re-authenticate,
# which cannot help, and they do it twice before disbelieving the tool.
out=$(AGENTKIT_NET_PROBE=fail run_state "$(make_gh net 1 0)" "$(with_account net)")
assert_contains "$out" 'state=network-unreachable' 'an unreachable API is not called a bad token'
assert_contains "$out" 'do NOT re-authenticate' 'and says so explicitly'
assert_contains "$out" 'network_access' 'and names the setting that fixes it'

# Even with a stale token in the environment -- the network is still the thing
# to fix first, because fixing the token changes nothing while it is blocked.
FAKE_GH_TOKEN=ghp_stale
out=$(AGENTKIT_NET_PROBE=fail run_state "$(make_gh net2 1 0)" "$(with_account net2)")
assert_contains "$out" 'state=network-unreachable' 'the network verdict outranks an env token'
FAKE_GH_TOKEN=''

# With the network up, the token verdicts still apply.
out=$(AGENTKIT_NET_PROBE=ok run_state "$(make_gh keyring2 1 1)" "$(with_account keyring2)")
assert_contains "$out" 'state=keyring-unreadable' 'and a reachable API restores the token verdicts'

# --- genuinely never logged in ---------------------------------------------
out=$(AGENTKIT_NET_PROBE=ok run_state "$(make_gh none 1 1)" "$(empty_cfg none)")
assert_contains "$out" 'state=not-logged-in' 'no config at all is not-logged-in'
assert_contains "$out" 'gh auth login' 'with the obvious remedy'

# --- a token exists and is readable, but the forge refuses it ---------------
out=$(AGENTKIT_NET_PROBE=ok run_state "$(make_gh stale 1 0)" "$(with_account stale)")
assert_contains "$out" 'state=token-rejected' 'a readable but refused token is distinguished'
assert_not_contains "$out" 'insecure-storage' 'and is not confused with a keyring problem'

# --- a bad token in the environment shadows a good one ----------------------
# The environment wins in gh, so a stale GH_TOKEN breaks a machine whose stored
# credentials are perfect. Fixing the stored token would not help.
FAKE_GH_TOKEN=ghp_stale
out=$(AGENTKIT_NET_PROBE=ok run_state "$(make_gh env 1 0)" "$(with_account env)")
assert_contains "$out" 'state=env-token-rejected' 'an environment token is blamed when it is at fault'
assert_contains "$out" 'unset GH_TOKEN' 'and the remedy targets the environment'
FAKE_GH_TOKEN=''

# --- no gh at all -----------------------------------------------------------
# A PATH with an interpreter but no gh. Omitting bash would make the shebang
# itself fail with 127, and the assertion would pass for the wrong reason.
nogh="$tmp/nogh"
mkdir -p "$nogh"
for b in bash env timeout; do
    if p=$(command -v "$b" 2> /dev/null); then ln -sf "$p" "$nogh/$b"; fi
done
out=$(env PATH="$nogh" GH_CONFIG_DIR="$(empty_cfg missing)" "$script")
assert_contains "$out" 'state=gh-missing' 'a missing gh is not reported as an auth failure'

# --- never fails ------------------------------------------------------------
rc=0
AGENTKIT_NET_PROBE=fail run_state "$(make_gh keyring 1 1)" "$(with_account keyring)" > /dev/null 2>&1 || rc=$?
assert_eq '0' "$rc" 'reporting a failure is not itself a failure'

finish
