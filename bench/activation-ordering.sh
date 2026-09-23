#!/usr/bin/env bash
# Does the harness deliver UserPromptSubmit additionalContext before the model's first tool call?
# Probe: invoke a workflow with a prompt that asks the model to echo the nonce from its context
# as its FIRST tool call, then compare that call to the nonce in the receipt record.
set -euo pipefail
PROGRAM=${0##*/}
usage() { printf 'usage: %s --harness codex|claude --repo DIR [--plugin-dir DIR] [--out DIR]\n' "$PROGRAM"; }
harness='' repo='' out='' plugin_dir=''
while (($#)); do
    case $1 in
        --harness) harness=$2; shift 2 ;;
        --repo) repo=$2; shift 2 ;;
        --plugin-dir) plugin_dir=$2; shift 2 ;;
        --out) out=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ $harness == codex || $harness == claude ]] || { usage >&2; exit 2; }
[[ -d $repo/.git ]] || { printf '%s: --repo must be a git checkout with the plugin hooks active\n' "$PROGRAM" >&2; exit 2; }
[[ $harness != claude || -n $plugin_dir ]] || { printf '%s: --plugin-dir is required for --harness claude\n' "$PROGRAM" >&2; exit 2; }
out=${out:-$(mktemp -d "${TMPDIR:-/tmp}/activation-ordering.XXXXXX")}
# Literal $agentkit: workflow trigger below is not meant to expand.
# shellcheck disable=SC2016
prompt='$agentkit:parallel-issues probe: your FIRST and ONLY tool call must be the shell command
printf "PROBE_NONCE=%s\n" <nonce>  where <nonce> is the --nonce value from the receipt command
in your context. Make no other call. If no such command is in your context, run
printf "PROBE_NONCE=none\n" instead. Then stop.'
case $harness in
    codex)
        (cd -- "$repo" && codex exec --json -s workspace-write --skip-git-repo-check "$prompt") > "$out/transcript.jsonl" 2> "$out/stderr.log" || true
        first_call=$(jq -r 'select(.type=="item.completed" and .item.type=="command_execution") | .item.command' "$out/transcript.jsonl" | head -1)
        if [[ -z $first_call ]]; then
            # The PreToolUse hook may block the command before it becomes a
            # command_execution item; codex still logs the attempted command.
            first_call=$(grep -o 'Command: .*' "$out/stderr.log" | head -1)
            first_call=${first_call#Command: }
        fi
        session=$(jq -r 'select(.type=="thread.started") | .thread_id' "$out/transcript.jsonl" | head -1)
        ;;
    claude)
        # A precise allow list for the one command the probe needs; never a blanket permission bypass.
        # --allowedTools takes a variadic list; use = so it doesn't swallow the prompt positional.
        # The plugin under test is loaded for this session only from the built tree
        # (tests/build-plugin.sh), so the probe measures the branch's hooks and never
        # touches the user's installed plugins.
        (cd -- "$repo" && claude -p --output-format stream-json --verbose --allowedTools='Bash(printf:*)' --plugin-dir "$plugin_dir" "$prompt") > "$out/transcript.jsonl" 2> "$out/stderr.log" || true
        first_call=$(jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Bash") | .input.command' "$out/transcript.jsonl" | head -1)
        if [[ -z $first_call ]]; then
            # The PreToolUse hook may block the command before it becomes a
            # tool_use content block; fall back to the composed command as
            # logged in the block notice, the same way the Codex leg does.
            first_call=$(grep -o 'Command: .*' "$out/stderr.log" | head -1)
            first_call=${first_call#Command: }
        fi
        session=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$out/transcript.jsonl" | head -1)
        ;;
esac
[[ -n $session ]] || { printf 'ORDER=no-session transcript=%s\n' "$out/transcript.jsonl"; exit 1; }
receipt="$repo/.agent/activation/$(printf '%s' "$session" | sha256sum | cut -d' ' -f1).json"
if [[ ! -f $receipt ]]; then printf 'ORDER=no-delivery receipt-missing=%s transcript=%s\n' "$receipt" "$out/transcript.jsonl"; exit 1; fi
nonce=$(jq -r '.nonce' "$receipt")
# The probed command is `printf "PROBE_NONCE=%s\n" <nonce>` -- the nonce is a
# trailing printf argument, not inlined after "PROBE_NONCE=", in both the
# command_execution item and the PreToolUse-blocked command text. Match on
# the nonce appearing in the command at all.
if [[ $first_call == *"$nonce"* ]]; then
    printf 'ORDER=context-before-first-call harness=%s transcript=%s\n' "$harness" "$out/transcript.jsonl"
elif [[ $first_call == *PROBE_NONCE=none* ]]; then
    printf 'ORDER=first-call-before-context harness=%s transcript=%s\n' "$harness" "$out/transcript.jsonl"; exit 1
else
    printf 'ORDER=unclassified first-call=%q transcript=%s\n' "$first_call" "$out/transcript.jsonl"; exit 1
fi
