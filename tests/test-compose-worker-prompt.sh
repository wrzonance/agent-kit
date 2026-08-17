#!/usr/bin/env bash
# Suite: compose-worker-prompt.sh fills both worker templates from repository facts.
set -uo pipefail

TEST_NAME='compose-worker-prompt'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

compose="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

trust_line=$(grep -m1 -n 'shared_path=.*contract_reader' "$compose" | cut -d: -f1)
# shellcheck disable=SC2016
contract_read_pattern='grep -Eq.*\$contract'
contract_read_line=$(grep -m1 -n "$contract_read_pattern" "$compose" | cut -d: -f1)
assert_eq yes "$([[ -n $trust_line && -n $contract_read_line && trust_line -lt contract_read_line ]] && printf yes || printf no)" \
    'composer validates the contract before reading its content'
compose_source=$(<"$compose")
assert_contains "$compose_source" '--resolve test' \
    'composer asks agent-run for focus-command resolution'
assert_not_contains "$compose_source" 'runner_resolves' \
    'composer has no mirrored runner resolution function'
assert_not_contains "$compose_source" 'declared_runner_resolves' \
    'composer has no mirrored declared-runner resolution function'

make_repo() {
    local dir=$1 contract=$2
    mkdir -p "$dir/.agent"
    git -C "$dir" init -q
    printf '%s\n' \
        'AGENT_REPO_SLUG=example-org/example-repo' \
        'AGENT_BASE_BRANCH=develop' \
        'AGENT_CMD_VERIFY=tools/verify' \
        'AGENT_CMD_BACKEND_TEST=tools/backend-test' \
        'AGENT_CMD_TEST=tools/full-test' \
        'AGENT_CMD_SETUP=tools/setup' \
        'AGENT_CMD_INSTALL=tools/install' \
        'AGENT_CMD_SERVE=tools/serve' \
        'AGENT_CMD_DEV=tools/dev' \
        'AGENT_CMD_TEST_SETUP=tools/test-setup' \
        'AGENT_CMD_TEST_FOCUS=tools/focused-test --only %s' \
        > "$dir/.agent/config.env"
    printf '%s\n' "$contract" > "$dir/.agent/env-contract.txt"
    printf '%s\n' "SPEC-BYTES \$(must-stay-literal)" > "$dir/.agent/fenced-spec.txt"
    printf '%s\n' 'PRIOR-BYTES' > "$dir/.agent/fenced-prior-art.txt"
}

contract=$'skills= path='"$root"$'/agentkit/skills\nharness= name=codex trailer="Codex <noreply@openai.com>"'
repo="$tmp/repo with spaces"
make_repo "$repo" "$contract"

assert_rendered_guard_passes() {
    local rendered_prompt=$1 label=$2 guard_block
    guard_block=$(printf '%s\n' "$rendered_prompt" | awk '
        /^worker_model=/ { capture=1 }
        capture && /^worker_attribution=/ { exit }
        capture { print }
    ')
    assert_contains "$guard_block" "[ -n \"\$worker_model\" ]" \
        "$label keeps the non-empty worker-model guard"
    assert_not_contains "$guard_block" "[ \"\$worker_model\" != " \
        "$label drops the self-comparison guard"
    assert_rc 0 "$label rendered worker-model guard passes" -- bash -c "$guard_block"
}

chain_base=30c38b2c1fa35c6cecc5946aaa7c41e7c132885c
prompt=$(bash "$compose" --template issue-lead --worktree "$repo" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
    --worker-effort high --yolo --chain-base "$chain_base")

assert_contains "$prompt" 'Repo: example-org/example-repo' 'issue lead receives the configured repository slug'
assert_contains "$prompt" 'Worktree: '"$repo" 'issue lead receives the absolute worktree'
assert_contains "$prompt" 'Branch: feat/issue-136' 'issue lead receives the requested branch'
assert_contains "$prompt" 'Base: develop' 'issue lead receives the configured base branch'
assert_contains "$prompt" 'Worker effort: high' 'issue lead receives the requested worker effort'
expected_test_chmod="chmod +x -- \"\$worktree/tests/<name>.sh\""
expected_test_invocation="before invoking it as \"\$worktree/tests/<name>.sh\""
expected_test_handoff="handing it off for commit"
expected_test_mode_check="verify the mode is 755/100755"
expected_agent_run="'$root/agentkit/skills/.shared/scripts/agent-run.sh'"
shared_reference="\"\$shared/"
assert_contains "$prompt" "$expected_test_chmod" \
    'issue lead is told to set the executable bit on new shell tests'
assert_contains "$prompt" "$expected_test_invocation" \
    'issue lead invokes new shell tests from the assigned worktree'
assert_contains "$prompt" "$expected_test_handoff" \
    'issue lead sets the executable bit before handing new shell tests off for commit'
assert_contains "$prompt" "$expected_test_mode_check" \
    'issue lead verifies the executable mode before the first run'
assert_contains "$prompt" "SPEC-BYTES \$(must-stay-literal)" 'spec bytes stay literal'
assert_contains "$prompt" 'PRIOR-BYTES' 'prior-art bytes are injected'
assert_contains "$prompt" 'worker_model='"'"'gpt-5.6-luna' 'worker model is filled'
assert_contains "$prompt" 'AGENT_CMD_TEST_FOCUS' 'declared focus contract remains documented'
assert_not_contains "$prompt" '<PASTE' 'issue lead has no PASTE placeholder'
assert_not_contains "$prompt" '<WHEN' 'issue lead has no WHEN placeholder'
assert_not_contains "$prompt" '--cmd lint' 'undeclared lint command is not injected'
assert_not_contains "$prompt" '--cmd build' 'undeclared build command is not injected'
assert_not_contains "$prompt" '--cmd setup' 'operational setup command is not injected'
assert_not_contains "$prompt" '--cmd install' 'operational install command is not injected'
assert_not_contains "$prompt" '--cmd serve' 'long-running serve command is not injected'
assert_not_contains "$prompt" '--cmd dev' 'long-running dev command is not injected'
assert_not_contains "$prompt" '--cmd test-setup' 'operational test setup command is not injected'
assert_contains "$prompt" '--cmd verify --yolo --yolo-base ' 'verify receives chained yolo flags'
assert_contains "$prompt" '--cmd backend-test --yolo --yolo-base ' 'multi-word declaration becomes a dashed command name'
assert_contains "$prompt" '--cmd test --yolo --yolo-base ' 'test receives chained yolo flags'
assert_contains "$prompt" "--cmd test --only 'NAME[,NAME...]' --yolo --yolo-base $chain_base" \
    'focused test selector receives chained yolo flags'
assert_rendered_guard_passes "$prompt" 'issue-lead'

command_lines=$(printf '%s\n' "$prompt" | grep -E 'agent-run\.sh.*--cmd')
assert_contains "$command_lines" '--cmd verify' \
    'generated command scan finds actual agent-run --cmd lines'
assert_not_contains "$command_lines" "\$(" 'generated command lines have no command substitutions'
assert_not_contains "$command_lines" '--cmd test-focus' 'focused selector is not emitted as a normal command'
assert_not_contains "$command_lines" '[[' 'generated command lines have no Bash conditionals'
assert_not_contains "$command_lines" 'mapfile' 'generated command lines have no Bash-only mapfile'
assert_not_contains "$command_lines" '<<<' 'generated command lines have no Bash-only here-string'

output_file="$tmp/fix-batch.md"
assert_rc 0 'fix-batch can render to an output file' -- bash "$compose" \
    --template fix-batch --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high --output "$output_file"
fix_prompt=$(<"$output_file")
assert_contains "$fix_prompt" 'PR: 136' 'fix-batch receives the issue number'
assert_contains "$fix_prompt" 'Base: develop' 'fix-batch receives the configured base branch'
assert_contains "$fix_prompt" 'Worker effort: high' 'fix-batch receives the requested worker effort'
assert_contains "$fix_prompt" "$expected_test_chmod" \
    'fix-batch is told to set the executable bit on new shell tests'
assert_contains "$fix_prompt" "$expected_test_invocation" \
    'fix-batch invokes new shell tests from the assigned worktree'
assert_contains "$fix_prompt" "$expected_test_handoff" \
    'fix-batch sets the executable bit before handing new shell tests off for commit'
assert_contains "$fix_prompt" "$expected_test_mode_check" \
    'fix-batch verifies the executable mode before the first run'
assert_contains "$fix_prompt" '--cmd verify' 'fix-batch receives declared commands'
assert_contains "$fix_prompt" "$expected_agent_run" \
    'fix-batch command paths are fully resolved absolute paths'
assert_not_contains "$fix_prompt" "$shared_reference" \
    'fix-batch output does not leave helper paths for the worker to derive'
assert_not_contains "$fix_prompt" '<PASTE' 'fix-batch has no PASTE placeholder'
assert_not_contains "$fix_prompt" '<WHEN' 'fix-batch has no WHEN placeholder'
assert_rendered_guard_passes "$fix_prompt" 'fix-batch'

assert_rc 1 'an omitted worker model is rejected by the composer' -- bash "$compose" \
    --template issue-lead --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-effort high
assert_rc 1 'an empty worker model is rejected by the composer' -- bash "$compose" \
    --template issue-lead --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-model '' --worker-effort high

assert_rc 1 'a non-40-character chain base is rejected' -- bash "$compose" \
    --template issue-lead --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high --yolo --chain-base short

bad_repo="$tmp/bad-repo"
make_repo "$bad_repo" 'skills= path='"$root"$'/agentkit/skills\n<PASTE bad contract data>'
assert_rc 1 'surviving PASTE placeholders fail closed' -- bash "$compose" \
    --template issue-lead --worktree "$bad_repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high

missing_slug="$tmp/missing-slug"
make_repo "$missing_slug" "$contract"
sed -i '/^AGENT_REPO_SLUG=/d' "$missing_slug/.agent/config.env"
missing_slug_output=''
missing_slug_rc=0
missing_slug_output=$(bash "$compose" --template issue-lead --worktree "$missing_slug" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
    --worker-effort high 2>&1) || missing_slug_rc=$?
assert_eq 1 "$missing_slug_rc" 'missing repository slug fails closed'
assert_contains "$missing_slug_output" 'AGENT_REPO_SLUG' \
    'missing repository slug error names the unresolved fact'

missing_base="$tmp/missing-base"
make_repo "$missing_base" "$contract"
sed -i '/^AGENT_BASE_BRANCH=/d' "$missing_base/.agent/config.env"
missing_base_output=''
missing_base_rc=0
missing_base_output=$(bash "$compose" --template issue-lead --worktree "$missing_base" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
    --worker-effort high 2>&1) || missing_base_rc=$?
assert_eq 1 "$missing_base_rc" 'missing base branch fails closed'
assert_contains "$missing_base_output" 'AGENT_BASE_BRANCH' \
    'missing base branch error names the unresolved fact'

# The worker sources these two lines. With a worktree path containing spaces an
# unquoted value parses as an assignment followed by a stray command, so the
# rendered assignments must survive a real shell parse -- asserting on the text
# alone would pass for a value that no shell could read back.
assignment_line=$(printf '%s\n' "$prompt" | grep -m1 '^worktree=')
shared_line=$(printf '%s\n' "$prompt" | grep -m1 '^shared=')
assert_eq "$repo" "$(bash -c "$assignment_line"'; printf %s "$worktree"')" \
    'the rendered worktree assignment reads back as the exact path in bash'
# No bash fallback here. Falling back on a zsh *failure* would let a zsh parse
# error pass as success, which is the one thing this case exists to catch. Zsh
# being absent is reported as an explicit skip instead of being papered over.
if command -v zsh >/dev/null 2>&1; then
    assert_eq "$repo" "$(zsh -c "$assignment_line"'; printf %s "$worktree"')" \
        'the rendered worktree assignment reads back as the exact path in zsh'
else
    printf '  skip zsh assignment parse (zsh is not installed)\n'
fi
assert_eq "$root/agentkit/skills/.shared/scripts" \
    "$(bash -c "$shared_line"'; printf %s "$shared"')" \
    'the rendered shared assignment reads back as the exact path'
assert_contains "$prompt" "$expected_agent_run" \
    'issue-lead command paths are fully resolved absolute paths'
assert_not_contains "$prompt" "$shared_reference" \
    'issue-lead output does not leave helper paths for the worker to derive'

# The shared path comes from the contract, not the worktree, so it needs its own
# spaced case -- the assertion above runs against a repo path with no spaces and
# would pass unquoted.
spaced_skills="$tmp/skills dir"
spaced_contract=$'skills= path='"$spaced_skills"$'\nharness= name=codex trailer="Codex <noreply@openai.com>"'
spaced_repo="$tmp/spaced-contract"
make_repo "$spaced_repo" "$spaced_contract"
spaced_prompt=$(bash "$compose" --template issue-lead --worktree "$spaced_repo" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna --worker-effort high)
spaced_shared_line=$(printf '%s\n' "$spaced_prompt" | grep -m1 '^shared=')
assert_eq "$spaced_skills/.shared/scripts" \
    "$(bash -c "$spaced_shared_line"'; printf %s "$shared"')" \
    'a shared path containing spaces reads back intact'

# A trusted skills path may itself contain the placeholder marker. Replacement
# must consume the marker in the template once, rather than rescanning the
# replacement and looping forever. Keep this invocation bounded so the old
# implementation fails red without hanging the suite.
literal_shared_skills="$tmp/skills-\$shared"
literal_shared_contract=$'skills= path='"$literal_shared_skills"$'\nharness= name=codex trailer="Codex <noreply@openai.com>"'
literal_shared_repo="$tmp/literal-shared-contract"
make_repo "$literal_shared_repo" "$literal_shared_contract"
literal_shared_prompt=''
literal_shared_rc=0
literal_shared_prompt=$(timeout 3 bash "$compose" --template issue-lead \
    --worktree "$literal_shared_repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high 2>&1) || literal_shared_rc=$?
assert_eq 0 "$literal_shared_rc" \
    "a literal \$shared marker in the trusted skills path does not loop"
literal_shared_command=$(printf '%s\n' "$literal_shared_prompt" |
    grep -E -m1 '^.*agent-run\.sh.*--cmd test')
assert_contains "$literal_shared_command" 'agent-run.sh' \
    "literal \$shared scan finds an emitted helper command"
literal_shared_expected="'$literal_shared_skills/.shared/scripts/agent-run.sh'"
assert_contains "$literal_shared_command" "$literal_shared_expected" \
    "literal \$shared bytes remain in a shell-safe emitted helper path"

# Helper paths are emitted as commands executed by the worker. A trusted path
# containing shell metacharacters must be one shell word in both normal and
# focused command lines, preserving spaces, $, backticks, quotes, and slashes.
metachar_skills="$tmp/skills "
metachar_skills+='$'
metachar_skills+='`'
metachar_skills+='&'
metachar_skills+='"'
metachar_skills+="'"
metachar_skills+=$'\\'
metachar_skills+=' dir'
metachar_contract=$'skills= path='"$metachar_skills"$'\nharness= name=codex trailer="Codex <noreply@openai.com>"'
metachar_repo="$tmp/metachar-contract"
make_repo "$metachar_repo" "$metachar_contract"
metachar_prompt=$(bash "$compose" --template issue-lead --worktree "$metachar_repo" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna --worker-effort high)
metachar_reference_line=$(printf '%s\n' "$metachar_prompt" |
    grep -F -m1 "$metachar_skills/.shared/scripts/contract-read.sh")
assert_contains "$metachar_reference_line" 'contract-read.sh' \
    'metacharacter scan finds the resolved reference command'
assert_contains "$metachar_reference_line" "$metachar_skills/.shared/scripts/contract-read.sh" \
    'metacharacters survive non-rescanning placeholder replacement'
parse_helper_path() {
    local command_line=$1
    bash -c 'set -- '"$command_line"'; printf %s "$1"'
}
metachar_command=$(printf '%s\n' "$metachar_prompt" |
    grep -E -m1 '^.*agent-run\.sh.*--cmd test ')
metachar_focus_command=$(printf '%s\n' "$metachar_prompt" |
    grep -E -m1 '^.*agent-run\.sh.*--cmd test --only ')
assert_contains "$metachar_command" 'agent-run.sh' \
    'metacharacter scan finds an emitted normal helper command'
assert_contains "$metachar_focus_command" 'agent-run.sh' \
    'metacharacter scan finds an emitted focused helper command'
assert_eq "$metachar_skills/.shared/scripts/agent-run.sh" \
    "$(parse_helper_path "$metachar_command")" \
    'metacharacter helper path parses as one normal command word'
assert_eq "$metachar_skills/.shared/scripts/agent-run.sh" \
    "$(parse_helper_path "$metachar_focus_command")" \
    'metacharacter helper path parses as one focused command word'

# AGENT_CMD_TEST_FOCUS alone cannot resolve --cmd test: agent-run.sh needs either
# AGENT_CMD_TEST or a declared runner, and with neither the emitted focused
# selector would fail in the worker's hands.
focus_only="$tmp/focus-only"
make_repo "$focus_only" "$contract"
sed -i '/^AGENT_CMD_TEST=/d' "$focus_only/.agent/config.env"
focus_only_output=''
focus_only_rc=0
focus_only_output=$(bash "$compose" --template issue-lead --worktree "$focus_only" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
    --worker-effort high 2>&1) || focus_only_rc=$?
assert_eq 1 "$focus_only_rc" 'a declared focus with no resolvable test command fails closed'
assert_contains "$focus_only_output" 'AGENT_CMD_TEST_FOCUS' \
    'the refusal names the focus declaration'

# A declared runner satisfies --cmd test on its own -- but only a real one.
# agent-run.sh requires the resolved runner to be EXECUTABLE, so the composer
# applies the same test; a declaration naming a missing or non-executable path
# is not a runner and must not unlock the focused selector.
compose_focus_repo() {
    local dir=$1
    make_repo "$dir" "$contract"
    sed -i '/^AGENT_CMD_TEST=/d' "$dir/.agent/config.env"
}
run_focus_compose() {
    local dir=$1 rc=0
    bash "$compose" --template issue-lead --worktree "$dir" \
        --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
        --worker-effort high >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

focus_runner="$tmp/focus-runner"
compose_focus_repo "$focus_runner"
mkdir -p "$focus_runner/tools"
printf '#!/usr/bin/env bash\n' > "$focus_runner/tools/run"
chmod +x "$focus_runner/tools/run"
printf 'tools/run\n' > "$focus_runner/.agent/runner"
assert_eq 0 "$(run_focus_compose "$focus_runner")" \
    'an executable .agent/runner satisfies the focus selector without AGENT_CMD_TEST'

focus_missing_runner="$tmp/focus-missing-runner"
compose_focus_repo "$focus_missing_runner"
printf 'tools/absent\n' > "$focus_missing_runner/.agent/runner"
assert_eq 1 "$(run_focus_compose "$focus_missing_runner")" \
    'an .agent/runner naming a missing path does not satisfy the focus selector'

focus_nonexec_runner="$tmp/focus-nonexec-runner"
compose_focus_repo "$focus_nonexec_runner"
mkdir -p "$focus_nonexec_runner/tools"
printf '#!/usr/bin/env bash\n' > "$focus_nonexec_runner/tools/run"
chmod -x "$focus_nonexec_runner/tools/run"
printf 'tools/run\n' > "$focus_nonexec_runner/.agent/runner"
assert_eq 1 "$(run_focus_compose "$focus_nonexec_runner")" \
    'an .agent/runner naming a non-executable path does not satisfy the focus selector'

focus_nonexec_env="$tmp/focus-nonexec-env"
compose_focus_repo "$focus_nonexec_env"
mkdir -p "$focus_nonexec_env/tools"
printf '#!/usr/bin/env bash\n' > "$focus_nonexec_env/tools/run"
chmod -x "$focus_nonexec_env/tools/run"
nonexec_env_rc=0
AGENT_REPO_RUNNER="$focus_nonexec_env/tools/run" bash "$compose" --template issue-lead \
    --worktree "$focus_nonexec_env" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high >/dev/null 2>&1 || nonexec_env_rc=$?
assert_eq 1 "$nonexec_env_rc" \
    'a non-executable AGENT_REPO_RUNNER does not satisfy the focus selector'

# agent-run.sh uses an ENVIRONMENT AGENT_REPO_RUNNER verbatim and never resolves
# a relative one against the repository root, so what it names depends on that
# process's cwd. Resolving it against the worktree here would accept a runner
# agent-run.sh could reject -- even with $worktree/tools/run executable.
focus_rel_env="$tmp/focus-rel-env"
compose_focus_repo "$focus_rel_env"
mkdir -p "$focus_rel_env/tools"
printf '#!/usr/bin/env bash\n' > "$focus_rel_env/tools/run"
chmod +x "$focus_rel_env/tools/run"
rel_env_rc=0
AGENT_REPO_RUNNER='tools/run' bash "$compose" --template issue-lead \
    --worktree "$focus_rel_env" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high >/dev/null 2>&1 || rel_env_rc=$?
assert_eq 1 "$rel_env_rc" \
    'a relative AGENT_REPO_RUNNER does not satisfy the focus selector even when the worktree copy is executable'

# An unusable environment runner does not end the search: agent-run.sh's
# resolve_runner falls through to .agent/runner, so a repository whose test
# command does resolve at runtime must not be rejected at compose time.
make_runner_fallback_repo() {
    local dir=$1
    compose_focus_repo "$dir"
    mkdir -p "$dir/tools"
    printf '#!/usr/bin/env bash\n' > "$dir/tools/fallback"
    chmod +x "$dir/tools/fallback"
    printf 'tools/fallback\n' > "$dir/.agent/runner"
}

rel_env_fallback="$tmp/rel-env-fallback"
make_runner_fallback_repo "$rel_env_fallback"
rel_env_fallback_rc=0
AGENT_REPO_RUNNER='tools/run' bash "$compose" --template issue-lead \
    --worktree "$rel_env_fallback" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high >/dev/null 2>&1 || rel_env_fallback_rc=$?
assert_eq 0 "$rel_env_fallback_rc" \
    'a relative AGENT_REPO_RUNNER falls through to an executable .agent/runner'

nonexec_env_fallback="$tmp/nonexec-env-fallback"
make_runner_fallback_repo "$nonexec_env_fallback"
printf '#!/usr/bin/env bash\n' > "$nonexec_env_fallback/tools/absent-exec"
chmod -x "$nonexec_env_fallback/tools/absent-exec"
nonexec_env_fallback_rc=0
AGENT_REPO_RUNNER="$nonexec_env_fallback/tools/absent-exec" bash "$compose" --template issue-lead \
    --worktree "$nonexec_env_fallback" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high >/dev/null 2>&1 || nonexec_env_fallback_rc=$?
assert_eq 0 "$nonexec_env_fallback_rc" \
    'a non-executable AGENT_REPO_RUNNER falls through to an executable .agent/runner'

finish
