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

step 'harness-neutrality'
# The tree runs under more than one agent CLI, from more than one account. Three
# ways that breaks, each of which has actually happened:
#
#   1. A resolver that searches one harness's plugin cache. Every helper
#      invocation then resolves to nothing on the other CLI.
#   2. A manifest for one harness only. The plugin does not install at all.
#   3. Prose that names one CLI as THE harness -- "the shell Codex runs",
#      "one Codex issue lead" -- which reads as an instruction, not a note.
#
# Cross-harness references are the deliberate exception and mark themselves with
# `harness-allow:`, the same per-line, visible-in-review escape the
# ecosystem gate uses. Naming BOTH CLIs in one line is inherently even-handed and
# passes without a marker.
harness_rc=0

while IFS= read -r resolver_file; do
    if grep -q 'CODEX_HOME' "$resolver_file" && ! grep -q 'CLAUDE_CONFIG_DIR' "$resolver_file"; then
        printf '  FAIL  %s searches one harness cache only\n' "$resolver_file" >&2
        harness_rc=1
    fi
done < <(grep -rl 'plugins/cache' "$plugin" --include='*.sh' --include='*.md')

for manifest in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
    if [[ ! -r $plugin/$manifest ]]; then
        printf '  FAIL  missing %s; the plugin will not install on that harness\n' "$manifest" >&2
        harness_rc=1
    fi
done

# Both harnesses look for the hook manifest at hooks/hooks.json.
if [[ ! -r $plugin/hooks/hooks.json ]]; then
    printf '  FAIL  hooks/hooks.json is where both harnesses look for it\n' >&2
    harness_rc=1
fi

# Naming a CLI is not the failure -- the concrete review recipes MUST name one,
# and instruction files, config paths, model ids and script flags all carry the
# names harmlessly. The failure is prose that tells the agent WHAT IT IS, so this
# matches assumption-shaped phrasing rather than every mention. A curated pattern
# risks missing a novel phrasing; matching every mention produced forty lines of
# noise and would have been switched off within a week.
if grep -rniE '\b(codex|claude)\b[[:space:]]+(runs|uses|exposes|commonly|issue lead|session|harness|runtime|agent\b)|the shell (codex|claude)|(codex|claude) (credit|equivalent)|one \*\*(codex|claude)' \
    "$skills" --include='*.md' --include='*.sh' |
    grep -viE 'harness-allow:' |
    grep -viE '\bcodex\b.*\bclaude\b|\bclaude\b.*\bcodex\b'; then
    printf '  FAIL  prose that names one agent CLI as THE harness. Write it from the\n' >&2
    printf '        contract (harness= / peer-cli=), or mark a deliberate\n' >&2
    printf '        cross-harness reference with harness-allow:\n' >&2
    harness_rc=1
fi

[[ $harness_rc -eq 0 ]] && printf '  ok\n' || rc=1

step 'org-neutrality'
if grep -rniE 'jacobs|tango|bravo|wrzonance|thewrz|adam@|192\.168\.' \
    "$plugin" \
    --include='*.sh' --include='*.md' --include='*.yaml' --include='*.json'; then
    printf '  FAIL  organization-identifying text in the shipped tree\n' >&2
    rc=1
else
    printf '  ok\n'
fi

# The README stated eight suites and ~350 assertions while the tree carried
# eleven and six hundred. Nobody noticed, because nothing checked -- and an
# external review reasonably read the overstatement as a coverage claim. A count
# in prose is a fact about the tree, so the tree gets to enforce it.
step 'README matches the suite inventory'
readme_suites=$(sed -n 's/.*and \([a-z]*\) suites.*/\1/p' "$root/README.md" | head -1)
actual_suites=$(find "$here" -maxdepth 1 -name 'test-*.sh' | wc -l | tr -d ' ')
declare -A NUMBER_WORD=(
    [8]=eight [9]=nine [10]=ten [11]=eleven [12]=twelve [13]=thirteen
    [14]=fourteen [15]=fifteen [16]=sixteen [17]=seventeen [18]=eighteen
    [19]=nineteen [20]=twenty
)
expected_word=${NUMBER_WORD[$actual_suites]:-$actual_suites}
if [[ $readme_suites == "$expected_word" ]]; then
    printf '  ok\n'
else
    printf '  FAIL  README says "%s suites", tree has %s (%s)\n' \
        "$readme_suites" "$actual_suites" "$expected_word" >&2
    rc=1
fi

step 'unit suites'
shopt -s nullglob
for suite in "$here"/test-*.sh; do
    printf '\n-- %s\n' "$(basename "$suite")"
    "$suite" || rc=1
done

printf '\n%s\n' "$([[ $rc -eq 0 ]] && echo 'ALL GREEN' || echo 'FAILURES ABOVE')"
exit "$rc"
