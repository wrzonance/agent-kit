#!/usr/bin/env bash
# Verify the shipped reference manifest and the filesystem agree in BOTH
# directions: no manifest entry without a file, no reference file absent from
# the manifest.
#
# Companion references live in `.shared/` and `<skill>/references/`. The first
# is invisible to `rg --files` without `--hidden`, to shell globs without
# `dotglob`, and to naive `find`-based discovery -- so an agent that cannot
# resolve a named reference degrades into a filesystem search instead of a
# clean "not found here". The manifest is the deterministic answer to "what
# references exist and where", and it is only worth trusting if it cannot
# silently drift from the tree it describes. A rename must surface as a named
# mismatch on both sides, never as a manifest that quietly describes a file
# that moved.
set -euo pipefail

program=${0##*/}
skills_dir=${1:?usage: lint-reference-manifest.sh SKILLS_DIR}
[[ -d $skills_dir ]] || {
    printf '%s: skills directory is missing: %s\n' "$program" "$skills_dir" >&2
    exit 2
}
skills_dir=$(cd -- "$skills_dir" && pwd -P)

# Deliberately non-dotted and directly under the skills tree: the manifest that
# exists to escape hidden-directory discovery must not itself be hidden.
readonly MANIFEST_NAME='references.md'
manifest="$skills_dir/$MANIFEST_NAME"

violations=0
report() {
    printf 'VIOLATION %s: %s\n' "$program" "$1" >&2
    violations=$((violations + 1))
}

if [[ ! -f $manifest ]]; then
    report "the reference manifest is missing: $manifest -- every reference file must be listed there with its purpose"
    printf '%s: %d violation(s)\n' "$program" "$violations" >&2
    exit 1
fi

# Entry grammar, matching the manifest's own documented shape:
#   - `$agentkit/<path>` -- <one-line purpose>
# `$agentkit` is the resolved skills tree, so <path> is simultaneously the
# path relative to that tree and the form an agent can open without
# reconstructing a prefix. A bare relative path would resolve only by accident
# of where the manifest happens to sit.
# shellcheck disable=SC2016  # $agentkit is literal manifest text, never expanded here
readonly ENTRY_RE='^- `\$agentkit/([^`]+)` -- +([^ ].*)$'

declare -A listed=()
entries=0
fenced=0
while IFS= read -r line; do
    # The manifest documents its own grammar in a fenced block. Parsing that
    # example as an entry would make the file fail on its own documentation,
    # so fences are skipped rather than the example being contorted to hide
    # from the parser.
    if [[ $line == '```'* ]]; then
        fenced=$((1 - fenced))
        continue
    fi
    ((fenced == 0)) || continue
    # shellcheck disable=SC2016  # the literal prefix the manifest writes
    [[ $line == '- `$agentkit/'* ]] || continue
    entries=$((entries + 1))
    if [[ ! $line =~ $ENTRY_RE ]]; then
        report "malformed manifest entry (expected '- \`\$agentkit/<path>\` -- <one-line purpose>'): $line"
        continue
    fi
    rel=${BASH_REMATCH[1]}
    if [[ $rel != *.md || $rel == */../* || $rel == ../* || $rel == /* ]]; then
        report "manifest entry is not a tree-relative markdown path: $rel"
        continue
    fi
    if [[ -n ${listed[$rel]:-} ]]; then
        report "duplicate manifest entry for $rel -- each reference file is listed exactly once"
        continue
    fi
    listed[$rel]=1
    [[ -f "$skills_dir/$rel" ]] ||
        report "manifest entry names a file that does not ship: $rel (looked for $skills_dir/$rel)"
done < "$manifest"

# A manifest that parses to nothing would pass every comparison below against
# an empty tree. Scanning nothing is a failure, never a pass.
((entries > 0)) ||
    report "the manifest carries no entries -- it must list every reference file with its purpose"

# The filesystem side. `.shared/*.md` is the shared-policy set both split
# skills paste into worker prompts; `<skill>/references/*.md` is the per-skill
# set (lint-skill-size.sh already forbids subdirectories under references/, so
# the depth is fixed).
shipped=0
while IFS= read -r file; do
    rel=${file#"$skills_dir/"}
    shipped=$((shipped + 1))
    [[ -n ${listed[$rel]:-} ]] ||
        report "reference file is absent from $MANIFEST_NAME: $rel -- add it with a one-line purpose"
done < <(
    {
        [[ -d $skills_dir/.shared ]] &&
            find "$skills_dir/.shared" -maxdepth 1 -type f -name '*.md'
        find "$skills_dir" -mindepth 3 -maxdepth 3 -type f -path '*/references/*.md'
    } | sort
)

if ((violations)); then
    printf '%s: %d violation(s)\n' "$program" "$violations" >&2
    exit 1
fi
printf '%s: %d manifest entries, %d reference files, both directions agree\n' \
    "$program" "$entries" "$shipped"
