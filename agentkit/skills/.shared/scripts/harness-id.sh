#!/usr/bin/env bash
#
# harness-id.sh -- which agent CLI is running this, as one line.
#
# The single source of truth for harness identity, because that identity is
# consumed in two places that must never disagree: agent-preflight writes it into
# the environment contract, and the session hook checks it before reusing a
# CACHED contract.
#
# That second use is the reason this file exists. The contract is cached per
# repository and reused for a while, but the harness is a fact about the SESSION,
# not the repository. A contract written by one CLI and served to the other
# credits every commit to the wrong agent -- observed live, with a contract
# written by one CLI reused by the other two minutes later.
#
# Reports, never fails: an unknown harness is named as unknown rather than
# guessed, since a wrong attribution is worse than an absent one.
set -uo pipefail

name=unknown
trailer='Agent <noreply@example.invalid>'
other=none

# Order matters. A machine that has run both CLIs has both config directories, so
# the on-disk check is only ever a last resort -- the environment a CLI exports
# about ITSELF is the reliable signal.
if [[ -n ${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-} ]]; then
    name=claude
    trailer='Claude <noreply@anthropic.com>'
    other=codex
elif [[ -n ${CODEX_HOME:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_PERMISSION_PROFILE:-} ]] ||
    [[ -d ${CODEX_HOME:-$HOME/.codex} ]]; then
    name=codex
    trailer='Codex <noreply@openai.com>'
    other=claude
fi

case ${1:-line} in
    --name) printf '%s\n' "$name" ;;
    --other) printf '%s\n' "$other" ;;
    --trailer) printf '%s\n' "$trailer" ;;
    -h | --help) printf 'usage: harness-id.sh [--name|--other|--trailer]\n' ;;
    *) printf 'name=%s trailer="%s" other=%s\n' "$name" "$trailer" "$other" ;;
esac
