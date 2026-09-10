#!/usr/bin/env bash
# Public command/declaration boundaries for paired formatting and cargo summaries.
set -uo pipefail
TEST_NAME=agent-run-format-summary
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
run="$root/agentkit/skills/.shared/scripts/agent-run.sh"
detect="$root/agentkit/skills/.shared/scripts/detect-toolchains.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

for kind in rust dotnet node python; do
    repo="$tmp/$kind"
    mkdir -p "$repo"
    case $kind in
        rust) touch "$repo/Cargo.toml"; expected='cargo fmt' ;;
        dotnet) touch "$repo/App.csproj"; expected='dotnet format' ;;
        node)
            printf '%s\n' '{"scripts":{"format:check":"prettier --check src","format":"prettier --write src"}}' > "$repo/package.json"
            expected='npm run format' ;;
        python)
            printf '[tool.ruff]\n' > "$repo/pyproject.toml"
            mkdir -p "$repo/.venv/bin"
            touch "$repo/.venv/bin/ruff"
            chmod +x "$repo/.venv/bin/ruff"
            expected='.venv/bin/ruff format' ;;
    esac
    out=$("$detect" --repo-root "$repo" --format suggestions)
    assert_contains "$out" "# AGENT_CMD_FORMAT_FIX=$expected" "$kind offers the paired fix"
    assert_contains "$out" '# AGENT_CMD_FORMAT=' "$kind keeps the format check"
done
for manager in npm pnpm yarn; do
    repo="$tmp/check-only-$manager"
    mkdir -p "$repo/ui"
    case $manager in
        npm) touch "$repo/ui/package-lock.json"; prefix='npm exec --no --' ;;
        pnpm) touch "$repo/ui/pnpm-lock.yaml"; prefix='pnpm exec' ;;
        yarn) touch "$repo/ui/yarn.lock"; prefix='yarn exec' ;;
    esac
    printf '%s\n' '{"scripts":{"format:check":"prettier --check src docs/file.ts"}}' > "$repo/ui/package.json"
    out=$("$detect" --repo-root "$repo" --format suggestions)
    assert_contains "$out" "AGENT_CMD_UI_FORMAT_FIX=$prefix prettier --write src docs/file.ts" "$manager safely pairs simple check-only Prettier"
    assert_contains "$out" 'AGENT_RUNDIR_UI_FORMAT_FIX=ui' 'derived pair stays in the component'
done
for script in 'prettier --check src && echo done' 'prettier --check src/*.ts' 'prettier --check --ignore-path custom src' 'prettier --check "src with spaces"'; do
    jq -n --arg script "$script" '{scripts:{"format:check":$script}}' > "$repo/ui/package.json"
    out=$("$detect" --repo-root "$repo" --format suggestions)
    assert_not_contains "$out" 'AGENT_CMD_UI_FORMAT_FIX=' 'ambiguous check-only script gets no guessed fix'
    assert_contains "$out" 'add an explicit format:fix script' 'unsupported form explains the missing pair'
done
repo="$tmp/mono"
mkdir -p "$repo/backend"
touch "$repo/backend/Cargo.toml"
out=$("$detect" --repo-root "$repo" --format suggestions)
assert_contains "$out" '# AGENT_CMD_BACKEND_FORMAT_FIX=cargo fmt' 'component name precedes FORMAT_FIX'
assert_contains "$out" '# AGENT_RUNDIR_BACKEND_FORMAT_FIX=backend' 'fix keeps the component cwd'

repo="$tmp/run"
git init -q "$repo"
mkdir -p "$repo/.agent" "$repo/component"
cat > "$repo/component/formatter" <<'SH'
#!/bin/sh
case "$1" in
    fix) printf fixed > 'file with spaces';;
    check) test "$(cat 'file with spaces' 2>/dev/null)" = fixed ;;
esac
SH
chmod +x "$repo/component/formatter"
cat > "$repo/.agent/config.env" <<'CFG'
AGENT_CMD_FORMAT=./formatter check
AGENT_RUNDIR_FORMAT=component
AGENT_CMD_FORMAT_FIX=./formatter fix
AGENT_RUNDIR_FORMAT_FIX=component
AGENT_CMD_BACKEND_FORMAT=./formatter check
AGENT_RUNDIR_BACKEND_FORMAT=component
AGENT_CMD_BACKEND_FORMAT_FIX=./formatter fix
AGENT_RUNDIR_BACKEND_FORMAT_FIX=component
CFG
assert_rc 1 'check starts red' -- "$run" --dir "$repo" --cmd format
assert_rc 0 'declared fix executes' -- "$run" --dir "$repo" --cmd format --fix
assert_rc 0 'check passes after fix' -- "$run" --dir "$repo" --cmd format
rm -f "$repo/component/file with spaces"
assert_rc 0 'component fix can chain its check' -- "$run" --dir "$repo" --cmd backend-format --fix --cmd backend-format
assert_rc 1 'fix rejects a non-formatter' -- "$run" --dir "$repo" --cmd test --fix
assert_rc 1 'fix rejects literal commands' -- "$run" --dir "$repo" --fix -- true
printf 'AGENT_REPO_RUNNER=./runner\n' > "$repo/.agent/config.env"
printf '#!/bin/sh\ntouch runner-was-used\n' > "$repo/runner"
chmod +x "$repo/runner"
out=$("$run" --dir "$repo" --cmd format --fix 2>&1)
assert_contains "$out" 'AGENT_CMD_FORMAT_FIX' 'missing fix declaration names its key'
assert_eq no "$([[ -e $repo/runner-was-used ]] && printf yes || printf no)" 'missing fix never falls back to runner'

# Optional fix absence must skip before fallback and preserve the next link.
for check_declared in no yes; do
    for runner_declared in no yes; do
        printf 'AGENT_CMD_TEST=touch required-test-ran\n' > "$repo/.agent/config.env"
        [[ $check_declared == no ]] || printf 'AGENT_CMD_FORMAT=false\n' >> "$repo/.agent/config.env"
        [[ $runner_declared == no ]] || printf 'AGENT_REPO_RUNNER=./runner\n' >> "$repo/.agent/config.env"
        scenario="check=$check_declared runner=$runner_declared"
        assert_rc 0 "optional missing fix skips ($scenario)" -- "$run" --dir "$repo" --cmd format --fix --if-declared
        rm -f "$repo/required-test-ran"
        out=$("$run" --dir "$repo" --force --cmd format --fix --if-declared --cmd test 2>&1)
        assert_eq 0 "$?" "optional fix chain succeeds ($scenario)"
        assert_contains "$out" 'skipping' "optional fix explains its skip ($scenario)"
        assert_eq yes "$([[ -e $repo/required-test-ran ]] && printf yes || printf no)" "mandatory chain link executes ($scenario)"
        assert_eq no "$([[ -e $repo/runner-was-used ]] && printf yes || printf no)" "optional fix bypasses runner ($scenario)"
        assert_rc 1 "required missing fix still fails ($scenario)" -- "$run" --dir "$repo" --cmd format --fix
    done
done

# Recorded cargo-style failure with noisy output and an adversarially long line.
cat > "$repo/cargo" <<'SH'
#!/bin/sh
printf 'running 2 tests\n'
printf 'noise %.0s' $(seq 1 3000)
printf '\nfailures:\n\n---- tests::broken stdout ----\n'
printf "thread 'tests::broken' panicked at src/lib.rs:12:5:\nassertion left == right failed\n  left: 1\n right: 2\nnote: backtrace\ncontext-five\ncontext-six\n"
printf '\nfailures:\n    tests::broken\n\ntest result: FAILED. 1 passed; 1 failed\n'
printf 'error[E0308]: incompatible types\n  --> src/lib.rs:12:5\n   |\n12 | broken\n   | expected u8\n   | found str\ncompiler-context-six\n'
awk 'BEGIN { for(i=0;i<100;i++) { printf "error[E9999]: "; for(j=0;j<10000;j++) printf "x"; print "" } }'
exit 101
SH
chmod +x "$repo/cargo"
printf 'AGENT_CMD_TEST=./cargo test\n' > "$repo/.agent/config.env"
out=$("$run" --dir "$repo" --cmd test 2>&1)
rc=$?
assert_eq 101 "$rc" 'cargo failure status survives extraction pipelines'
assert_contains "$out" 'tests::broken' 'summary includes failing test names'
assert_contains "$out" 'right: 2' 'summary includes panic diagnostics'
assert_contains "$out" 'compiler-context-six' 'summary includes six following compiler lines'
assert_contains "$out" 'full log:' 'summary links the full log'
assert_eq yes "$([[ ${#out} -lt 8000 ]] && printf yes || printf no)" 'long diagnostics cannot defeat the output cap'
log=$(sed -n 's/^full log: //p' <<< "$out")
assert_eq yes "$([[ -f $log && $(wc -c < "$log") -gt 1000000 ]] && printf yes || printf no)" 'full log retains unabridged diagnostics'
finish
