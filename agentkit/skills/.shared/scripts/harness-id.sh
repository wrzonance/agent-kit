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
# OPENCODE and OPENCODE_PID are set unconditionally by OpenCode's own CLI
# entrypoint, in a yargs .middleware() that runs before any command --
# packages/opencode/src/index.ts (anomalyco/opencode, verified via `gh api
# search/code` against the upstream source, since no doc page enumerates
# variables the CLI SETS rather than reads):
#   process.env.AGENT = "1"
#   process.env.OPENCODE = "1"
#   process.env.OPENCODE_PID = String(process.pid)
# The shell tool that runs commands on the agent's behalf spawns them with
# `{...process.env, ...extra.env}` (packages/opencode/src/tool/shell.ts), so
# both variables are inherited by every command OpenCode runs -- the same
# "CLI exports a fact about itself into commands it runs" shape CLAUDECODE
# and the CODEX_* variables already rely on above. AGENT=1 alone is
# deliberately NOT used as a signal: it is a generic, unnamespaced token
# other tooling could plausibly set for unrelated reasons, where OPENCODE/
# OPENCODE_PID are namespaced and specific to this CLI.
elif [[ -n ${OPENCODE:-}${OPENCODE_PID:-} ]]; then
    name=opencode
    trailer='OpenCode <noreply@opencode.ai>'
    # OpenCode has no single fixed peer CLI: unlike Claude/Codex's fixed
    # 1:1 pairing, an OpenCode session's cross-provider adversarial reviewer
    # is whichever of Codex or Claude is actually installed alongside it.
    # A comma-separated candidate list here (never used by the claude/codex
    # cases above, which stay single-name) lets probe_peer_cli try Codex
    # first, then Claude, and still emit exactly one winning peer-cli= name
    # -- the shape every existing peer-cli= consumer already parses.
    other=codex,claude
fi

case ${1:-line} in
    --name) printf '%s\n' "$name" ;;
    --other) printf '%s\n' "$other" ;;
    --trailer) printf '%s\n' "$trailer" ;;
    -h | --help) printf 'usage: harness-id.sh [--name|--other|--trailer]\n' ;;
    *) printf 'name=%s trailer="%s" other=%s\n' "$name" "$trailer" "$other" ;;
esac
