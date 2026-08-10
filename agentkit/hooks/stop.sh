#!/usr/bin/env bash
# Stop -> block when a declared verify command has not covered the current
# changes. Declaring a verify command IS the opt-in: a repository that declares
# none is never blocked.
#
# This never runs verification itself; it only checks that verification happened.
# NEVER exits non-zero.
set -uo pipefail

allow() { printf '{}\n'; exit 0; }
GUARD_HOOK_NAME=stop
trap 'guard_log_error $? 2>/dev/null || true; allow' ERR

input=$(cat 2> /dev/null || true)

# A retry with no successful stamp remains the loop guard for a genuinely
# failing command. Once a stamp exists, active retries go through the same
# attestation below and cannot bypass later changes.
stop_active=$(jq -r '.stop_hook_active // false' <<< "$input" 2> /dev/null || true)

cwd=$(jq -r '.cwd // empty' <<< "$input" 2> /dev/null || true)
[[ -n $cwd && -d $cwd ]] || allow

root=$(git -C "$cwd" rev-parse --show-toplevel 2> /dev/null || true)
[[ -n $root ]] || allow

self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.
# shellcheck source=lib/guard-lib.sh
source "$self_dir/lib/guard-lib.sh" 2> /dev/null || allow

resolver="$self_dir/../skills/.shared/scripts/repo-config.sh"
[[ -x $resolver ]] || allow

# 1. Opt-in check.
verify_name=''
for candidate in VERIFY TEST; do
    if [[ -n $("$resolver" --repo-root "$root" --get "AGENT_CMD_$candidate" 2> /dev/null || true) ]]; then
        verify_name=$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]')
        break
    fi
done
[[ -n $verify_name ]] || allow

# 2. Any changes at all?
#
# .agent/ is excluded: it is the agent's own untracked working state -- logs,
# caches, the env contract, and this very stamp -- so it is never what a
# verification run covers. Counting it would break this check twice over. Every
# repository that opted in has an untracked .agent/, so a tree with no source
# change at all would read as changed; and agent-preflight.sh rewrites
# .agent/env-contract.txt on session start, which bumps the directory's own mtime
# past the stamp and would block a tree verification had just covered.
changed_paths=()
while IFS= read -r -d '' record; do
    status=${record:0:2}
    rel=${record:3}
    if [[ $rel != .agent && $rel != .agent/* ]]; then
        changed_paths+=("$rel")
    fi

    # With -z, rename/copy output is <status + new path><old path>. Consume the
    # second NUL record explicitly so it cannot be mistaken for a new status.
    if [[ $status == *R* || $status == *C* ]]; then
        IFS= read -r -d '' rel || break
        if [[ $rel != .agent && $rel != .agent/* ]]; then
            changed_paths+=("$rel")
        fi
    fi
done < <(git -C "$root" status --porcelain=v1 -z --untracked-files=all 2> /dev/null)
((${#changed_paths[@]})) || allow

block() {
    jq -nc --arg r "$1" '{decision:"block",reason:$r}'
    exit 0
}

# The stamp is per command NAME, and the name read here is the one selected
# above. A stamp that said only "something passed" would be cleared by any
# passing command -- a repository declaring AGENT_CMD_LINT=true would disarm this
# check in one line while its real gate still failed.
stamp="$root/.agent/cache/stamp-$verify_name"
# "Changes are not covered by a verification run" claimed a completeness this
# gate does not have. It knows one thing: whether the command THIS REPOSITORY
# declared has run over these changes. A live run had that command pass while CI
# failed a gate no declared command covered -- and the wording is what made that
# a surprise rather than a known limit.
reason="The command this repository declared as $verify_name has not run over these
changes. That is the only thing this gate checks -- it is not a claim that the
changes are correct, or that CI will agree. Run:
$RESOLVE_HINT
  \"\$agentkit/.shared/scripts/agent-run.sh\" --cmd $verify_name
then finish."

path_newer_than_stamp() {
    local rel=$1 candidate parent
    candidate=$root/$rel
    if [[ -e $candidate || -L $candidate ]]; then
        [[ $candidate -nt $stamp ]]
        return
    fi

    parent=${rel%/*}
    [[ $parent == "$rel" ]] && parent=.
    while [[ $parent != . && ! -d $root/$parent ]]; do
        [[ $parent == */* ]] && parent=${parent%/*} || parent=.
    done
    candidate=$root/$parent
    [[ $candidate -nt $stamp ]]
}

# This gate runs at the END OF EVERY TURN, so whichever command it picks is
# paid for on a one-line comment as surely as on a refactor. A repository that
# declares only a full suite therefore charges minutes for trivial edits --
# observed, on a single added YAML comment.
if [[ $verify_name != verify ]]; then
    reason+="

This repository declares no AGENT_CMD_VERIFY, so the gate falls back to
'$verify_name'. Since it runs at the end of every turn, declaring a FAST
AGENT_CMD_VERIFY (lint and typecheck, seconds) keeps the per-turn cost
proportionate while '$verify_name' stays available for the full run."
fi

# 3. No stamp at all.
if [[ ! -r $stamp ]]; then
    [[ $stop_active == true ]] && allow
    block "$reason"
fi

# A failed verification must not trap the harness in an unbounded active-retry
# loop. The first Stop already issued the verification nudge; the retry is the
# escape hatch when that command could not produce a fresh successful stamp.
[[ $stop_active == true ]] && allow

# 4. Any change newer than the stamp. A deleted path has no mtime of its own;
# walk to the nearest surviving directory, whose mtime records the entry
# removal.
for rel in "${changed_paths[@]}"; do
    path_newer_than_stamp "$rel" && block "$reason"
done

allow
