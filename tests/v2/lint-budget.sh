#!/usr/bin/env bash
# The v2 static budgets from docs/superpowers/specs/2026-09-30-agentkit-v2-design.md.
# Raising a number here needs a field-run measurement that names the turn it saves.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../v2" && pwd)
MAX_SKILL_LINES=120
MAX_MD_BYTES=40960
MAX_CODE_LINES=5000
rc=0

while IFS= read -r skill; do
    n=$(wc -l <"$skill")
    ((n <= MAX_SKILL_LINES)) || { printf 'FAIL %s: %d lines > %d\n' "${skill#"$root"/}" "$n" "$MAX_SKILL_LINES"; rc=1; }
done < <(find "$root" -path "$root/skills/*" -name SKILL.md)

md=0
while IFS= read -r f; do md=$((md + $(wc -c <"$f"))); done < <(find "$root" -name '*.md')
((md <= MAX_MD_BYTES)) || { printf 'FAIL markdown %d bytes > %d\n' "$md" "$MAX_MD_BYTES"; rc=1; }

code=0
while IFS= read -r f; do code=$((code + $(wc -l <"$f"))); done < <(find "$root/bin" "$root/lib" -type f)
((code <= MAX_CODE_LINES)) || { printf 'FAIL code %d lines > %d\n' "$code" "$MAX_CODE_LINES"; rc=1; }

for manifest in "$root/.codex-plugin/plugin.json" "$root/.claude-plugin/plugin.json"; do
    jq -e 'has("hooks") | not' "$manifest" >/dev/null || { printf 'FAIL %s declares hooks\n' "$manifest"; rc=1; }
done
[[ ! -e $root/hooks ]] || { printf 'FAIL v2/hooks exists\n'; rc=1; }

((rc)) || printf 'v2 budget ok: markdown=%dB code=%d lines\n' "$md" "$code"
exit "$rc"
