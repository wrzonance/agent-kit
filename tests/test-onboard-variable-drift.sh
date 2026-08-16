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
        awk '/repo-config|repo_config_get|read_config|config\\.env|--get/ { print }' "$script"
    done < <(find "$root/agentkit/skills" -type f -name '*.sh' -print0) |
        grep -oE 'AGENT_[A-Z][A-Z0-9_]*' | sort -u
)
assert_eq 'yes' "$([[ ${#consumed_keys[@]} -gt 0 ]] && printf yes || printf no)" \
    'shipped scripts expose literal config consumers'

# This is consumed by agent-run.sh as a runtime assertion, not as a persistent
# config.env declaration. Its documentation is still part of the onboarding
# contract so operators can discover the serialization control.
runtime_keys=(AGENT_COMPOSE_SERIALIZED)
consumed_keys+=("${runtime_keys[@]}")

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

finish
