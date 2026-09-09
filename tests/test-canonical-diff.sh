#!/usr/bin/env bash
# Boundary coverage for the shared canonical-diff touched-path derivation
# (issue #609 fix round 2, P1): a payload's granted-paths set must include
# every file a diff actually touches -- a quoted/non-ASCII name, a rename, a
# mode-only change, a binary file -- and must refuse rather than under-report
# when it cannot be determined.
set -uo pipefail

TEST_NAME='canonical-diff'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
lib="$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- End-to-end: payload --base-ref --emit-paths against a real git repo
# carrying a quoted/non-ASCII path, a rename, a mode-only change, and a
# binary file, none of which a `---`/`+++` header grep reliably recovers.
origin="$tmp/origin.git"
repo="$tmp/repo"
git init --bare --quiet "$origin"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" config core.quotepath true
git -C "$repo" remote add origin "$origin"
printf 'base\n' >"$repo/fileA"
printf 'base\n' >"$repo/fileB"
printf 'base\n' >"$repo/fileC"
git -C "$repo" add fileA fileB fileC
git -C "$repo" commit --quiet -m base
git -C "$repo" push --quiet -u origin main
git -C "$repo" switch --quiet -c feature
printf 'changed\n' >"$repo/fileA"
printf 'secret\n' >"$repo/confidential-é.txt"
git -C "$repo" add fileA "confidential-é.txt"
git -C "$repo" mv fileB fileB-renamed
chmod +x "$repo/fileC"
git -C "$repo" add fileC
printf '\x00\x01binary' >"$repo/bin.dat"
git -C "$repo" add bin.dat
git -C "$repo" commit --quiet -m 'changes'

emitted="$tmp/emitted-paths"
payload=$(
    cd -- "$repo" || exit
    /bin/bash "$script" payload --worktree "$repo" --repo acme/widget --pr 60 \
        --base-ref main --emit-paths "$emitted"
)
assert_eq yes "$( [[ -n $payload ]] && printf yes || printf no )" \
    'a diff carrying a quoted path, a rename, a mode-only change and a binary file still derives a payload'
emitted_paths=$(<"$emitted")
assert_contains "$emitted_paths" 'fileA' 'the emitted set includes the ordinarily-modified file'
assert_contains "$emitted_paths" 'confidential-é.txt' \
    'the emitted set includes the quoted/non-ASCII path (issue #609 P1)'
assert_contains "$emitted_paths" 'fileB' 'the emitted set includes a rename source'
assert_contains "$emitted_paths" 'fileB-renamed' 'the emitted set includes a rename destination'
assert_contains "$emitted_paths" 'fileC' 'the emitted set includes a mode-only change with no content hunk'
assert_contains "$emitted_paths" 'bin.dat' 'the emitted set includes a binary file'

# An ungranted quoted path re-asks: a grant scoped to a payload that only
# ever touched fileA must not cover the wider PR payload above, which also
# touches confidential-é.txt (this is the exact P1 attack shape -- a payload
# that "adds confidential-é.txt beside a granted fileA").
state="$tmp/state/record"
mkdir -p -- "$tmp/state"
chmod 700 -- "$tmp/state"
fileA_only_diff="$tmp/fileA-only.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 main...feature -- fileA >"$fileA_only_diff"
fileA_only_paths="$tmp/fileA-only-paths"
fileA_only_payload=$(/bin/bash "$script" payload --repo acme/widget --pr 60 \
    --diff "$fileA_only_diff" --emit-paths "$fileA_only_paths")
assert_eq differ "$( [[ $fileA_only_payload != "$payload" ]] && printf differ || printf same )" \
    'the fileA-only grant payload and the full base-ref payload carry different digests'
/bin/bash "$script" grant --state "$state" --provider openai \
    --payload "$fileA_only_payload" --source auto-review-flag --paths-file "$fileA_only_paths" >/dev/null
requoted_check_rc=0
requoted_check_error=$(/bin/bash "$script" check --state "$state" --provider openai \
    --payload "$payload" --paths-file "$emitted" 2>&1) || requoted_check_rc=$?
assert_eq 10 "$requoted_check_rc" \
    'a grant scoped to fileA alone never covers the wider payload that also touches the quoted file'
assert_contains "$requoted_check_error" 'confidential-é.txt' \
    'the re-ask names the ungranted quoted path'

# --- Unit coverage: diff_touched_paths_from_range refuses when it cannot be
# determined, rather than silently under-reporting.
# shellcheck source=../agentkit/skills/.shared/scripts/lib/canonical-diff.sh
source "$lib"
mismatch_repo="$tmp/mismatch-repo"
git init --quiet --initial-branch=main "$mismatch_repo"
git -C "$mismatch_repo" config user.email test@example.invalid
git -C "$mismatch_repo" config user.name test
printf 'one\n' >"$mismatch_repo/one.txt"
git -C "$mismatch_repo" add one.txt
git -C "$mismatch_repo" commit --quiet -m base
git -C "$mismatch_repo" switch --quiet -c feature
printf 'two\n' >"$mismatch_repo/one.txt"
git -C "$mismatch_repo" commit --quiet -am change
not_git_diff="$tmp/not-a-git-diff"
printf 'this is not a diff --git rendering at all\n' >"$not_git_diff"
check_mismatch() {
    cd -- "$mismatch_repo" || return
    diff_touched_paths_from_range 'main...feature' main "$not_git_diff" >/dev/null
}
assert_rc 1 'diff_touched_paths_from_range refuses when the file record count does not match the range (undeterminable set)' -- \
    check_mismatch

empty_git_diff="$tmp/empty-git-diff"
: >"$empty_git_diff"
check_zero_records() {
    cd -- "$mismatch_repo" || return
    diff_touched_paths_from_range 'main...feature' main "$empty_git_diff" >/dev/null
}
assert_rc 1 'diff_touched_paths_from_range refuses when the supplied diff file records zero diff --git headers but the range touches a file' -- \
    check_zero_records

# --- Unit coverage: the text-parsing fallback (no known range) also refuses
# rather than guesses on a quoted header or a record-count mismatch. The
# fixture mixes a plain header (fileA, as an ordinary granted file would
# render) with a quoted one, mirroring the real P1 attack shape -- a payload
# that adds a quoted/non-ASCII path beside a granted plain one -- rather than
# an all-quoted file, where a bare grep's own exit status would coincidentally
# look like a refusal for the wrong reason.
quoted_fallback_diff="$tmp/quoted-fallback.diff"
cat >"$quoted_fallback_diff" <<'EOF'
--- a/fileA
+++ b/fileA
@@ -1 +1 @@
-old
+new
diff --git "a/confidential-\303\251.txt" "b/confidential-\303\251.txt"
index 0000000..1111111 100644
--- "a/confidential-\303\251.txt"
+++ "b/confidential-\303\251.txt"
@@ -1 +1 @@
-old
+new
EOF
assert_rc 1 'diff_touched_paths refuses a quoted header rather than silently omitting it beside a plain granted path' -- \
    diff_touched_paths "$quoted_fallback_diff"

mode_only_fallback_diff="$tmp/mode-only-fallback.diff"
cat >"$mode_only_fallback_diff" <<'EOF'
diff --git a/fileC b/fileC
old mode 100644
new mode 100755
diff --git a/fileA b/fileA
index 0000000..1111111 100644
--- a/fileA
+++ b/fileA
@@ -1 +1 @@
-old
+new
EOF
assert_rc 1 'diff_touched_paths refuses when a diff --git record (mode-only, no hunk) has no matching header pair' -- \
    diff_touched_paths "$mode_only_fallback_diff"

well_formed_diff="$tmp/well-formed.diff"
cat >"$well_formed_diff" <<'EOF'
--- a/fileA
+++ b/fileA
@@ -1 +1 @@
-old
+new
EOF
assert_eq 'fileA' "$(diff_touched_paths "$well_formed_diff")" \
    'diff_touched_paths still parses a plain header-only diff with no diff --git framing'

finish
