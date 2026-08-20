#!/usr/bin/env bash
# Suite: harness-id.sh reports which agent CLI is running, from real
# environment signals only -- never guessed.
#
# Issue #318: OpenCode detection is added here. Its signal is pinned from
# OpenCode's own upstream source (packages/opencode/src/index.ts,
# anomalyco/opencode, read via `gh api search/code` since no doc page
# enumerates variables the CLI SETS rather than reads): a yargs
# .middleware() unconditionally sets `process.env.OPENCODE = "1"` and
# `process.env.OPENCODE_PID` before any command runs, and the shell tool
# that executes commands on the agent's behalf inherits `process.env`
# (packages/opencode/src/tool/shell.ts) -- so both variables are present in
# every command OpenCode runs, the same shape CLAUDECODE/CODEX_* already
# rely on. This suite fixtures exactly those two variables; it does not
# re-derive them from a live OpenCode install.
set -uo pipefail

TEST_NAME='harness-id'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/harness-id.sh"

run_clean() {
    # Strip every real-world harness signal from the environment before
    # applying the fixture's own -- otherwise this suite run from inside an
    # actual Claude/Codex/OpenCode session would leak its own identity into
    # every case, including the "unknown" one.
    env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
        -u CODEX_HOME -u CODEX_SANDBOX_NETWORK_DISABLED -u CODEX_PERMISSION_PROFILE \
        -u OPENCODE -u OPENCODE_PID \
        HOME="$tmp/no-codex-home" \
        "$@"
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/no-codex-home"

# --- unknown: no signal at all ----------------------------------------------
out=$(run_clean bash "$script")
assert_eq 'name=unknown trailer="Agent <noreply@example.invalid>" other=none' "$out" \
    'no harness signal reports unknown rather than guessing'

# --- claude: unaffected by this change ---------------------------------------
out=$(run_clean env CLAUDECODE=1 bash "$script")
assert_eq 'name=claude trailer="Claude <noreply@anthropic.com>" other=codex' "$out" \
    'CLAUDECODE still reports claude, with codex as the single peer'

out=$(run_clean env CLAUDE_CODE_ENTRYPOINT=cli bash "$script")
assert_contains "$out" 'name=claude' 'CLAUDE_CODE_ENTRYPOINT alone still reports claude'

# --- codex: unaffected by this change ----------------------------------------
out=$(run_clean env CODEX_HOME="$tmp/codex-home" bash "$script")
assert_eq 'name=codex trailer="Codex <noreply@openai.com>" other=claude' "$out" \
    'CODEX_HOME still reports codex, with claude as the single peer'

out=$(run_clean env CODEX_SANDBOX_NETWORK_DISABLED=1 bash "$script")
assert_contains "$out" 'name=codex' 'CODEX_SANDBOX_NETWORK_DISABLED alone still reports codex'

mkdir -p "$tmp/dot-codex-home/.codex"
out=$(run_clean env HOME="$tmp/dot-codex-home" bash "$script")
assert_contains "$out" 'name=codex' 'an on-disk ~/.codex directory still reports codex as a last resort'

# --- opencode: the new case ---------------------------------------------------
out=$(run_clean env OPENCODE=1 OPENCODE_PID=12345 bash "$script")
assert_eq 'name=opencode trailer="OpenCode <noreply@opencode.ai>" other=codex,claude' "$out" \
    'OPENCODE + OPENCODE_PID reports opencode, with codex,claude as ordered peer candidates'

out=$(run_clean env OPENCODE=1 bash "$script")
assert_contains "$out" 'name=opencode' 'OPENCODE alone is enough to detect opencode'

out=$(run_clean env OPENCODE_PID=999 bash "$script")
assert_contains "$out" 'name=opencode' 'OPENCODE_PID alone is enough to detect opencode'

# A generic, unnamespaced AGENT=1 (also set by OpenCode's middleware, but not
# specific to it) must never be the detection signal on its own -- some other
# tool could plausibly set it for an unrelated reason.
out=$(run_clean env AGENT=1 bash "$script")
assert_contains "$out" 'name=unknown' \
    'a bare AGENT=1 with no OPENCODE/OPENCODE_PID does not report opencode'

# The Codex on-disk ~/.codex fallback is the WEAKEST of the three signals
# (evidence Codex was once installed, not evidence it is running now) and
# must never shadow a real OpenCode session: an OpenCode session on a
# machine that has ever run Codex, with no CODEX_* variable currently set,
# must still report opencode, not codex.
mkdir -p "$tmp/opencode-with-old-codex-home/.codex"
out=$(run_clean env OPENCODE=1 HOME="$tmp/opencode-with-old-codex-home" bash "$script")
assert_eq 'name=opencode trailer="OpenCode <noreply@opencode.ai>" other=codex,claude' "$out" \
    'OPENCODE=1 wins over a stale on-disk ~/.codex directory'

# An actively-set CODEX_* session variable is still stronger evidence than
# OPENCODE=1: this ordering question does not actually arise in practice
# (a single session is not simultaneously two CLIs), but the fixed check
# order must still be deterministic rather than accidental.
out=$(run_clean env OPENCODE=1 CODEX_HOME="$tmp/codex-home-explicit" bash "$script")
assert_eq 'name=codex trailer="Codex <noreply@openai.com>" other=claude' "$out" \
    'an explicit CODEX_HOME is still checked ahead of OPENCODE=1'

# --- --name / --trailer / --other flags carry the opencode values too -------
assert_eq 'opencode' "$(run_clean env OPENCODE=1 bash "$script" --name)" \
    '--name reports opencode'
assert_eq 'OpenCode <noreply@opencode.ai>' "$(run_clean env OPENCODE=1 bash "$script" --trailer)" \
    '--trailer reports the OpenCode identity'
assert_eq 'codex,claude' "$(run_clean env OPENCODE=1 bash "$script" --other)" \
    '--other reports the ordered opencode peer-candidate list'

# --- claude takes priority when multiple signals are present ----------------
# Order matters (see the header comment in harness-id.sh): a machine that has
# run every CLI accumulates every on-disk marker, so the environment a CLI
# exports about ITSELF is checked first, in a fixed order, rather than
# resolved by any notion of "most specific."
out=$(run_clean env CLAUDECODE=1 OPENCODE=1 CODEX_HOME="$tmp/codex-home" bash "$script")
assert_contains "$out" 'name=claude' \
    'claude is still checked first when every signal is present at once'

# --- the emitted opencode trailer composes with a provider/model-id worker
# model, and survives worktree-commit.sh's --trailer validation -----------
# OpenCode model ids are `provider/model-id` (e.g. wrzcluster/qwen3-coder):
# the slash must survive contract-read.sh's --worker-model substitution and
# still parse as a valid "Key: value" git trailer line.
contract_read="$root/agentkit/skills/.shared/scripts/contract-read.sh"
fixture_repo="$tmp/opencode-trailer-fixture"
mkdir -p "$fixture_repo/.agent"
git -C "$fixture_repo" init -q
opencode_line=$(run_clean env OPENCODE=1 bash "$script")
printf '%s\n' "harness= $opencode_line" > "$fixture_repo/.agent/env-contract.txt"
chmod 600 "$fixture_repo/.agent/env-contract.txt"

composed=$(bash "$contract_read" --repo-root "$fixture_repo" --get harness.trailer \
    --worker-model 'wrzcluster/qwen3-coder' 2> /dev/null)
assert_eq 'OpenCode wrzcluster/qwen3-coder <noreply@opencode.ai>' "$composed" \
    'contract-read.sh composes the OpenCode trailer with a provider/model-id worker model, slash intact'

# worktree-commit.sh's own validate_trailer_line (agentkit/skills/.shared/
# scripts/worktree-commit.sh) accepts any "Key: value" line where the key is
# letters/digits/hyphens and the value is non-empty after trimming -- it
# imposes no further shape on the value, so the slash in the composed
# worker-model is never a validation concern. Reproduced inline (not
# sourced: the real script's unconditional `main "$@"` at end-of-file makes
# sourcing it unsafe outside a real commit) to pin that same acceptance
# behavior against this exact composed value.
line="Co-Authored-By: $composed"
key="${line%%:*}"
value="${line#*:}"
value="${value#"${value%%[![:space:]]*}"}"
if [[ "$key" =~ ^[A-Za-z0-9-]+$ && -n "$value" ]]; then
    validation_probe="OK $key"
else
    validation_probe="REJECTED"
fi
assert_eq 'OK Co-Authored-By' "$validation_probe" \
    'the composed OpenCode trailer parses as a well-formed Co-Authored-By line (worktree-commit.sh shape)'

finish
