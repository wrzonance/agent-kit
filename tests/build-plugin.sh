#!/usr/bin/env bash
# Assemble the agent-kit plugin from the skill tree.
#
# The same directory installs into BOTH Codex and Claude Code: codex reads
# .claude-plugin/marketplace.json, which is Claude's own manifest location.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
skills="$root/agentkit/skills"
dest=${1:-$root/plugin}
version=0.1.0

rm -rf -- "$dest"
mkdir -p "$dest/.claude-plugin" "$dest/agentkit/.codex-plugin"

# Skills, minus the vendor tree and minus anything test-shaped. -a preserves the
# executable bit, which codex needs.
cp -a "$skills/." "$dest/agentkit/skills/"

# .system is codex's OWN system-skills tree, vendored into the source layout so
# the harness can prove we never touch it. Packaging it would reinstall codex's
# built-ins under this plugin's name and carry .codex-system-skills.marker into
# a third-party plugin.
rm -rf -- "$dest/agentkit/skills/.system"

find "$dest/agentkit/skills" \( -name 'test-*' -o -name fixtures -o -name stub \) \
    -exec rm -rf -- {} + 2> /dev/null || true

cat > "$dest/.claude-plugin/marketplace.json" <<EOF
{
  "name": "agent-kit",
  "interface": { "displayName": "Agent Kit" },
  "plugins": [
    {
      "name": "agentkit",
      "source": { "source": "local", "path": "./agentkit" },
      "policy": { "installation": "AVAILABLE" }
    }
  ]
}
EOF

# "hooks" is not optional: without it the manifest registers no hook file, the
# harness never reads hooks.json, and the whole feature ships inert while every
# file that implements it is present and well-formed.
cat > "$dest/agentkit/.codex-plugin/plugin.json" <<EOF
{
  "name": "agentkit",
  "version": "$version",
  "description": "Board-aware parallel issue and PR review skills with a declared repository contract.",
  "license": "MIT",
  "skills": "./skills/",
  "hooks": "./hooks.json"
}
EOF

# Hooks are plugin artifacts rather than skills, so they are authored under
# plugin-src/ and assembled here. -a keeps the executable bit codex needs.
# Only the two hook artifacts are copied: plugin-src/skills is a symlink onto the
# skill tree that exists so the hooks resolve their helpers the same way in the
# source tree as in the built plugin, and packaging it would ship a dangling one.
cp -a "$root/agentkit/hooks" "$dest/agentkit/hooks"
cp -a "$root/agentkit/hooks.json" "$dest/agentkit/hooks.json"

jq -e . < "$dest/.claude-plugin/marketplace.json" > /dev/null
jq -e . < "$dest/agentkit/.codex-plugin/plugin.json" > /dev/null

# Follow the manifest's own declaration to the file rather than checking the file
# we just copied: an orphaned hooks.json is well-formed too, so validating it
# proves nothing about whether anything reads it.
hooks_rel=$(jq -r '.hooks // empty' < "$dest/agentkit/.codex-plugin/plugin.json")
[[ -n $hooks_rel ]] || { printf 'plugin.json declares no hooks file\n' >&2; exit 1; }
[[ -f $dest/agentkit/${hooks_rel#./} ]] ||
    { printf 'plugin.json declares a missing hooks file: %s\n' "$hooks_rel" >&2; exit 1; }
jq -e '.hooks' < "$dest/agentkit/${hooks_rel#./}" > /dev/null

printf 'built plugin at %s (version %s)\n' "$dest" "$version"
