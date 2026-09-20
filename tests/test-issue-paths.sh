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
printf 'readme\n' >"$repo/README.md"
ln -s tools "$repo/link"
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" add -- .
git -C "$repo" commit -qm base

body="$tmp/body.md"
cat >"$body" <<'EOF'
Add `tools/bootstrap-worktree.sh` beside the tooling docs and update src/existing.sh.
Create `NEW.md`, `.gitignore`, and `.editorconfig`; update README.md.
The documentation output is docs/new-guide.md.
Run `jq` with `--dry-run`; Status remains Ready.
Release version `1.2.3` after the files are ready.
Ignore `missing/child.sh`, `link/escape.sh`, `../escape.sh`, `/tmp/escape.sh`,
`.github/workflows/new.yml`, and `scripts/*.sh`.
EOF

script="$root/agentkit/skills/parallel-issues/scripts/issue-paths.sh"
out=$("$script" --issue 202 --repo-root "$repo" --body-file "$body")
assert_eq $'create .editorconfig\ncreate .gitignore\ncreate NEW.md\ncreate docs/new-guide.md\ncreate tools/bootstrap-worktree.sh\nexists README.md\nexists src/existing.sh' "$out" \
    'the issue body yields deterministic literal exists/create predictions'
assert_not_contains "$out" 'link/escape.sh' 'a symlink ancestor cannot escape the repository tree'
assert_not_contains "$out" '.github/workflows' 'protected paths are excluded'
assert_not_contains "$out" '../' 'traversal is excluded'
assert_not_contains "$out" '*' 'glob-shaped text is not reported as a literal path'
assert_not_contains "$out" 'dry-run' 'a command option is not reported as a path'
assert_not_contains "$out" 'jq' 'a command name is not invented as a root file'
assert_not_contains "$out" 'Status' 'a status word is not invented as a root file'
assert_not_contains "$out" '1.2.3' 'quoted dotted prose is not invented as a root file'

mkdir -p "$tmp/failing-bin"
real_git=$(command -v git)
cat >"$tmp/failing-bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ " $* " == *' ls-tree '* ]]; then
    exit 42
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x "$tmp/failing-bin/git"
rc=0
out=$(REAL_GIT="$real_git" PATH="$tmp/failing-bin:$PATH" \
    "$script" --issue 202 --repo-root "$repo" --body-file "$body" 2>&1) || rc=$?
assert_eq '1' "$rc" 'a failed repository tree read fails the public helper'
assert_contains "$out" 'could not list repository tree' \
    'the tree evidence failure is explicit'

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

# Issue #846: the prediction order must be the helper's, not the caller's.
# Under a punctuation-ignoring collation an unpinned `sort` moved
# `docs/new-guide.md` ahead of `.editorconfig`, so the same tree and body
# produced different bytes on a developer's shell than on CI. Resolve a locale
# that actually collates differently from C; with none installed the comparison
# would be vacuous, so say that rather than bank a pass it did not earn.
# Not any other locale: one that demonstrably orders differently from C. Most
# UTF-8 locales collate bytewise like C, and picking one of those would bank a
# pass that proves nothing. The probe reverses only where punctuation is
# ignored, which is the collation that produced the bug.
c_probe=$(printf '.z\nay\n' | LC_ALL=C sort)
alt_locale=''
while IFS= read -r candidate; do
    case $candidate in
        C | C.* | POSIX) continue ;;
        *.UTF-8 | *.utf8) ;;
        *) continue ;;
    esac
    if [[ $(printf '.z\nay\n' | LC_ALL="$candidate" sort) != "$c_probe" ]]; then
        alt_locale=$candidate
        break
    fi
done < <(locale -a 2> /dev/null || true)
if [[ -n $alt_locale ]]; then
    c_order=$(LC_ALL=C "$script" --issue 202 --repo-root "$repo" --body-file "$body")
    alt_order=$(LC_ALL="$alt_locale" "$script" --issue 202 --repo-root "$repo" --body-file "$body")
    assert_eq "$c_order" "$alt_order" "prediction order does not follow the caller locale ($alt_locale)"
else
    printf '  skip no non-C UTF-8 locale installed; collation independence unverified here\n'
fi

finish
