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
version=$(jq -r .version < "$root/agentkit/.codex-plugin/plugin.json")

rm -rf -- "$dest"
mkdir -p "$dest/.claude-plugin" "$dest/agentkit/skills"

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

cp -a "$root/.claude-plugin/marketplace.json" "$dest/.claude-plugin/marketplace.json"

# Both manifests are COPIED, never regenerated. This script used to write its own
# plugin.json, so the built artifact could disagree with the repository about the
# hooks path or the version, and the tests would still pass -- they were checking
# this script's opinion rather than what ships.
#
# One per harness is not optional: a plugin missing a manifest does not install
# on that CLI at all, and the same tree is used from both.
for manifest in .codex-plugin .claude-plugin; do
    [[ -f $root/agentkit/$manifest/plugin.json ]] ||
        { printf 'missing agentkit/%s/plugin.json\n' "$manifest" >&2; exit 1; }
    mkdir -p "$dest/agentkit/$manifest"
    cp -a "$root/agentkit/$manifest/plugin.json" "$dest/agentkit/$manifest/plugin.json"
    jq -e . < "$dest/agentkit/$manifest/plugin.json" > /dev/null
done

# Hooks are plugin artifacts rather than skills, so they are authored under
# plugin-src/ and assembled here. -a keeps the executable bit codex needs.
# Only the two hook artifacts are copied: plugin-src/skills is a symlink onto the
# skill tree that exists so the hooks resolve their helpers the same way in the
# source tree as in the built plugin, and packaging it would ship a dangling one.
# hooks.json now lives INSIDE hooks/, which is where both harnesses look for
# it, so one copy carries the dispatchers and the manifest together.
cp -a "$root/agentkit/hooks" "$dest/agentkit/hooks"

jq -e . < "$dest/.claude-plugin/marketplace.json" > /dev/null

# OpenCode ships as a plain ES module + package.json under opencode/, packaged
# ALONGSIDE the Claude/Codex manifests, never touching their output: a third
# harness surface, not a replacement. There is no assembly step -- the module
# under opencode/ is already what ships, so this is a straight copy plus a
# manifest sanity check, same as the two plugin.json copies above.
mkdir -p "$dest/opencode"
cp -a "$root/opencode/package.json" "$dest/opencode/package.json"
cp -a "$root/opencode/index.js" "$dest/opencode/index.js"
jq -e . < "$dest/opencode/package.json" > /dev/null

# Follow the manifest's own declaration to the file rather than checking the file
# we just copied: an orphaned hooks.json is well-formed too, so validating it
# proves nothing about whether anything reads it.
hooks_rel=$(jq -r '.hooks // empty' < "$dest/agentkit/.codex-plugin/plugin.json")
[[ -n $hooks_rel ]] || { printf 'plugin.json declares no hooks file\n' >&2; exit 1; }
[[ -f $dest/agentkit/${hooks_rel#./} ]] ||
    { printf 'plugin.json declares a missing hooks file: %s\n' "$hooks_rel" >&2; exit 1; }
jq -e '.hooks' < "$dest/agentkit/${hooks_rel#./}" > /dev/null

printf 'built plugin at %s (version %s)\n' "$dest" "$version"
