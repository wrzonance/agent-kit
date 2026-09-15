#!/usr/bin/env bash
# Suite: every repository configuration key has an onboarding discovery path.
set -uo pipefail

TEST_NAME='onboard-variable-drift'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

schema="$root/agentkit/skills/.shared/schema/config.env.example"
skill="$root/agentkit/skills/onboard-repo/SKILL.md"
resolver="$root/agentkit/skills/.shared/scripts/repo-config.sh"
runner="$root/agentkit/skills/.shared/scripts/agent-run.sh"

assert_eq 'yes' "$([[ -f $schema && ! -L $schema ]] && printf yes || printf no)" \
    'the config.env example is a regular file'
assert_eq 'yes' "$([[ -f $skill && ! -L $skill ]] && printf yes || printf no)" \
    'the onboarding skill is a regular file'
assert_eq 'yes' "$([[ -f $resolver && ! -L $resolver ]] && printf yes || printf no)" \
    'the repository config resolver is a regular file'

# ACCEPTED_KEYS is the resolver's fixed declaration inventory: any shipped
# script may consume these values from .agent/config.env. Dynamic command and
# rundir keys are covered by their generic table rows below. Runtime-only flags
# are checked separately as consumed inputs and must still be documented.
mapfile -t config_keys < <(
    sed -n '/readonly ACCEPTED_KEYS=(/,/)/p' "$resolver" |
        grep -oE 'AGENT_[A-Z0-9_]+' | sort -u
)
assert_eq 'yes' "$([[ ${#config_keys[@]} -gt 0 ]] && printf yes || printf no)" \
    'the resolver exposes a fixed config declaration inventory'

# Also discover literal reads in shipped scripts. The allowlist above catches
# declarations that are available to consumers; this scan catches a consumer
# added before its key is added to the resolver. Restricting matches to config
# access sites avoids treating local markers and runtime environment flags as
# repository declarations.
mapfile -t consumed_keys < <(
    while IFS= read -r -d '' script; do
        awk '/repo-config|repo_config_get|read_config|config\.env|--get/ { print }' "$script"
    done < <(find "$root/agentkit/skills" -type f -name '*.sh' -print0) |
        grep -oE 'AGENT_[A-Z][A-Z0-9_]*' | sort -u
)
assert_eq 'yes' "$([[ ${#consumed_keys[@]} -gt 0 ]] && printf yes || printf no)" \
    'shipped scripts expose literal config consumers'

# Keep the literal-dot branch pinned even when the current shipped scripts
# happen to mention config.env alongside another recognized access marker.
config_consumer_probe='read from .agent/config.env: AGENT_CONFIG_PROBE'
assert_contains "$(awk '/config\.env/ { print }' <<< "$config_consumer_probe")" \
    'AGENT_CONFIG_PROBE' 'the consumer scan recognizes a literal config.env reference'

# These are read by agent-run.sh straight from the environment as runtime
# assertions, never as a persistent config.env declaration. Their documentation
# is still part of the onboarding contract so operators can discover them.
runtime_keys=(AGENT_CACHE_ROOT AGENT_COMPOSE_SERIALIZED)
consumed_keys+=("${runtime_keys[@]}")

# Guard runtime_keys itself against drift: derive every AGENT_* environment
# read in the runner (assignment/export sites, internal double-underscore
# markers, and dynamic AGENT_CMD_/AGENT_RUNDIR_ tokens excluded) and assert it
# equals runtime_keys exactly, minus keys the resolver already declares. A new
# or renamed runtime-only read must be added here before this test goes green.
mapfile -t runner_reads < <(
    grep -nE '\$\{?AGENT_[A-Z]' "$runner" |
        grep -vE '^[0-9]+:[[:space:]]*(export[[:space:]]+)?AGENT_[A-Z0-9_]*=' |
        grep -vE '^[0-9]+:[[:space:]]*#' |
        grep -oE 'AGENT_[A-Z][A-Z0-9_]*' | sort -u
)
derived_runtime_keys=()
for key in "${runner_reads[@]}"; do
    case $key in
        AGENT_CMD_ | AGENT_RUNDIR_) continue ;;
        *__) continue ;;
    esac
    declared=no
    for config_key in "${config_keys[@]}"; do
        [[ $key == "$config_key" ]] && declared=yes && break
    done
    [[ $declared == yes ]] || derived_runtime_keys+=("$key")
done
assert_eq "$(printf '%s\n' "${runtime_keys[@]}" | sort)" \
    "$(printf '%s\n' "${derived_runtime_keys[@]}" | sort)" \
    'runtime_keys matches every AGENT_* environment read in agent-run.sh'

variable_table=$(
    awk '
        /^\| Key \| What it does \|$/ { in_table=1; next }
        in_table && /^\|/ { print; next }
        in_table { exit }
    ' "$skill"
)

tick=$'\x60'
cmd_row="| ${tick}AGENT_CMD_<NAME>${tick} |"
rundir_row="| ${tick}AGENT_RUNDIR_<NAME>${tick} |"
generated_row="| ${tick}AGENT_GENERATED_PATHS${tick} |"
compose_row="| ${tick}AGENT_COMPOSE_SERIALIZED${tick} |"
cache_root_row="| ${tick}AGENT_CACHE_ROOT${tick} |"

for key in "${config_keys[@]}"; do
    in_schema=no
    in_table=no
    grep -Eq "(^|[^A-Z0-9_])${key}([^A-Z0-9_]|$)" "$schema" && in_schema=yes
    grep -Fq "${tick}${key}${tick}" <<< "$variable_table" && in_table=yes
    assert_eq yes "$([[ $in_schema == yes || $in_table == yes ]] && printf yes || printf no)" \
        "$key has a config.env example or onboarding-table entry"
done

for key in "${consumed_keys[@]}"; do
    case $key in
        AGENT_CMD_|AGENT_RUNDIR_) continue ;;
    esac
    in_schema=no
    in_table=no
    grep -Eq "(^|[^A-Z0-9_])${key}([^A-Z0-9_]|$)" "$schema" && in_schema=yes
    case $key in
        AGENT_CMD_*) grep -Fq "$cmd_row" <<< "$variable_table" && in_table=yes ;;
        AGENT_RUNDIR_*) grep -Fq "$rundir_row" <<< "$variable_table" && in_table=yes ;;
        *) grep -Fq "${tick}${key}${tick}" <<< "$variable_table" && in_table=yes ;;
    esac
    assert_eq yes "$([[ $in_schema == yes || $in_table == yes ]] && printf yes || printf no)" \
        "$key consumed by a shipped script has a discovery path"
done

assert_contains "$variable_table" "$cmd_row" \
    'the onboarding table covers dynamic command declarations'
assert_contains "$variable_table" "$rundir_row" \
    'the onboarding table covers dynamic command directories'
assert_contains "$variable_table" "$generated_row" \
    'the onboarding table documents generated artifact paths'
assert_contains "$variable_table" "$compose_row" \
    'the onboarding table documents runtime-only compose serialization'
assert_contains "$variable_table" "$cache_root_row" \
    'the onboarding table documents the runtime-only cache root override'

# A required formatter repair must be discoverable before a worker starts.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/.agent" "$repo/server"
git -C "$repo" init -q
preflight="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
printf '%s\n' 'AGENT_CMD_SERVER_FORMAT=server/.venv/bin/ruff format --check server' > "$repo/.agent/config.env"
before=$(cat "$repo/.agent/config.env")
rc=0
out=$("$preflight" --worktree "$repo" --no-write 2>&1) || rc=$?
assert_eq 1 "$rc" 'preflight rejects a missing component formatter repair declaration'
assert_contains "$out" 'AGENT_CMD_SERVER_FORMAT_FIX' 'preflight names the missing declaration'
assert_contains "$out" 'parallel-issues worker workflow' 'preflight names the workflow requiring repair'
assert_contains "$out" 'server/.venv/bin/ruff format server' 'preflight preserves the declared ruff operands'
assert_eq "$before" "$(cat "$repo/.agent/config.env")" 'preflight offers repairs without writing config'

# The preview's config line must resolve as argv, not a single quoted token.
grep '^AGENT_CMD_SERVER_FORMAT_FIX=' <<< "$out" >> "$repo/.agent/config.env"
argv=$("$resolver" --repo-root "$repo" --get-argv AGENT_CMD_SERVER_FORMAT_FIX | tr '\0' '\n')
assert_eq $'server/.venv/bin/ruff\nformat\nserver' "$argv" 'the offered declaration is directly usable by agent-run'
rc=0
"$preflight" --worktree "$repo" > /dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'an explicitly paired formatter passes and writes a contract'
printf '%s\n' "$before" > "$repo/.agent/config.env"
rc=0
out=$("$preflight" --worktree "$repo" --ensure 2>&1) || rc=$?
assert_eq 1 "$rc" 'cached-contract reuse cannot bypass a missing repair declaration'

for check in 'dotnet format --verify-no-changes' 'cargo fmt --check' 'python3 -m ruff format --check'; do
    printf 'AGENT_CMD_FORMAT=%s\nAGENT_RUNDIR_FORMAT=server\n' "$check" > "$repo/.agent/config.env"
    rc=0
    out=$("$preflight" --worktree "$repo" --no-write 2>&1) || rc=$?
    expected=${check/ --verify-no-changes/}
    expected=${expected/ --check/}
    assert_eq 1 "$rc" "$check requires a repair pair"
    assert_contains "$out" "AGENT_CMD_FORMAT_FIX=$expected" "$check offers its supported fix verbatim"
    assert_contains "$out" 'AGENT_RUNDIR_FORMAT_FIX=server' 'the repair retains the declared check directory'
done
printf '%s\n' '{"scripts":{"format:check":"prettier --check src"}}' > "$repo/package.json"
printf '%s\n' 'AGENT_CMD_FORMAT=npm run format:check' > "$repo/.agent/config.env"
out=$("$preflight" --worktree "$repo" --no-write 2>&1)
assert_contains "$out" 'AGENT_CMD_FORMAT_FIX=npm exec --no -- prettier --write src' 'preflight reuses the safe Prettier detector proposal'
printf '%s\n' '{"scripts":{"format:check":"custom-formatter --check src"}}' > "$repo/package.json"
printf '%s\n' 'AGENT_CMD_FORMAT_FIX=' >> "$repo/.agent/config.env"
rc=0
out=$("$preflight" --worktree "$repo" --no-write 2>&1) || rc=$?
assert_eq 1 "$rc" 'an empty fix does not satisfy the workflow'
assert_contains "$out" 'No safe FORMAT_FIX proposal: add an explicit format:fix script.' 'unknown formatters require an explicit script, never a guess'
assert_not_contains "$out" 'Confirm in .agent/config.env:' 'unknown formatters do not receive invented commands'

# Generated artifacts are proposed even without a detected language component.
artifacts="$tmp/artifacts"
mkdir -p "$artifacts/server" "$artifacts/client" "$artifacts/node_modules/pkg"
printf '{}\n' > "$artifacts/server/openapi.json"
printf '// generated\n' > "$artifacts/client/generated.ts"
printf '{}\n' > "$artifacts/node_modules/pkg/openapi.json"
detector="$root/agentkit/skills/.shared/scripts/detect-toolchains.sh"
out=$("$detector" --repo-root "$artifacts" --format suggestions)
assert_contains "$out" '# AGENT_GENERATED_PATHS=client/generated.ts,server/openapi.json' 'the detector proposes sorted generated-contract paths'
assert_not_contains "$out" 'node_modules/pkg/openapi.json' 'generated proposals exclude dependency artifacts'
assert_not_contains "$out" $'\nAGENT_GENERATED_PATHS=' 'generated paths are proposals, never active declarations'
generated_description=$(grep -F "$generated_row" <<< "$variable_table")
assert_contains "$generated_description" 'write-set' 'generated-path documentation names its write-set role'
assert_contains "$generated_description" 'staleness' 'generated-path documentation retains its staleness role'

finish
