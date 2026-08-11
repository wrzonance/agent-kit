#!/usr/bin/env bash
# Suite: repository command approval reads its confirmation from the controlling
# terminal, enforced in `agent-run.sh` itself. This is defense-in-depth, not a
# cryptographic human-only gate (an agent that allocates a pseudo-terminal, as
# the helper here does, or writes the trust record directly, still can) -- its
# value is that a non-interactive agent shell cannot answer the prompt, so the
# refusal no longer hands back a runnable `--approve`. These cases pin that a
# terminal-less attempt fails and persists no trust across every shell spelling,
# that a terminal confirmation approves or declines, and that the removed hook
# matcher raises no false denial.
set -uo pipefail

TEST_NAME='agent-run-approval-gate'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tty_approve="$here/lib/tty-approve"
readme="$root/README.md"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    printf 'AGENT_CMD_VERIFY=true\n' > "$dir/.agent/config.env"
    printf '%s' "$dir"
}

# A repo-local trust root, so an approval (or its absence) is observable and
# never leaks into the developer's real state directory.
trust_files() { find "$1" -name '*.trust' 2> /dev/null; }

# --- the tool refuses approval with no controlling terminal, every spelling ---
# `setsid` detaches from any controlling terminal, reproducing a non-interactive
# agent shell regardless of whether the test itself runs under a TTY. Every
# spelling an agent could reach for by re-running the printed refusal must fail
# identically and persist no trust. (A determined agent that allocates its own
# pseudo-terminal is out of scope -- the gate is defense-in-depth, not a proof
# of humanity; see the suite header.)
repo=$(make_repo)
trust_root="$tmp/trust-agent"

agent_approve() {
    setsid env AGENT_TRUST_ROOT="$trust_root" bash -c "$1" < /dev/null 2>&1
}

while IFS='|' read -r label spelling; do
    out=$(cd "$repo" && agent_approve "$spelling") && rc=0 || rc=$?
    assert_eq '1' "$rc" "agent approval fails without a terminal: $label"
    assert_contains "$out" 'interactive terminal' \
        "agent approval names the missing capability: $label"
    assert_contains "$out" 'defense-in-depth' \
        "agent approval does not overclaim the boundary: $label"
done <<EOF
plain|"$run_sh" --approve --cmd verify
reordered|"$run_sh" --cmd verify --approve
quoted-option|"$run_sh" "--approve" --cmd verify
bash-c|bash -c '"$run_sh" --approve --cmd verify'
sh-c|sh -c '"$run_sh" --approve --cmd verify'
command-builtin|command "$run_sh" --approve --cmd verify
env-prefix|env FOO=bar "$run_sh" --approve --cmd verify
EOF

# No spelling above wrote trust, so a normal run is still refused.
assert_eq '' "$(trust_files "$trust_root")" \
    'no agent spelling persisted repository trust'
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" "$run_sh" --cmd verify 2>&1) || true
assert_contains "$out" 'refusing unapproved repository command' \
    'the command stays unapproved after every agent attempt'

# --- a terminal confirmation approves, and only then does the command run ---
# (The helper's PTY stands in for a terminal; it authenticates no human -- that
# is the point of the defense-in-depth framing above.)
repo=$(make_repo)
trust_root="$tmp/trust-confirmed"
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" y -- "$run_sh" --approve --cmd verify 2>&1) && rc=0 || rc=$?
assert_eq '0' "$rc" 'a terminal confirmation approves'
assert_contains "$out" 'approved verify' 'the approval is recorded'
assert_contains "$(trust_files "$trust_root")" '.trust' \
    'the confirmed approval persisted a trust record'
assert_rc 0 'the approved command now runs' -- \
    env AGENT_TRUST_ROOT="$trust_root" "$run_sh" --dir "$repo" --cmd verify

# --- a declined terminal confirmation approves nothing ---
repo=$(make_repo)
trust_root="$tmp/trust-declined"
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$tty_approve" n -- "$run_sh" --approve --cmd verify 2>&1) && rc=0 || rc=$?
assert_eq '1' "$rc" 'a declined confirmation fails'
assert_contains "$out" 'approval declined' 'a declined confirmation says so'
assert_eq '' "$(trust_files "$trust_root")" 'a declined confirmation persists no trust'

# --- the hook does not police approval, so it raises no false denial ---
# The prior matcher misfired on literal commands after `--` and on quoted prose;
# with enforcement in the tool, the hook simply allows these.
pre_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:"approval-gate",tool_name:"Bash",tool_use_id:"t",
          transcript_path:null,tool_input:{command:$cmd}}'
}
decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$1"; }

repo=$(make_repo)
for allowed in \
    "\"$run_sh\" --approve --cmd verify" \
    "\"$run_sh\" -- some-tool --approve" \
    "echo 'example; $run_sh --approve --cmd verify'" \
    "grep -rn -- '--approve' agentkit/hooks"; do
    out=$(pre_input "$repo" "$allowed" | "$hooks/pre-tool-use.sh" 2> /dev/null)
    assert_hook_output "$out" pre-tool-use "hook output is schema-valid: $allowed"
    assert_eq 'allow' "$(decision "$out")" "hook raises no false denial: $allowed"
done

# --- the wrapper refusal never prints a copyable bypass ---
repo=$(make_repo)
out=$(cd "$repo" && AGENT_TRUST_ROOT="$tmp/trust-msg" "$run_sh" --cmd verify 2>&1) || true
assert_contains "$out" 'refusing unapproved repository command' \
    'the wrapper refuses an unapproved repository command'
assert_contains "$out" 'human' 'the wrapper refusal points at a human review'
assert_not_contains "$out" '--approve --cmd verify' \
    'the wrapper refusal does not print the bypass command'

# --- an explicitly unattended run passes the gate with --yolo, loudly ---
# The flag exists for fleets a human launched as unattended: without it, blocked
# workers stall (or worse, forge the confirmation). It must run the command with
# no approval record, announce the skip on stderr -- the audit stream -- and
# persist nothing. Streams are captured separately so a wrong-stream audit line
# cannot pass, and the PASS line proves the declared command actually ran.
# --yolo validates the declaration against the remote trunk, so this fixture
# publishes its config.env to a local origin first. setsid runs with -w so the
# child's exit status propagates instead of a fork-and-exit 0.
make_published_repo() {
    local dir origin
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    origin=$(mktemp -d "$tmp/origin.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    printf 'AGENT_CMD_VERIFY=true\n' > "$dir/.agent/config.env"
    git -C "$dir" add .agent/config.env
    git -C "$dir" -c user.email=t@example.invalid -c user.name=t commit -qm init
    git -C "$dir" init -q --bare "$origin" 2> /dev/null || git init -q --bare "$origin"
    git -C "$dir" remote add origin "$origin"
    git -C "$dir" push -q origin HEAD:main
    git -C "$dir" fetch -q origin
    printf '%s' "$dir"
}
repo=$(make_published_repo)
trust_root="$tmp/trust-yolo"
yolo_err="$tmp/yolo-stderr"
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" --yolo --cmd verify < /dev/null 2> "$yolo_err") && rc=0 || rc=$?
err=$(cat -- "$yolo_err")
assert_eq '0' "$rc" '--yolo runs an unapproved declared command without a terminal'
assert_contains "$out" 'PASS: true' '--yolo actually ran the declared command'
assert_contains "$err" 'trust gate skipped (--yolo)' \
    '--yolo announces the skip on stderr'
assert_not_contains "$out" 'trust gate skipped' \
    'the audit line stays off stdout'
assert_eq '' "$(trust_files "$trust_root")" '--yolo persists no trust record'

# The skip survives in the durable artifact: an audit reading only the retained
# logs must be able to tell a bypassed run from an approved one.
yolo_log=$(find "$repo/.agent/logs" -name '*.log' | head -1)
assert_contains "$(cat -- "$yolo_log")" 'trust gate skipped (--yolo)' \
    'the run log records the bypass'

# --yolo is trunk-bounded: an input that differs from the remote trunk is new
# code asking to run unattended, and is refused without a trust record.
printf 'AGENT_CMD_VERIFY=false\n' > "$repo/.agent/config.env"
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" --yolo --cmd verify < /dev/null 2>&1) && rc=0 || rc=$?
assert_eq '1' "$rc" 'a declaration changed from the trunk is refused under --yolo'
assert_contains "$out" 'refusing --yolo' 'the refusal names the yolo gate'
assert_contains "$out" '.agent/config.env' 'the refusal names the changed input'
assert_eq '' "$(trust_files "$trust_root")" 'the trunk-mismatch refusal persists no trust'
git -C "$repo" checkout -q -- .agent/config.env

# An untracked runner is equally a changed input: present here, absent at trunk.
printf '#!/bin/sh\nexit 0\n' > "$repo/.agent/runner"
chmod +x "$repo/.agent/runner"
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" --yolo --cmd verify < /dev/null 2>&1) && rc=0 || rc=$?
assert_eq '1' "$rc" 'an untracked runner is refused under --yolo'
assert_contains "$out" '.agent/runner' 'the refusal names the introduced runner'
rm -f "$repo/.agent/runner"

# Without a remote trunk to validate against, --yolo refuses rather than guesses.
repo=$(make_repo)
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" --yolo --cmd verify < /dev/null 2>&1) && rc=0 || rc=$?
assert_eq '1' "$rc" '--yolo without a remote trunk ref is refused'
assert_contains "$out" 'no remote trunk ref' 'the refusal names the missing baseline'

# --yolo is inert for a literal command -- the gate never covered those, so
# there is no skip to announce and still nothing to persist. No trunk is needed
# either: the check guards repository-declared commands only.
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" --yolo -- true < /dev/null 2>&1) && rc=0 || rc=$?
assert_eq '0' "$rc" 'a literal command runs under --yolo'
assert_not_contains "$out" 'trust gate skipped' \
    '--yolo is inert for a literal command'
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    setsid -w "$run_sh" -- true < /dev/null 2>&1) && rc=0 || rc=$?
assert_eq '0' "$rc" 'the same literal command runs without --yolo'
assert_eq '' "$(trust_files "$trust_root")" \
    'literal commands persist no trust either way'

# The skip is per-invocation: the very next plain run is still refused.
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" "$run_sh" --cmd verify 2>&1) || true
assert_contains "$out" 'refusing unapproved repository command' \
    'a plain run after --yolo is still refused'

# --approve records trust and --yolo skips it; together they are a usage error.
out=$(cd "$repo" && AGENT_TRUST_ROOT="$trust_root" \
    "$run_sh" --approve --yolo --cmd verify 2>&1) && rc=0 || rc=$?
assert_eq '1' "$rc" '--approve with --yolo is refused'
assert_contains "$out" 'mutually exclusive' '--approve/--yolo refusal names the conflict'
assert_eq '' "$(trust_files "$trust_root")" 'the refused combination persists no trust'

# --- the README documents the terminal confirmation and is honest about it ---
readme_text=$(cat -- "$readme")
assert_contains "$readme_text" 'controlling terminal' \
    'README documents the terminal-confirmation boundary'
assert_contains "$readme_text" 'not** a cryptographic human-only' \
    'README does not overclaim the boundary as human-only'
assert_contains "$readme_text" 'agent-run.sh --yolo --cmd NAME' \
    'README documents the unattended bypass by its exact invocation'
assert_contains "$readme_text" 'records no trust' \
    'README states the bypass persists nothing'

finish
