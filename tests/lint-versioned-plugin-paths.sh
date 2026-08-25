#!/usr/bin/env bash
# Detect a version-pinned plugin path where it would be READ AS A COMMAND TO
# RUN -- in skill markdown, reference markdown, or helper scripts.
#
# A path like ".../agentkit/0.5.0/skills/.shared/scripts/agent-run.sh" stops
# resolving the moment the plugin updates and the 0.5.0 directory is pruned,
# and then it fails as a bare missing-file error that never says why (#297).
# Operator-facing commands and anything recorded for a future resumed run to
# execute must use the contract/resolver form ($agentkit, or
# `contract-read.sh --get skills.path`) instead of a literal version segment.
#
# The trigger is a REAL digit immediately after "agentkit/". That single
# discriminator is deliberately what already separates every legitimate form
# in this tree from the hazard, with nothing extra to special-case:
#   - the detector's own regex literal (`agentkit/[0-9]` in
#     agentkit/hooks/post-tool-use.sh) has a literal "[" after the slash, not
#     a digit;
#   - the bootstrap discovery glob (`*/agentkit/*/skills`) has a literal "*";
#   - the resolver variable form (`$agentkit/...`, `agentkit/$version`) has a
#     "$";
#   - prose documenting the hazard abstractly (`agentkit/<version>/`, the
#     same convention issue #297's own spec uses) has a "<".
# A deliberate exception -- a hazard-documenting example that DOES spell out
# real digits -- marks itself `hazard-allow:` on the same line, the same
# per-line escape the ecosystem/harness/routing-neutrality gates use.
set -euo pipefail

program=${0##*/}
pattern='agentkit/[0-9][0-9A-Za-z.-]*/skills'

scan() {
    local root=$1 matches
    matches=$(grep -rnE "$pattern" "$root" --include='*.sh' --include='*.md' 2>/dev/null |
        grep -v 'hazard-allow:' || true)
    if [[ -n $matches ]]; then
        printf '%s\n' "$matches" >&2
        printf '%s: version-pinned plugin path read as a command; use the contract/resolver\n' \
            "$program" >&2
        # shellcheck disable=SC2016  # literal text for the reader, not shell expansion
        printf '  form ($agentkit, or "$agentkit/.shared/scripts/contract-read.sh" --get\n' >&2
        printf '  skills.path) instead of a literal agentkit/<version>/ path\n' >&2
        return 1
    fi
    return 0
}

selftest() {
    local tmp fail=0
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' RETURN

    # 1. An executed pinned path -- the hazard this lint exists to catch.
    mkdir -p "$tmp/violation/skills/.shared"
    cat > "$tmp/violation/skills/.shared/example.md" <<'EOF'
Run it by hand:

```bash
/home/x/.claude/plugins/cache/agent-kit/agentkit/0.5.0/skills/.shared/scripts/agent-run.sh --cmd test
```
EOF
    if scan "$tmp/violation" > /dev/null 2>&1; then
        printf '%s: selftest FAIL: an executed pinned path was not flagged\n' "$program" >&2
        fail=1
    fi

    # 2. The detector's own regex literal must not be flagged.
    mkdir -p "$tmp/detector"
    cat > "$tmp/detector/post-tool-use.sh" <<'EOF'
if grep -qE 'plugins/cache/[^[:space:]]*agentkit/[0-9]' <<< "$command_line"; then
    :
fi
EOF
    if ! scan "$tmp/detector" > /dev/null 2>&1; then
        printf '%s: selftest FAIL: the detector regex literal was flagged\n' "$program" >&2
        fail=1
    fi

    # 3. The bootstrap discovery glob must not be flagged.
    mkdir -p "$tmp/bootstrap"
    cat > "$tmp/bootstrap/SKILL.md" <<'EOF'
```bash
agentkit=$(find "$HOME/.claude/plugins/cache" -maxdepth 4 -type d -path '*/agentkit/*/skills' | sort -V | tail -1)
```
EOF
    if ! scan "$tmp/bootstrap" > /dev/null 2>&1; then
        printf '%s: selftest FAIL: the bootstrap discovery glob was flagged\n' "$program" >&2
        fail=1
    fi

    # 4. Prose quoting a pinned path as an example of the hazard, marked
    #    hazard-allow, must not be flagged even though it spells out real
    #    digits.
    mkdir -p "$tmp/prose"
    cat > "$tmp/prose/reference.md" <<'EOF'
A stale command looks like `agentkit/0.5.0/skills/.shared/scripts/agent-run.sh`.  <!-- hazard-allow: documents the #297 hazard, not an emitted command -->
EOF
    if ! scan "$tmp/prose" > /dev/null 2>&1; then
        printf '%s: selftest FAIL: a hazard-allow-marked hazard example was flagged\n' "$program" >&2
        fail=1
    fi

    if ((fail)); then
        return 1
    fi
    printf '%s: selftest ok, 4/4 fixtures behaved as pinned\n' "$program"
    return 0
}

if [[ ${1:-} == --selftest ]]; then
    selftest
    exit $?
fi

root=${1:?usage: lint-versioned-plugin-paths.sh ROOT_DIR|--selftest}
[[ -d $root ]] || {
    printf '%s: not a directory: %s\n' "$program" "$root" >&2
    exit 2
}

if scan "$root"; then
    printf '%s: ok, no version-pinned plugin paths in %s\n' "$program" "$root"
    exit 0
fi
exit 1
