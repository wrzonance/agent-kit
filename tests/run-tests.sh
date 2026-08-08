#!/usr/bin/env bash
# Canonical local verification for the skill tree. Run from anywhere.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# The plugin root holds both the skills and the hook dispatchers. The hooks are
# not skills, but they ship in the same artifact, so every gate that guards the
# skills guards them too -- scanning the plugin root covers both in one pass.
plugin="$root/agentkit"
skills="$plugin/skills"

rc=0
step() { printf '\n== %s\n' "$1"; }

step 'shellcheck (shipped scripts)'
mapfile -t scripts < <(find "$plugin" -name '*.sh' | sort)
printf '  %d scripts\n' "${#scripts[@]}"
# -x follows `# shellcheck source=` so the hooks' shared library is analysed as
# part of each caller; -P SCRIPTDIR resolves those paths against each script's
# own directory rather than the one this gate is invoked from.
shellcheck -x -P SCRIPTDIR -S style "${scripts[@]}" || rc=1

step 'bash -n (shipped scripts)'
for f in "${scripts[@]}"; do
    bash -n "$f" || rc=1
done
printf '  ok\n'

step 'bash 5.2 compatibility'
# The target is Debian trixie (bash 5.2.37); this machine runs 5.3. `bash -n`
# here would accept 5.3-only syntax that is a syntax error there, and no 5.2
# binary is available to test against -- so grep for the additions.
if grep -rnE '\$\{[[:space:]]|\$\{\||compgen -V|GLOBSORT' "$plugin" \
    --include='*.sh' --include='*.md'; then
    printf '  FAIL  bash 5.3-only syntax; the target is 5.2\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'shellcheck (test scripts)'
# The exclusion must be anchored to this directory. `-not -path '*/tmp/*'` was
# intended to skip the scratch dir, but the working root itself lives under /tmp,
# so it matched EVERY test script and this gate linted nothing for its whole life.
mapfile -t tscripts < <(find "$here" -name '*.sh' -not -path "$here/tmp/*" | sort)
((${#tscripts[@]} >= 5)) || {
    printf '  FAIL  only %d test scripts matched; the filter is excluding too much\n' \
        "${#tscripts[@]}" >&2
    rc=1
}
printf '  %d test scripts\n' "${#tscripts[@]}"
# -x follows `# shellcheck source=` directives so the helper's use of TEST_NAME
# is visible and does not read as a dead variable. -P SCRIPTDIR resolves those
# relative paths against each script's own directory rather than the caller's
# cwd, which is what this gate is run from.
shellcheck -x -P SCRIPTDIR -S style -e SC1091 "${tscripts[@]}" "$here/stub/gh" || rc=1

step 'markdown code blocks'
"$here/lint-markdown-blocks.sh" "$skills" || rc=1

step 'skill helper invocations'
"$here/lint-skill-invocations.sh" "$skills" || rc=1

step 'no vendored system skills'
# .system/ is Codex's OWN bundled skill set (imagegen, skill-creator,
# plugin-creator, review-agent, skill-installer, openai-docs), each under its own
# licence. It appeared here only because an early snapshot copied all of
# ~/.codex/skills. Shipping it would redistribute OpenAI's skills under this
# manifest and shadow ones Codex already provides.
if [[ -e $plugin/skills/.system ]]; then
    printf '  FAIL  .system/ is Codex own bundled skills and must not ship\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'ecosystem-neutrality'
# The skills must name commands, never ecosystems. A repo driven by make, cargo,
# uv, or a bespoke dispatcher gets a wrong example otherwise, and the agent burns
# a failed call discovering that.
#
# Detection code is the deliberate exception and marks itself: enumerating the
# ecosystems a repository MIGHT use is how the tree stays agnostic -- the
# opposite of prescribing one. Those lines carry an `ecosystem-allow:` marker
# stating why, so the exemption is per-line and visible in review rather than a
# whole file quietly dropping out of the gate.
#
# Matched as <tool> <subcommand>, not as `npm run` alone: the leak this gate
# missed was `-- npm test`, six lines away from a block that had already been
# converted. Naming the tool is what makes a line wrong, whatever subcommand
# follows it.
if grep -rnE -e '(^|[^a-z-])(pnpm|yarn)\b' \
    -e '(^|[^a-z./-])(npm|pnpm|yarn|bun|cargo|uv|poetry|pipenv|go|make|just|task|mvn|gradle|pytest|tox)[[:space:]]+(run|test|ci|install|build|check|lint|fmt|typecheck)([^a-z-]|$)' \
    "$plugin" --include='*.md' --include='*.sh' |
    grep -v 'ecosystem-allow:'; then
    printf '  FAIL  ecosystem-specific command in the shipped tree\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'no pre-plugin paths'
# Packaging moves the tree, so `$codex_home/skills/...` no longer resolves. The
# hooks kept teaching it in their deny messages long after the skills stopped
# using it -- a guard that corrects you with a broken command is worse than no
# guard, and only a live session surfaced it.
if grep -rn 'codex_home' "$plugin" \
    --include='*.sh' --include='*.md'; then
    printf '  FAIL  references the pre-plugin skills path\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'org-neutrality'
if grep -rniE 'jacobs|tango|bravo|wrzonance|thewrz|adam@|192\.168\.' \
    "$plugin" \
    --include='*.sh' --include='*.md' --include='*.yaml' --include='*.json'; then
    printf '  FAIL  organization-identifying text in the shipped tree\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'unit suites'
shopt -s nullglob
for suite in "$here"/test-*.sh; do
    printf '\n-- %s\n' "$(basename "$suite")"
    "$suite" || rc=1
done

printf '\n%s\n' "$([[ $rc -eq 0 ]] && echo 'ALL GREEN' || echo 'FAILURES ABOVE')"
exit "$rc"
