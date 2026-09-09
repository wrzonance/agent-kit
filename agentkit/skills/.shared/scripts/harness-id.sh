#!/usr/bin/env bash
#
# harness-id.sh -- which agent CLI is running this, as one line: the single source
# of truth consumed by agent-preflight (writes it into the contract) and by the
# session hook (checks it before reusing a CACHED contract -- a contract from one
# CLI served to the other credits every commit wrongly). Unknown is named, not guessed.
set -uo pipefail

name=unknown
trailer='Agent <noreply@example.invalid>'
other=none

# Order matters, and not just claude-before-codex: an actively-set session
# variable is strong evidence a CLI is running THIS session, while an on-disk
# directory is only evidence that CLI was installed at some point -- so every
# CLI's own explicit environment signal is checked first, in a fixed order,
# and the weakest signal (Codex's ~/.codex directory, the only on-disk
# fallback any of the three has) runs dead last. Getting this wrong recreates
# exactly the misattribution this file exists to prevent: an OpenCode session
# on a machine that has ever run Codex, with no CODEX_* variable currently
# set, would otherwise be reported as codex by the directory fallback alone.
if [[ -n ${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-} ]]; then
    name=claude
    trailer='Claude <noreply@anthropic.com>'
    other=codex
elif [[ -n ${CODEX_HOME:-}${CODEX_SANDBOX_NETWORK_DISABLED:-}${CODEX_PERMISSION_PROFILE:-} ]]; then
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
# OPENCODE_PID are namespaced and specific to this CLI. Checked here, ahead
# of the Codex on-disk fallback below, so a machine that has ever run Codex
# does not shadow an actual OpenCode session.
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
# Last resort: a machine that has run Codex before has ~/.codex on disk even
# in a session with no CODEX_* variable currently set. Weakest evidence of
# the three checks above, so it runs only after all of them have missed.
elif [[ -d ${CODEX_HOME:-$HOME/.codex} ]]; then
    name=codex
    trailer='Codex <noreply@openai.com>'
    other=claude
fi

if [[ ${1:-} == -- ]]; then
    shift
fi
case ${1:-line} in
    --name) printf '%s\n' "$name" ;;
    --other) printf '%s\n' "$other" ;;
    --trailer) printf '%s\n' "$trailer" ;;
    -h | --help) printf 'usage: harness-id.sh [--name|--other|--trailer]\n' ;;
    *) printf 'name=%s trailer="%s" other=%s\n' "$name" "$trailer" "$other" ;;
esac
