#!/usr/bin/env bash
# A concrete hook/harness proposal is scoped without touching live protected
# state, then applied by the agent only after the existing ledger covers it.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='protected patch proposal boundary (#911 review)'

helper="$root/agentkit/skills/.shared/scripts/protected-patch.sh"
commit_helper="$root/agentkit/skills/.shared/scripts/worktree-commit.sh"
ledger_helper="$root/agentkit/skills/.shared/scripts/session-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/.claude" "$repo/.agent"
printf '{"mode":"base"}\n' > "$repo/.claude/settings.json"
printf 'seed\n' > "$repo/seed.txt"
git -C "$repo" add -- .claude/settings.json seed.txt
git -C "$repo" commit -qm base
git -C "$repo" checkout -qb feature

patch="$tmp/settings.patch"
content="$repo/.agent/settings.proposed"
printf '{"mode":"approved"}\n' >"$content"
draft_out=$(cd "$repo" && "$helper" draft --path .claude/settings.json \
    --content "$content" --output "$patch")
assert_contains "$draft_out" 'path=.claude/settings.json' \
    'the helper generates a review patch from safely stored proposed content'
assert_eq '{"mode":"base"}' "$(cat "$repo/.claude/settings.json")" \
    'draft generation does not write the live harness configuration'
assert_contains "$(cat "$patch")" '+++ b/.claude/settings.json' \
    'the generated patch targets the protected repository path'

scope_out=$(cd "$repo" && "$helper" scope --patch "$patch")
scope=${scope_out#approval_scope=}
scope=${scope%% *}
assert_contains "$scope" 'protected-tree:' \
    'proposal scope uses the existing exact protected-tree authorization shape'
assert_eq '{"mode":"base"}' "$(cat "$repo/.claude/settings.json")" \
    'scope derivation does not write the live harness configuration'
assert_rc 0 'scope derivation leaves the real index untouched' -- \
    git -C "$repo" diff --cached --quiet

ledger="$repo/.agent/session-ledger.ndjson"
apply_rc=0
apply_out=$(cd "$repo" && "$helper" apply --patch "$patch" --ledger "$ledger" \
    --run-id issue-911-review --ledger-scope "$scope" 2>&1) || apply_rc=$?
assert_eq '3' "$apply_rc" 'an unapproved proposal is not applied'
assert_contains "$apply_out" 'failure-v1 class=permission-trust-refusal' \
    'the missing proposal grant is a typed authorization handback'
assert_eq '{"mode":"base"}' "$(cat "$repo/.claude/settings.json")" \
    'the refused apply leaves the live harness configuration unchanged'
assert_rc 0 'the refused apply leaves the real index untouched' -- \
    git -C "$repo" diff --cached --quiet

"$ledger_helper" append --ledger "$ledger" --run-id issue-911-review \
    --skills-path "$root/agentkit/skills" --procedure-set parallel-issues \
    --decision authorize:protected-commit --scope "$scope" \
    --quote 'approved the concrete protected patch' >/dev/null
apply_out=$(cd "$repo" && "$helper" apply --patch "$patch" --ledger "$ledger" \
    --run-id issue-911-review --ledger-scope "$scope")
assert_contains "$apply_out" "applied_scope=$scope" \
    'the covering concrete grant applies the reviewed patch'
assert_eq '{"mode":"approved"}' "$(cat "$repo/.claude/settings.json")" \
    'the approved proposal reaches the live harness path'
assert_eq '.claude/settings.json' "$(git -C "$repo" diff --cached --name-only)" \
    'the approved proposal is staged for the supported commit helper'

commit_out=$(cd "$repo" && "$commit_helper" --message 'fix: approved harness configuration' \
    --trailer 'Co-Authored-By: Codex <noreply@openai.com>' \
    --ledger "$ledger" --run-id issue-911-review --ledger-scope "$scope" \
    -- .claude/settings.json)
assert_contains "$commit_out" 'committed ' \
    'the agent commits an approved proposal without handing Git commands to the operator'
assert_contains "$(git -C "$repo" log -1 --format=%B)" \
    'Authorized-By-Ledger: issue-911-review authorize:protected-commit' \
    'the resulting commit records the reused concrete authorization'

changed_patch="$tmp/settings-changed.patch"
cat >"$changed_patch" <<'EOF'
diff --git a/.claude/settings.json b/.claude/settings.json
--- a/.claude/settings.json
+++ b/.claude/settings.json
@@ -1 +1 @@
-{"mode":"approved"}
+{"mode":"changed-again"}
EOF
changed_rc=0
changed_out=$(cd "$repo" && "$helper" apply --patch "$changed_patch" --ledger "$ledger" \
    --run-id issue-911-review --ledger-scope "$scope" 2>&1) || changed_rc=$?
assert_eq '3' "$changed_rc" 'changed proposal bytes cannot inherit the earlier grant'
assert_contains "$changed_out" 'scope does not match the concrete proposal' \
    'the changed proposal refusal names the stale scope'
assert_eq '{"mode":"approved"}' "$(cat "$repo/.claude/settings.json")" \
    'a stale grant cannot write changed harness bytes'

ordinary_patch="$tmp/ordinary.patch"
cat >"$ordinary_patch" <<'EOF'
diff --git a/seed.txt b/seed.txt
--- a/seed.txt
+++ b/seed.txt
@@ -1 +1 @@
-seed
+changed
EOF
ordinary_rc=0
ordinary_out=$(cd "$repo" && "$helper" scope --patch "$ordinary_patch" 2>&1) || ordinary_rc=$?
assert_eq '2' "$ordinary_rc" 'proposal helper refuses an ordinary source patch'
assert_contains "$ordinary_out" 'not preparation-restricted' \
    'the ordinary-path refusal keeps the helper scoped to the true boundary'

git_metadata_patch="$tmp/git-config.patch"
cat >"$git_metadata_patch" <<'EOF'
diff --git a/.git/config b/.git/config
--- a/.git/config
+++ b/.git/config
@@ -1 +1 @@
-old
+new
EOF
git_metadata_rc=0
git_metadata_out=$(cd "$repo" && "$helper" scope --patch "$git_metadata_patch" 2>&1) || git_metadata_rc=$?
assert_eq '1' "$git_metadata_rc" 'untrackable Git metadata has an explicit runtime restriction'
assert_contains "$git_metadata_out" 'failure-v1 class=runtime-restriction' \
    'the Git-metadata boundary is machine-readable'
assert_contains "$git_metadata_out" 'cannot be represented by a staged-tree grant' \
    'the Git-metadata refusal explains why the proposal cannot enter the commit path'

finish
