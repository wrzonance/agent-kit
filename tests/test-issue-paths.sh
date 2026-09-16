#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='issue paths'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p "$repo/tools" "$repo/src" "$repo/docs" "$repo/.github/workflows"
printf 'tooling\n' >"$repo/tools/README.md"
printf 'source\n' >"$repo/src/existing.sh"
printf 'docs\n' >"$repo/docs/README.md"
printf 'workflow\n' >"$repo/.github/workflows/ci.yml"
ln -s tools "$repo/link"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" add -- .
git -C "$repo" commit -qm base

body="$tmp/body.md"
cat >"$body" <<'EOF'
Add `tools/bootstrap-worktree.sh` beside the tooling docs and update src/existing.sh.
The documentation output is docs/new-guide.md.
Ignore `missing/child.sh`, `link/escape.sh`, `../escape.sh`, `/tmp/escape.sh`,
`.github/workflows/new.yml`, and `scripts/*.sh`.
EOF

script="$root/agentkit/skills/parallel-issues/scripts/issue-paths.sh"
out=$("$script" --issue 202 --repo-root "$repo" --body-file "$body")
assert_eq $'create docs/new-guide.md\ncreate tools/bootstrap-worktree.sh\nexists src/existing.sh' "$out" \
    'the issue body yields deterministic literal exists/create predictions'
assert_not_contains "$out" 'link/escape.sh' 'a symlink ancestor cannot escape the repository tree'
assert_not_contains "$out" '.github/workflows' 'protected paths are excluded'
assert_not_contains "$out" '../' 'traversal is excluded'
assert_not_contains "$out" '*' 'glob-shaped text is not reported as a literal path'

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$tmp/gh.args"
printf '%s\n' '{"body":"Create \u0060tools/from-gh.sh\u0060."}'
EOF
chmod +x "$tmp/bin/gh"
out=$(PATH="$tmp/bin:$PATH" "$script" --issue 203 --repo-root "$repo")
assert_eq 'create tools/from-gh.sh' "$out" 'the public --issue interface fetches the body'
assert_contains "$(cat "$tmp/gh.args")" 'issue view 203' 'the requested issue number reaches gh as data'

finish
