#!/usr/bin/env bash
# Suite: spawn-contract.md's harness-neutral worker roster resolution
# (AGENT_WORKER_MODELS / AGENT_WORKER_MODELS_FALLBACK, issue #487).
#
# The contract's ```bash fenced block is the actual selection logic worker
# dispatchers paste and run -- this suite extracts that exact block (never a
# re-typed copy) and executes resolve_worker_slot against stub
# repo-config.sh/contract-read.sh helpers, so a change to the prose's shell
# is pinned by execution, not string matching alone.
set -uo pipefail

TEST_NAME='spawn-contract-roster'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

contract_md="$root/agentkit/skills/.shared/spawn-contract.md"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# Extract the sole ```bash ... ``` fenced block containing resolve_worker_slot.
block=$(awk '/^```bash$/{flag=1; next} /^```$/{flag=0} flag' "$contract_md")
assert_contains "$block" 'resolve_worker_slot' 'extracted the resolver block from spawn-contract.md'
printf '%s\n' "$block" > "$tmp/resolver.sh"

# Stub agentkit tree: only the two helpers the block actually shells out to.
mkdir -p "$tmp/agentkit/.shared/scripts"
cat > "$tmp/agentkit/.shared/scripts/repo-config.sh" <<'HELPER'
#!/usr/bin/env bash
# Stub: --get KEY against $STUB_CONFIG_FILE (K=V lines), exit 1 if absent/empty.
while (($#)); do
    case $1 in
        --get) shift; key=$1 ;;
        *) ;;
    esac
    shift
done
[[ -n ${STUB_CONFIG_FILE:-} && -f $STUB_CONFIG_FILE ]] || exit 1
line=$(grep -E "^${key}=" -- "$STUB_CONFIG_FILE" | head -n1) || exit 1
[[ -n $line ]] || exit 1
val=${line#*=}
[[ -n $val ]] || exit 1
printf '%s\n' "$val"
HELPER
chmod +x "$tmp/agentkit/.shared/scripts/repo-config.sh"

cat > "$tmp/agentkit/.shared/scripts/contract-read.sh" <<'HELPER'
#!/usr/bin/env bash
[[ ${STUB_HARNESS:-} ]] || exit 1
printf '%s\n' "$STUB_HARNESS"
HELPER
chmod +x "$tmp/agentkit/.shared/scripts/contract-read.sh"

run_resolver() {
    local config=$1 harness=$2
    (
        set -e
        export agentkit="$tmp/agentkit"
        export agentkit_provenance=ok
        export repository_root="$tmp"
        export STUB_CONFIG_FILE="$config"
        export STUB_HARNESS="$harness"
        # shellcheck source=/dev/null
        source "$tmp/resolver.sh"
        # shellcheck disable=SC2154  # worker_model/_fallback/model_pivot_note are set by the sourced resolver block
        printf 'worker_model=%s\n' "$worker_model"
        # shellcheck disable=SC2154
        printf 'worker_model_fallback=%s\n' "$worker_model_fallback"
        # shellcheck disable=SC2154
        printf 'model_pivot_note=%s\n' "$model_pivot_note"
    )
}

# --- roster form: picks the running harness's own family entry -------------
printf 'AGENT_WORKER_MODELS=claude-sonnet-5,gpt-5.6-luna\nAGENT_WORKER_MODELS_FALLBACK=claude-opus-5,gpt-5.6-terra\n' \
    > "$tmp/roster.env"
out=$(run_resolver "$tmp/roster.env" claude 2>/dev/null)
assert_contains "$out" 'worker_model=claude-sonnet-5' \
    'a Claude session self-detects and picks the claude-* roster entry'
assert_contains "$out" 'worker_model_fallback=claude-opus-5' \
    'a Claude session picks the claude-* fallback roster entry'
assert_contains "$out" 'model_pivot_note=' \
    'a roster-resolved value carries no pivot note'

out=$(run_resolver "$tmp/roster.env" codex 2>/dev/null)
assert_contains "$out" 'worker_model=gpt-5.6-luna' \
    'a Codex session self-detects and picks the gpt-5.6-* roster entry, same declaration'
assert_contains "$out" 'worker_model_fallback=gpt-5.6-terra' \
    'a Codex session picks the gpt-5.6-* fallback roster entry'

# --- declaration is authorization: an unsanctioned-but-declared roster
# model dispatches with no sanctioned-set stop --------------------------------
printf 'AGENT_WORKER_MODELS=claude-sonnet-5,gpt-5.6-sol\n' > "$tmp/unsanctioned.env"
out=$(run_resolver "$tmp/unsanctioned.env" codex 2>/dev/null)
rc=$?
assert_eq 0 "$rc" 'a roster-declared, otherwise-unsanctioned model does not stop for authorization'
assert_contains "$out" 'worker_model=gpt-5.6-sol' \
    'the declared roster model is used verbatim, bypassing the sanctioned-tier gate'

# --- roster key takes precedence over the singular key when both present ---
printf 'AGENT_WORKER_MODEL=gpt-5.6-terra\nAGENT_WORKER_MODELS=gpt-5.6-luna\n' > "$tmp/precedence.env"
out=$(run_resolver "$tmp/precedence.env" codex 2>/dev/null)
assert_contains "$out" 'worker_model=gpt-5.6-luna' \
    'the roster key wins over the singular key when both are declared'

# --- additive: singular-only declaration still parses and pivots exactly as
# before (no roster keys declared at all) ------------------------------------
printf 'AGENT_WORKER_MODEL=gpt-5.6-luna\nAGENT_WORKER_MODEL_FALLBACK=gpt-5.6-terra\n' > "$tmp/legacy.env"
out=$(run_resolver "$tmp/legacy.env" codex 2>/dev/null)
assert_contains "$out" 'worker_model=gpt-5.6-luna' \
    'a legacy singular-only declaration still resolves unchanged'
assert_contains "$out" 'worker_model_fallback=gpt-5.6-terra' \
    'a legacy singular-only fallback declaration still resolves unchanged'

# A cross-harness singular declaration still pivots exactly as before when no
# roster key is present.
printf 'AGENT_WORKER_MODEL=gpt-5.6-luna\n' > "$tmp/pivot.env"
out=$(run_resolver "$tmp/pivot.env" claude 2>/dev/null)
assert_contains "$out" 'worker_model=claude-sonnet-5' \
    'a Codex-shaped singular declaration still pivots to the native Claude tier'
assert_contains "$out" 'model_pivot_note=pivoted from cross-harness declaration' \
    'the legacy pivot note is still recorded when no roster key applies'

finish
