#!/usr/bin/env bash
# Suite: bootstrap-repo.sh generation, idempotency, and partial-write refusal.
set -uo pipefail

TEST_NAME='bootstrap-repo'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
bs_sh="$skills/.shared/scripts/bootstrap-repo.sh"
rc_sh="$skills/.shared/scripts/repo-config.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# A routing stub: picks a fixture based on the gh subcommand it was given.
mkdir -p "$tmp/stub"
cat > "$tmp/stub/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "\$*" >> "$tmp/gh.log"
case "\$*" in
  *"api graphql"*)        cat "$here/fixtures/gh-linked-projects.json" ;;
  *"project field-list"*) cat "$here/fixtures/gh-field-list.json" ;;
  *"project list"*)       cat "$here/fixtures/gh-project-list.json" ;;
  *"repo view"*)          printf '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}\n' ;;
  *"auth status"*)        printf 'Logged in\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub/gh"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" remote add origin https://github.com/example-org/example-repo.git
    printf '%s' "$dir"
}

run_bs() { PATH="$tmp/stub:$PATH" "$bs_sh" "$@"; }

# --- dry run writes nothing -----------------------------------------------
repo=$(make_repo)
out=$(run_bs --repo-root "$repo" --project 7 --dry-run 2>&1)
assert_contains "$out" 'AGENT_REPO_SLUG=example-org/example-repo' 'dry run previews config.env'
assert_contains "$out" 'PVTSSF_lADOAexampleB' 'dry run previews the Status field id'
assert_eq 'no' "$([[ -e $repo/.agent/config.env ]] && echo yes || echo no)" \
    'dry run creates no config.env'
assert_eq 'no' "$([[ -e $repo/.agent/board.json ]] && echo yes || echo no)" \
    'dry run creates no board.json'

# --- real run --------------------------------------------------------------
repo=$(make_repo)
assert_rc 0 'bootstrap succeeds' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 7
assert_eq 'yes' "$([[ -f $repo/.agent/config.env ]] && echo yes || echo no)" 'writes config.env'
assert_eq 'yes' "$([[ -f $repo/.agent/board.json ]] && echo yes || echo no)" 'writes board.json'

board=$(cat "$repo/.agent/board.json")
assert_eq '1' "$(jq -r '.schemaVersion' <<< "$board")" 'board.json declares schemaVersion 1'
assert_eq 'PVT_kwDOAexample1' "$(jq -r '.project.id' <<< "$board")" 'records the project node id'
assert_eq 'PVTSSF_lADOAexampleB' "$(jq -r '.statusField.id' <<< "$board")" 'records the Status field id'
assert_eq 'opt-ready' "$(jq -r '.statusField.options.Ready' <<< "$board")" 'maps Ready to its option id'
assert_eq 'opt-inprog' "$(jq -r '.statusField.options["In progress"]' <<< "$board")" \
    'maps a spaced option name'
assert_contains "$(jq -r '.fingerprint' <<< "$board")" 'sha256:' 'records a fingerprint'

# The generated config must survive its own resolver with zero warnings.
warnings=$("$rc_sh" --repo-root "$repo" --list 2>&1 > /dev/null)
assert_eq '' "$warnings" 'generated config.env produces no resolver warnings'
listed=$("$rc_sh" --repo-root "$repo" --list 2> /dev/null)
assert_contains "$listed" 'AGENT_PROJECT_NUMBER=7' 'generated config carries the project number'
assert_contains "$listed" 'AGENT_STATUS_VOCAB=Backlog,Ready,In progress,In review,Done' \
    'status vocabulary comes from the discovered option order'
assert_contains "$(cat "$repo/.agent/config.env")" 'AGENT_ONBOARDED_BY=agentkit/0.1.0' \
    'generated config records the installed generator version'

# --- a repo linked to exactly one board needs no --project -----------------
# An org can own dozens of boards while a repo is linked to one. Asking the
# repository, not the owner, is what keeps bootstrap zero-prompt on most repos.
repo=$(make_repo)
: > "$tmp/gh.log"
assert_rc 0 'a repo linked to one board bootstraps without --project' -- env \
    PATH="$tmp/stub:$PATH" "$bs_sh" --repo-root "$repo"
assert_contains "$(cat "$repo/.agent/config.env")" 'AGENT_PROJECT_NUMBER=7' \
    'and picks the linked board'
assert_not_contains "$(cat "$tmp/gh.log")" 'project list' \
    'without falling back to the owner-wide board list'

# --- not linked to any board falls back to the owner list ------------------
repo=$(make_repo)
mkdir -p "$tmp/stub3"
cat > "$tmp/stub3/gh" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/gh3.log"
case "\$*" in
  *"api graphql"*)        printf '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}\n' ;;
  *"project field-list"*) cat "$here/fixtures/gh-field-list.json" ;;
  *"project list"*)       cat "$here/fixtures/gh-project-list.json" ;;
  *"repo view"*)          printf '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub3/gh"
: > "$tmp/gh3.log"
assert_rc 0 'an unlinked repo still bootstraps via the owner board list' -- env \
    PATH="$tmp/stub3:$PATH" "$bs_sh" --repo-root "$repo" --project 7
assert_contains "$(cat "$tmp/gh3.log")" 'project list' 'by falling back to gh project list'

# --- refuses to clobber ----------------------------------------------------
assert_rc 1 'refuses to overwrite without --force' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 7
assert_rc 0 '--force overwrites' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 7 --force

# --- idempotency -----------------------------------------------------------
before=$(jq -S 'del(.generatedAt)' < "$repo/.agent/board.json")
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
after=$(jq -S 'del(.generatedAt)' < "$repo/.agent/board.json")
assert_eq "$before" "$after" 'a second run produces identical content'

# --- no secrets ever leak --------------------------------------------------
config=$(cat "$repo/.agent/config.env")
for bad in GH_TOKEN TOKEN PROXY CA_BUNDLE PASSWORD; do
    assert_not_contains "$config" "$bad" "generated config.env has no $bad"
done

# --- environment-blocked ---------------------------------------------------
repo=$(make_repo)
mkdir -p "$tmp/emptybin"
assert_rc 3 'no gh on PATH exits 3' -- env PATH="$tmp/emptybin" /bin/bash "$bs_sh" --repo-root "$repo" --project 7

# --- partial discovery writes nothing --------------------------------------
repo=$(make_repo)
mkdir -p "$tmp/stub2"
cat > "$tmp/stub2/gh" << EOF
#!/usr/bin/env bash
case "\$*" in
  *"project list"*) cat "$here/fixtures/gh-project-list.json" ;;
  *"repo view"*)    printf '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}\n' ;;
  *"auth status"*)  printf 'Logged in\n' ;;
  *) printf '{"fields":[]}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub2/gh"
assert_rc 1 'a board with no Status field fails' -- env PATH="$tmp/stub2:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 7
assert_eq 'no' "$([[ -e $repo/.agent/board.json ]] && echo yes || echo no)" \
    'failed discovery writes no partial board.json'
assert_eq 'no' "$([[ -e $repo/.agent/config.env ]] && echo yes || echo no)" \
    'failed discovery writes no partial config.env'

# --- ambiguous board is refused, never guessed -----------------------------
repo=$(make_repo)
assert_rc 1 'an unknown project number is refused' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 999

# --- usage -----------------------------------------------------------------
assert_rc 2 'unknown flag is a usage error' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --bogus

# --- command suggestions ---------------------------------------------------
# The verify surface cannot be inferred: a repo may have a bespoke dispatcher
# AND twenty npm scripts. Surface both, decide neither.
repo=$(make_repo)
mkdir -p "$repo/tools"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
printf '{"scripts":{"test":"jest","lint":"eslint .","build":"tsc"}}\n' > "$repo/package.json"
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
config=$(cat "$repo/.agent/config.env")
assert_contains "$config" '# AGENT_CMD_' 'suggests commands as commented lines'
assert_contains "$config" 'AGENT_CMD_VERIFY=tools/verify' 'surfaces a bespoke dispatcher as a declaration'
assert_contains "$config" '# proposal-component|.|node|package.json' \
    'records the detected component in the proposal inventory'
assert_contains "$config" '# proposal-command|AGENT_CMD_VERIFY|tools/verify|present|' \
    'records proposal binary availability without declaring it'
# The old detection hardcoded `npm run <script>` whatever the lockfile said, and
# `npm lint` is not even a command. Suggestions are now ready-to-uncomment
# declarations carrying the runner the repository actually locked.
assert_contains "$config" 'AGENT_CMD_TEST=' 'surfaces package.json scripts as declarations'
assert_not_contains "$config" $'\nAGENT_CMD_' 'never uncomments a suggestion'
# The line above needs a preceding newline to match, so it cannot see a
# declaration sitting on the file's very first line; this pins the proposed
# key itself as inactive regardless of where it lands.
assert_eq '0' "$(grep -c '^AGENT_CMD_VERIFY=' "$repo/.agent/config.env" || true)" \
    'records the verify proposal without activating the declaration'
warnings=$("$rc_sh" --repo-root "$repo" --list 2>&1 > /dev/null)
assert_eq '' "$warnings" 'suggestions produce no resolver warnings'

# --- a Makefile repo -------------------------------------------------------
repo=$(make_repo)
printf 'test:\n\techo hi\nlint:\n\techo hi\n' > "$repo/Makefile"
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
assert_contains "$(cat "$repo/.agent/config.env")" 'AGENT_CMD_TEST=make test' 'surfaces Makefile targets'

# --- a repo with no detectable verify surface ------------------------------
repo=$(make_repo)
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
warnings=$("$rc_sh" --repo-root "$repo" --list 2>&1 > /dev/null)
assert_eq '' "$warnings" 'a repo with nothing detectable still generates a clean config'

# --- ignore rules are WRITTEN, and they work -------------------------------
# This printed advice and wrote nothing, so a bootstrapped repository could reach
# steady state with no rule at all -- which is what happened in the first repo it
# was used on. And the advice was too narrow: .agent/cache/ left env-contract.txt
# stageable, and that file carries the local home path, the CA bundle location,
# and the authenticated account name.
repo=$(make_repo)
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
ignore=$(cat "$repo/.gitignore" 2> /dev/null || true)
assert_contains "$ignore" '.agent/*' 'bootstrap writes the ignore rules'
assert_contains "$ignore" '!.agent/config.env' 'and exempts the declared config'
assert_contains "$ignore" '!.agent/board.json' 'and the declared board cache'

# The claim is about git's behaviour, not about a pattern's text, so it is
# asserted by actually staging.
mkdir -p "$repo/.agent/cache" "$repo/.agent/logs"
printf 'account=someone home=/home/someone\n' > "$repo/.agent/env-contract.txt"
printf 'x\n' > "$repo/.agent/cache/stamp-verify"
printf 'x\n' > "$repo/.agent/logs/run.log"
git -C "$repo" add -A > /dev/null 2>&1
staged=$(git -C "$repo" diff --cached --name-only -- .agent | sort | tr '\n' ' ')
assert_eq '.agent/board.json .agent/config.env ' "$staged" \
    'a blanket add stages the two declared files and nothing else'
assert_not_contains "$staged" 'env-contract' 'the probe output never reaches the index'

# Re-running must not duplicate the block: bootstrap --force is the documented
# migration for repositories that predate this.
before=$(grep -c 'agent/\*' "$repo/.gitignore")
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
assert_eq "$before" "$(grep -c 'agent/\*' "$repo/.gitignore")" 're-running does not duplicate the rules'

# An existing .gitignore must survive intact.
repo=$(make_repo)
printf 'node_modules/\n*.log\n' > "$repo/.gitignore"
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
assert_contains "$(cat "$repo/.gitignore")" 'node_modules/' 'existing ignore entries are preserved'

# Already-tracked working state is REPORTED, not silently removed: untracking is
# a history decision and not this script's to make.
repo=$(make_repo)
mkdir -p "$repo/.agent"
printf 'account=someone\n' > "$repo/.agent/env-contract.txt"
git -C "$repo" add -f .agent/env-contract.txt > /dev/null 2>&1
warn=$(run_bs --repo-root "$repo" --project 7 --force 2>&1 > /dev/null || true)
assert_contains "$warn" 'env-contract.txt' 'already-tracked working state is reported'
assert_contains "$warn" 'git rm --cached' 'with the command that fixes it'

# --- --force must not discard declared work --------------------------------
# Everything the generator writes is rediscoverable from the forge. The verify
# commands and label classifications are not: they are judgement work, and on a
# real repository confirming them meant running the full test suite. Regenerating
# over them destroyed all of it, and the agent that hit it happened to notice.
repo=$(make_repo config-good.env)
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
cat >> "$repo/.agent/config.env" <<'CFG'
AGENT_CMD_TEST=true
AGENT_LABEL_TYPES=bug,enhancement
AGENT_PROTECTED_PATHS=migrations/
CFG
out=$(run_bs --repo-root "$repo" --project 7 --force 2>&1)
after=$(cat "$repo/.agent/config.env")
assert_contains "$after" 'AGENT_CMD_TEST=true' 'a declared command survives --force'
assert_contains "$after" 'AGENT_LABEL_TYPES=bug,enhancement' 'and a label classification'
assert_contains "$after" 'AGENT_PROTECTED_PATHS=migrations/' 'and declared protected paths'
assert_contains "$out" 'carried forward' 'and the run says what it preserved'

declared_before=$(grep -E '^AGENT_(CMD_TEST|LABEL_TYPES|PROTECTED_PATHS)=' "$repo/.agent/config.env")
assert_rc 0 'refresh is an explicit force refresh' -- run_bs --repo-root "$repo" --project 7 --refresh
declared_after=$(grep -E '^AGENT_(CMD_TEST|LABEL_TYPES|PROTECTED_PATHS)=' "$repo/.agent/config.env")
assert_eq "$declared_before" "$declared_after" 'refresh preserves carried declarations exactly'
assert_eq '' "$(grep -E '^AGENT_CMD_LINT_SHELL=' "$repo/.agent/config.env" || true)" \
    'refresh leaves an unrelated proposal commented'

# Discovered facts are still refreshed rather than duplicated -- carrying
# everything forward blindly would pin a stale slug or board number for ever.
assert_eq '1' "$(grep -c '^AGENT_REPO_SLUG=' "$repo/.agent/config.env")" \
    'a regenerated key appears exactly once'
assert_eq '1' "$(grep -c '^AGENT_CMD_TEST=' "$repo/.agent/config.env")" \
    'and a carried key is not duplicated either'

# Still parses after the merge.
warnings=$("$rc_sh" --repo-root "$repo" --list 2>&1 > /dev/null)
assert_eq '' "$warnings" 'the merged config parses cleanly'

# A carried relative executable belongs to the real checkout, not bootstrap's
# temporary staging directory. Validation must use the explicit config path
# override while resolving candidates against the target repository root.
repo=$(make_repo)
mkdir -p "$repo/tools"
printf '#!/bin/sh\nexit 0\n' > "$repo/tools/verify"
chmod +x "$repo/tools/verify"
run_bs --repo-root "$repo" --project 7 --force > /dev/null 2>&1
printf 'AGENT_CMD_TEST=tools/verify\n' >> "$repo/.agent/config.env"
assert_rc 0 'bootstrap refresh validates carried commands against the real root' -- \
    env PATH="$tmp/stub:$PATH" "$bs_sh" --repo-root "$repo" --project 7 --force
assert_contains "$(cat "$repo/.agent/config.env")" 'AGENT_CMD_TEST=tools/verify' \
    'refresh keeps the carried executable declaration'

# Reset is the explicit archive-and-regenerate path; ordinary refresh must not
# discard declaration work or create an archive.
before_reset=$(find "$repo/.agent" -mindepth 2 -maxdepth 2 -type f -path '*/archive/*' | wc -l)
assert_rc 0 'reset archives before regenerating' -- env PATH="$tmp/stub:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 7 --reset
after_reset=$(find "$repo/.agent" -mindepth 2 -maxdepth 2 -type f -path '*/archive/*' | wc -l)
assert_eq '0' "$before_reset" 'refresh has no archive side effect'
assert_eq '2' "$after_reset" 'reset archives config and board'
assert_not_contains "$(cat "$repo/.agent/config.env")" 'AGENT_CMD_TEST=tools/verify' \
    'reset does not carry declarations out of the archive'


# --- the allowlist must WORK, not merely be present -------------------------
# A repository carried the intended allowlist in .gitignore and a broader
# `.agent/` in .git/info/exclude. Git does not descend into an excluded
# DIRECTORY, so the "!" negations were never reached: the rule was textually
# present and had no effect. This script reported "ignore rules already
# present" and onboarding failed one tool later, at git add, with a message
# naming only the directory.
repo=$(make_repo)
printf '.agent/\n' >> "$repo/.git/info/exclude"
out=$(run_bs --repo-root "$repo" --project 7 2>&1)
assert_contains "$out" 'allowlist has no effect' 'a defeated allowlist is reported, not assumed to work'
assert_contains "$out" '.git/info/exclude' 'and the file carrying the defeating rule is named'
assert_contains "$out" '.agent/ -> .agent/*' 'and the narrowing that fixes it is given'
assert_eq 'no' "$([[ -e $repo/.agent/config.env ]] && echo yes || echo no)" \
    'a dead ignore failure installs no config.env before remediation'
assert_eq 'no' "$([[ -e $repo/.agent/board.json ]] && echo yes || echo no)" \
    'a dead ignore failure installs no board.json before remediation'
assert_eq 'no' "$([[ -e $repo/.gitignore ]] && echo yes || echo no)" \
    'a dead ignore failure does not print partial success or create .gitignore'
# The named repair is directly rerunnable: once the blocking rule is narrowed,
# the same bootstrap command completes without --force.
sed -i -E 's|^[[:space:]]*\.agent/[[:space:]]*$|.agent/*|' "$repo/.git/info/exclude"
assert_rc 0 'the remediation permits a direct bootstrap rerun' -- env \
    PATH="$tmp/stub:$PATH" "$bs_sh" --repo-root "$repo" --project 7

# The same repository once the broader rule is narrowed: silence.
repo=$(make_repo)
printf '.agent/*\n' >> "$repo/.git/info/exclude"
out=$(run_bs --repo-root "$repo" --project 7 2>&1)
assert_not_contains "$out" 'allowlist has no effect' 'a working allowlist produces no warning'

# And with no competing rule at all.
repo=$(make_repo)
out=$(run_bs --repo-root "$repo" --project 7 2>&1)
assert_not_contains "$out" 'allowlist has no effect' 'nor does the ordinary case'


# --- --repo-root controls discovery, not just the write target --------------
# gh infers the repository from wherever it is invoked. Running from repository
# A with `--repo-root /path/to/B` therefore wrote A's slug, base branch and
# Project metadata into B -- into a committed file, silently naming the wrong
# repository. Caught by external review.
mkdir -p "$tmp/stubcwd"
cat > "$tmp/stubcwd/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
# The routing stub, except that \`repo view\` answers for the directory it is
# invoked in -- which is what the real gh does, and the whole point here.
here=\$(basename -- "\$PWD")
case "\$*" in
  *"repo view"*)          printf '{"nameWithOwner":"example-org/%s","defaultBranchRef":{"name":"main"}}\n' "\$here" ;;
  *"api graphql"*)        cat "$here/fixtures/gh-linked-projects.json" ;;
  *"project field-list"*) cat "$here/fixtures/gh-field-list.json" ;;
  *"project list"*)       cat "$here/fixtures/gh-project-list.json" ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stubcwd/gh"

repo_a=$(mktemp -d "$tmp/aaa.XXXXXX"); git -C "$repo_a" init -q
repo_b=$(mktemp -d "$tmp/bbb.XXXXXX"); git -C "$repo_b" init -q
(cd "$repo_a" && PATH="$tmp/stubcwd:$PATH" "$bs_sh" --repo-root "$repo_b" --project 7 > /dev/null 2>&1)
written=$(grep '^AGENT_REPO_SLUG=' "$repo_b/.agent/config.env" 2> /dev/null || printf 'none')
assert_contains "$written" "$(basename -- "$repo_b")" \
    'the slug written into B describes B, not the directory the command ran from'
assert_not_contains "$written" "$(basename -- "$repo_a")" \
    'and never the invoking repository'

# --- an unlinked board is never adopted silently ----------------------------
# The single-candidate shortcut used to skip the only guard here. A personal
# repository whose owner had exactly one board took that board -- an unrelated
# homelab project holding someone else's in-flight issue -- and would have
# written its ids into a committed board.json, after which the next lifecycle
# move would have mutated it. The session that hit this noticed only because the
# columns happened to be wrong.
mkdir -p "$tmp/stub-unlinked"
cat > "$tmp/stub-unlinked/gh" << EOF
#!/usr/bin/env bash
set -uo pipefail
case "\$*" in
  *"api graphql"*)        printf '{"data":{"repository":{"projectsV2":{"nodes":[]}}}}\n' ;;
  *"project field-list"*) cat "$here/fixtures/gh-field-list.json" ;;
  *"project list"*)       printf '{"projects":[{"closed":false,"id":"PVT_other","number":2,"title":"Someone elses board"}],"totalCount":1}\n' ;;
  *"repo view"*)          printf '{"nameWithOwner":"example-org/example-repo","defaultBranchRef":{"name":"main"}}\n' ;;
  *) printf '{}\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/stub-unlinked/gh"

repo=$(make_repo)
err=$(PATH="$tmp/stub-unlinked:$PATH" "$bs_sh" --repo-root "$repo" 2>&1 >/dev/null || true)
assert_contains "$err" 'refusing to adopt an unlinked board' \
    'a lone unlinked board is refused, not adopted'
assert_contains "$err" 'Someone elses board' 'and the candidate is named so the choice can be made'
assert_contains "$err" '--project N' 'and the way to accept it is spelled out'
assert_eq 'no' "$([[ -e $repo/.agent/board.json ]] && echo yes || echo no)" \
    'and nothing is written'

# Naming it explicitly is consent, and then it proceeds.
repo=$(make_repo)
assert_rc 0 'an explicitly named unlinked board is accepted' -- env PATH="$tmp/stub-unlinked:$PATH" \
    "$bs_sh" --repo-root "$repo" --project 2

# --- a board owned by someone else ------------------------------------------
# GitHub refuses to link an organization board to a personal repository at all,
# so for that pairing there is no link to find and the owner must be typed.
repo=$(make_repo)
out=$(PATH="$tmp/stub-unlinked:$PATH" "$bs_sh" --repo-root "$repo" --project 2 \
    --owner other-org --dry-run 2>&1)
assert_contains "$out" '"owner": "other-org"' \
    'board.json records the BOARD owner, not the repository owner'

# --- a refresh never erases the generator stamp ----------------------------
# AGENT_ONBOARDED_BY is generator-owned, so the carry-forward filter drops the
# previous value by design. When version discovery yields nothing there is no
# replacement to emit, and the provenance record -- the very thing drift
# detection reads -- would vanish. Reproduced by running a copy of the script
# from a tree where the plugin manifest does not resolve, which is what an
# install layout looks like.
stamp_repo=$(make_repo)
mkdir -p "$stamp_repo/.agent"
printf 'AGENT_REPO_SLUG=example-org/example-repo\nAGENT_ONBOARDED_BY=agentkit/0.0.9\n' \
    > "$stamp_repo/.agent/config.env"
orphan_dir=$(mktemp -d "$tmp/orphan.XXXXXX")/a/b/c
mkdir -p "$orphan_dir"
cp "$bs_sh" "$orphan_dir/bootstrap-repo.sh"
PATH="$tmp/stub:$PATH" "$orphan_dir/bootstrap-repo.sh" \
    --repo-root "$stamp_repo" --project 7 --refresh > /dev/null 2>&1 || true
assert_contains "$(cat "$stamp_repo/.agent/config.env")" 'AGENT_ONBOARDED_BY=agentkit/0.0.9' \
    'a refresh with no discoverable version keeps the previous generator stamp'

finish
