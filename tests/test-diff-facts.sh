#!/usr/bin/env bash
# Suite: diff-facts reports line facts split by repository-declared category.
set -uo pipefail

TEST_NAME='diff-facts'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

script="$root/agentkit/skills/.shared/scripts/diff-facts.sh"
repo="$tmp/repo with spaces"
mkdir -p "$repo/.agent" "$repo/src" "$repo/generated" "$repo/tests/fixtures"
git -C "$repo" init -q -b base
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name 'Diff Facts Test'

cat > "$repo/.agent/config.env" <<'EOF'
AGENT_BASE_BRANCH=base
AGENT_GENERATED_PATHS=generated/,openapi.json
EOF
printf 'old\n' > "$repo/src/app.sh"
printf 'old\n' > "$repo/generated/api.ts"
printf '{"openapi":"3.0"}\n' > "$repo/openapi.json"
printf '{"lockfileVersion":3}\n' > "$repo/package-lock.json"
printf 'old\n' > "$repo/tests/fixtures/example.json"
git -C "$repo" add -- .
git -C "$repo" commit -q -m base

printf 'old\noperational one\noperational two\n' > "$repo/src/app.sh"
printf 'old\ngenerated one\ngenerated two\ngenerated three\n' > "$repo/generated/api.ts"
printf '{"openapi":"3.0"}\nopenapi line one\nopenapi line two\nopenapi line three\nopenapi line four\n' > "$repo/openapi.json"
printf '{"lockfileVersion":3}\nlock one\nlock two\nlock three\nlock four\nlock five\n' > "$repo/package-lock.json"
printf 'old\nfixture one\nfixture two\nfixture three\nfixture four\nfixture five\nfixture six\n' > "$repo/tests/fixtures/example.json"

out=$(bash "$script" --repo-root "$repo")
assert_contains "$out" 'base=base' 'uses the declared base by default'
assert_contains "$out" 'files=5' 'reports changed file count'
assert_contains "$out" 'total.insertions=20' 'reports total insertions'
assert_contains "$out" 'total.deletions=0' 'reports total deletions'
assert_contains "$out" 'total.lines=20' 'reports total changed lines'
assert_contains "$out" 'operational.files=1' 'reports operational file count'
assert_contains "$out" 'operational.insertions=2' 'reports operational insertions'
assert_contains "$out" 'operational.lines=2' 'reports operational lines'
assert_contains "$out" 'generated.files=2' 'reports generated file count'
assert_contains "$out" 'generated.insertions=7' 'reports generated insertions'
assert_contains "$out" 'generated.lines=7' 'reports generated lines'
assert_contains "$out" 'lockfile.files=1' 'reports lockfile file count'
assert_contains "$out" 'lockfile.insertions=5' 'reports lockfile insertions'
assert_contains "$out" 'fixture.files=1' 'reports fixture file count'
assert_contains "$out" 'fixture.insertions=6' 'reports fixture insertions'
assert_contains "$out" 'non_operational.files=4' 'reports excluded file count'
assert_contains "$out" 'non_operational.lines=18' 'reports excluded lines'
assert_not_contains "$out" 'verdict' 'does not emit a verdict'
assert_not_contains "$out" 'trivial' 'does not emit a triviality judgment'

explicit=$(bash "$script" --repo-root "$repo" --base base)
assert_eq "$out" "$explicit" 'explicit base produces the same facts'

spaced_helpers="$tmp/helper scripts with spaces"
mkdir -p "$spaced_helpers"
cp "$script" "$spaced_helpers/diff-facts.sh"
cp "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
    "$spaced_helpers/repo-config.sh"
chmod +x "$spaced_helpers/diff-facts.sh" "$spaced_helpers/repo-config.sh"
spaced_out=$(bash "$spaced_helpers/diff-facts.sh" --repo-root "$repo")
assert_contains "$spaced_out" 'base=base' \
    'resolves repository config when the helper path contains spaces'
assert_contains "$spaced_out" 'generated.files=2' \
    'loads generated-path configuration when the helper path contains spaces'

advanced_repo="$tmp/advanced base repo"
mkdir -p "$advanced_repo/.agent" "$advanced_repo/src"
git -C "$advanced_repo" init -q -b base
git -C "$advanced_repo" config user.email test@example.invalid
git -C "$advanced_repo" config user.name 'Diff Facts Test'
cat > "$advanced_repo/.agent/config.env" <<'EOF'
AGENT_BASE_BRANCH=advanced-base
EOF
printf 'root\n' > "$advanced_repo/src/app.sh"
git -C "$advanced_repo" add -- .
git -C "$advanced_repo" commit -q -m root
git -C "$advanced_repo" checkout -q -b feature
printf 'root\nfeature change\n' > "$advanced_repo/src/app.sh"
git -C "$advanced_repo" add -- src/app.sh
git -C "$advanced_repo" commit -q -m feature
git -C "$advanced_repo" checkout -q base
git -C "$advanced_repo" branch -m advanced-base
printf 'root\nadvanced base change\n' > "$advanced_repo/src/app.sh"
git -C "$advanced_repo" add -- src/app.sh
git -C "$advanced_repo" commit -q -m 'advance base'
git -C "$advanced_repo" checkout -q feature

advanced_out=$(bash "$script" --repo-root "$advanced_repo")
assert_contains "$advanced_out" 'base=advanced-base' \
    'prints the named base ref after resolving its merge base'
assert_contains "$advanced_out" 'operational.insertions=1' \
    'counts only changes after the merge base'
assert_contains "$advanced_out" 'operational.lines=1' \
    'does not count commits added to the advanced base branch'

assert_rc 2 'rejects a missing base value' -- bash "$script" --repo-root "$repo" --base
assert_rc 2 'rejects an unknown option' -- bash "$script" --repo-root "$repo" --nope

printf 'AGENT_GENERATED_PATHS=/tmp/generated\n' > "$repo/.agent/config.env"
err=$(bash "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
    --repo-root "$repo" --list 2>&1 > /dev/null)
assert_contains "$err" 'AGENT_GENERATED_PATHS' 'warns when generated paths escape the repo'
out=$(bash "$root/agentkit/skills/.shared/scripts/repo-config.sh" \
    --repo-root "$repo" --list 2> /dev/null)
assert_not_contains "$out" 'AGENT_GENERATED_PATHS=' 'drops invalid generated paths'

assert_contains "$(<"$root/agentkit/skills/.shared/schema/config.env.example")" \
    'AGENT_GENERATED_PATHS=' 'onboarding schema surfaces generated paths'
assert_contains "$(<"$root/agentkit/skills/parallel-issues/SKILL.md")" \
    'operational lines' 'parallel issue guidance names operational lines'

if command -v zsh > /dev/null 2>&1; then
    rc=0
    err=$(zsh "$script" --help 2>&1 > /dev/null) || rc=$?
    assert_eq '3' "$rc" 'rejects an interpreter without Bash associative-array support'
    assert_contains "$err" 'requires Bash >= 4' \
        'interpreter guard names the Bash requirement'
    assert_contains "$err" 'run this helper with bash, not zsh' \
        'interpreter guard names the required interpreter'
else
    prefix=$(sed -n '1,35p' "$script")
    assoc_line=$(grep -n 'declare -A' "$script" | head -n 1 | cut -d: -f1)
    guard_line=$(grep -n 'requires Bash >= 4' "$script" | head -n 1 | cut -d: -f1)
    assert_contains "$prefix" 'requires Bash >= 4' \
        'source contract names the Bash requirement when zsh is unavailable'
    assert_contains "$prefix" 'exit 3' \
        'source contract uses a distinct environment failure exit'
    if ((guard_line < assoc_line)); then
        _pass 'source contract places the interpreter guard before associative declarations'
    else
        _fail 'source contract places the interpreter guard before associative declarations' \
            "guard line $guard_line is not before associative declaration line $assoc_line"
    fi
fi

finish
