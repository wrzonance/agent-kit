#!/usr/bin/env bash
#
# gh-auth-state.sh -- why gh can or cannot reach the forge FROM THIS PROCESS.
#
# "gh is not authenticated" is the least useful true statement available when the
# operator has, moments earlier, used gh successfully in their own terminal. The cases below
# look identical from the outside and have completely different fixes, and an
# agent told only "not authenticated" spent twelve commands rediscovering which
# one it was before reporting the tooling as broken.
#
# The case that motivated this: a token in the OS keyring is reachable from a
# login shell and NOT from wherever an agent's commands run, so `gh auth status`
# in a terminal and this failure are both true at once. `gh auth token` returning
# empty while hosts.yml names an account is the signature.
#
# Reports, never fails.
set -uo pipefail

# TCP reachability, no curl dependency. Overridable so the suite can exercise the
# unreachable branch on a machine that is, necessarily, online.
net_reachable() {
    case ${AGENTKIT_NET_PROBE:-} in
        ok) return 0 ;;
        fail) return 1 ;;
    esac
    timeout 5 bash -c 'exec 3<>/dev/tcp/api.github.com/443' 2> /dev/null
}

hosts="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
state=unknown
remedy=''

if ! command -v gh > /dev/null 2>&1; then
    state=gh-missing
    remedy='install the gh CLI'
elif gh api user --jq .login > /dev/null 2>&1; then
    # The only question that predicts whether the next call works. Deliberately
    # not `gh auth status`, which exits non-zero when ANY configured entry is
    # stale, even with a working account in the same output.
    state=ok
elif ! net_reachable; then
    # THE trap. gh validates a token by calling the API, so when the network is
    # blocked it reports a perfectly good token as invalid. An agent told
    # "the token is invalid" sends the operator to re-authenticate, which
    # changes nothing, twice. Sandboxes that permit writes commonly still deny
    # network, which is exactly this case.
    state=network-unreachable
    remedy='the API is not reachable from this process -- a sandbox is likely denying network. gh reports an unreachable API as an invalid token, so do NOT re-authenticate. For Codex: sandbox_workspace_write.network_access = true'
elif [[ -n ${GH_TOKEN:-}${GITHUB_TOKEN:-} ]]; then
    state=env-token-rejected
    remedy='unset GH_TOKEN and GITHUB_TOKEN, or replace with a token the forge accepts'
elif [[ ! -s $hosts ]]; then
    state=not-logged-in
    remedy='gh auth login'
elif gh auth token > /dev/null 2>&1; then
    state=token-rejected
    remedy='gh auth login   # a token is readable here but the forge refuses it'
else
    # hosts.yml names an account, yet no token can be read from this process:
    # it lives in the OS keyring, which this process cannot reach.
    state=keyring-unreadable
    remedy='gh auth token | gh auth login --hostname github.com --with-token --insecure-storage   # run in a shell where the keyring works; moves the token to a 0600 file'
fi

printf 'state=%s%s\n' "$state" "${remedy:+ remedy=\"$remedy\"}"
