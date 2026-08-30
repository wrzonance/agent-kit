#!/usr/bin/env bash
#
# harness-advice.sh -- the harness settings THIS machine actually needs.
#
# Prints nothing when nothing is wrong. That is the whole design: a block of
# configuration advice on every session is noise, and noise is how the
# environment contract stops being read. Advice appears only for a capability
# that is measurably missing right now.
#
# Every entry was earned by a real session losing time to it: an agent told the
# operator to re-authenticate a working gh because a sandbox denied the network;
# three separate sessions hit a read-only .git and each treated it as a fresh
# permissions fault; a pinned runtime failed every command in a worktree while
# the machine had the right version installed all along.
#
# Reports, never fails. Exit 0 always.
set -uo pipefail

PROGRAM=${0##*/}
ARG_REPO_ROOT=""
ARG_FORMAT=text

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --repo-root)
            ARG_REPO_ROOT=${2:-}
            shift 2 || shift
            ;;
        --quiet) ARG_FORMAT=quiet && shift ;;
        -h | --help)
            printf 'usage: %s [--repo-root DIR] [--quiet]\n' "$PROGRAM"
            printf '\nPrints the harness settings this machine needs, and nothing when it needs none.\n'
            printf -- '--quiet prints only a count, for a caller deciding whether to show the block.\n'
            exit 0
            ;;
        *) shift ;;
    esac
done

repo_root=${ARG_REPO_ROOT:-$(git rev-parse --show-toplevel 2> /dev/null || printf '%s' "$PWD")}
self_dir=${BASH_SOURCE[0]%/*}
[[ $self_dir != "${BASH_SOURCE[0]}" ]] || self_dir=.

findings=()

# --- can this process reach the forge at all? -------------------------------
# gh validates a token by calling the API, so a denied network is reported as an
# invalid token. That sent an operator to re-authenticate twice, changing
# nothing, while their credentials were perfect.
gh_state=$("$self_dir/gh-auth-state.sh" 2> /dev/null || printf 'state=unknown')
case $gh_state in
    *network-unreachable*)
        findings+=("network|The forge is unreachable from this process, and gh reports that as an invalid token -- do NOT re-authenticate.|[sandbox_workspace_write]
network_access = true|Outbound network for agent commands. Without it every forge call fails, wearing the costume of an auth failure.")
        ;;
    *keyring-unreadable*)
        findings+=("token|A token exists but this process cannot read it: it lives in the OS keyring, which a login shell reaches and an agent's commands may not.|gh auth token | gh auth login --hostname github.com --with-token --insecure-storage|Moves the token to a 0600 file. It becomes plaintext on disk, readable by anything running as you -- the usual trade for headless tooling, and yours to make.")
        ;;
esac

# The writable roots this harness is ALREADY configured with. Read so the advice
# can tell "you have not set this" apart from "you set it and it did not work" --
# repeating the first at someone who has already done it is how advice stops
# being read.
harness_writable_roots() {
    local cfg="${CODEX_HOME:-$HOME/.codex}/config.toml"
    [[ -r $cfg ]] || return 0
    sed -n 's/^[[:space:]]*writable_roots[[:space:]]*=[[:space:]]*\[\(.*\)\].*/\1/p' \
        "$cfg" 2> /dev/null |
        tr ',' '\n' |
        sed -E 's/^[[:space:]]*"?//; s/"?[[:space:]]*$//' |
        grep -v '^[[:space:]]*$' || true
}

# --- can git write? ---------------------------------------------------------
# A workspace sandbox holds <repo>/.git read-only ON PURPOSE, so every commit,
# every worktree, and even .git/info/exclude costs an approval round-trip.
git_dir=$(git -C "$repo_root" rev-parse --git-common-dir 2> /dev/null || true)
if [[ -n $git_dir ]]; then
    case $git_dir in /*) ;; *) git_dir="$repo_root/$git_dir" ;; esac
    if ! probe=$(mktemp "$git_dir/.agentkit-probe-XXXXXX" 2> /dev/null); then
        # Was a broader root already granted? An operator who lists a parent
        # directory has taken the whole risk -- every repository beneath it --
        # and, observed on a real machine, still has a read-only .git. Telling
        # them to "add writable_roots" then reads as advice that does not work,
        # when the actual correction is to name the .git path itself.
        ancestor='' exact=''
        while IFS= read -r root; do
            [[ -n $root ]] || continue
            if [[ $root == "$git_dir" ]]; then
                exact=$root
                break
            fi
            case "$git_dir/" in "$root"/*) [[ -n $ancestor ]] || ancestor=$root ;; esac
        done < <(harness_writable_roots)

        if [[ -n $exact ]]; then
            findings+=("git|This .git is listed in writable_roots and is STILL read-only, so the setting is not in effect.|Restart the agent after editing the config|A running session keeps the sandbox it started with. If a restart does not help, the path must match what git reports: $git_dir")
        elif [[ -n $ancestor ]]; then
            findings+=("git|Every git write needs an approval, and \"$ancestor\" is already in writable_roots -- a parent directory did not cover this .git.|[sandbox_workspace_write]
writable_roots = [\"$git_dir\"]|Name the .git path itself. The parent entry is granting every repository beneath it for no benefit here, so replace it rather than adding to it.")
        else
            findings+=("git|Every git write needs an approval: a workspace sandbox holds this .git read-only.|[sandbox_workspace_write]
writable_roots = [\"$git_dir\"]|Scope it to THIS repository, not a parent directory. It removes a blunt protection, so the narrow form matters -- see the risk note below.")
        fi
    fi
    [[ -z ${probe:-} ]] || rm -f -- "$probe" 2> /dev/null || true
fi

# --- is the pinned runtime the active one? ----------------------------------
pin=""
pin_src=""
if [[ -r $repo_root/.nvmrc ]]; then
    pin=$(tr -d '[:space:]v' < "$repo_root/.nvmrc" 2> /dev/null | head -c 16)
    pin_src=.nvmrc
elif [[ -r $repo_root/.node-version ]]; then
    pin=$(tr -d '[:space:]v' < "$repo_root/.node-version" 2> /dev/null | head -c 16)
    pin_src=.node-version
fi
if [[ -n $pin ]] && command -v node > /dev/null 2>&1; then
    active=$(node --version 2> /dev/null | tr -d 'v')
    if [[ ${active%%.*} != "${pin%%.*}" ]]; then
        findings+=("runtime|This repository pins node $pin ($pin_src) and $active is active, so every command here fails an engine check.|Activate it in the shell that LAUNCHES the agent|A version manager switches a shell, not a child process -- the agent inherits whatever was active when it started.")
    fi
fi

if [[ $ARG_FORMAT == quiet ]]; then
    printf '%s\n' "${#findings[@]}"
    exit 0
fi
((${#findings[@]})) || exit 0

printf 'HARNESS CONFIGURATION -- %d setting(s) this machine needs\n' "${#findings[@]}"
printf 'Tell the user; these are their decisions, not yours to apply.\n\n'
for finding in "${findings[@]}"; do
    # Split on "|" WITHOUT `read`: a fix is two lines (a TOML section and the
    # key under it), and `read` stops at the first newline. It was therefore
    # printing the section header alone and an empty "why" -- so the advice
    # named a config block and never the setting to put in it, which is the one
    # thing the reader needed.
    rest=${finding#*|}
    symptom=${rest%%|*}
    rest=${rest#*|}
    fix=${rest%%|*}
    why=${rest#*|}
    printf '* %s\n' "$symptom"
    printf '%s\n' "$fix" | sed 's/^/      /'
    printf '  why: %s\n\n' "$why"
done

# Stated every time the git finding appears, because the setting is the one that
# trades away a protection rather than restoring a capability.
if printf '%s\n' "${findings[@]}" | grep -q '^git|'; then
    cat << 'EOF'
Risk, on the writable_roots setting specifically:

  A read-only .git is the only thing standing between an agent and the git
  plumbing -- update-ref, reflog expire, gc --prune, filter-branch -- and
  .git/config keys that execute commands during ordinary git operations.

  agentkit refuses those at command level, with no override. Treat it as a
  speed bump. The protection moves from the filesystem to pattern matching,
  and the patterns HAVE been evaded: an external audit found four ordinary
  long-option spellings that passed while their short forms were refused.
  Those are fixed; assume more exist. Spelling defeats a pattern and cannot
  defeat a read-only mount.

  Scope it to one repository's .git. A parent directory hands every repo
  under it to any session, and nothing here is repo-aware enough to stop that.
EOF
fi
