#!/usr/bin/env bash
# Generate <repo>/.agent/config.env and .agent/board.json from live discovery.
#
# Run this ONCE per repository, on a machine authenticated to that repository's
# forge. It writes only whitelisted keys and never copies environment or token
# material into its output.
#
# Both files are built in a staging directory, validated against repo-config.sh,
# and only then moved into place. A discovery failure writes NOTHING: a
# half-populated option map would produce silently wrong board moves, which is
# worse than having no cache at all.
#
# Usage:
#   bootstrap-repo.sh [--repo-root DIR] [--project N] [--dry-run] [--force]
#
# Exit: 0 success, 1 discovery failed or would clobber, 2 bad usage,
#       3 gh unavailable or unauthenticated (environment-blocked).
set -euo pipefail

readonly PROGRAM=${0##*/}
readonly BOARD_SCHEMA_VERSION=1

warn() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }
die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}
die_blocked() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 3
}
die_usage() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    printf 'usage: %s [--repo-root DIR] [--project N] [--dry-run] [--force]\n' "$PROGRAM" >&2
    exit 2
}

repo_root=''
project_number=''
dry_run=0
force=0

while (($#)); do
    case $1 in
        --repo-root)
            shift
            (($#)) || die_usage '--repo-root requires a directory'
            repo_root=$1
            ;;
        --project)
            shift
            (($#)) || die_usage '--project requires a number'
            project_number=$1
            ;;
        --dry-run) dry_run=1 ;;
        --force) force=1 ;;
        -h | --help) die_usage 'help requested' ;;
        *) die_usage "unknown argument: $1" ;;
    esac
    shift
done

if [[ -n $project_number && ! $project_number =~ ^[0-9]{1,6}$ ]]; then
    die_usage "--project must be a number, got: $project_number"
fi

if [[ -z $repo_root ]]; then
    repo_root=$(git rev-parse --show-toplevel 2> /dev/null) ||
        die_usage 'not inside a git repository; pass --repo-root'
fi
[[ -d $repo_root ]] || die_usage "not a directory: $repo_root"

# --- preflight: environment-blocked is exit 3, not a failure ---------------
# This runs before ANY external command, including the coreutils used to locate
# the resolver below. Otherwise a stripped PATH dies at 127 on `dirname` and
# reports a missing-command error instead of the honest "gh is not installed".
for tool in gh jq dirname readlink sha256sum date mktemp; do
    command -v "$tool" > /dev/null 2>&1 || die_blocked "$tool is not installed"
done
# `gh auth status` exits NON-ZERO when any configured entry fails, even while a
# working account sits in the same output -- a stale token in the environment
# alongside a good one in the keyring reports both at once. Gating on it refused
# to onboard a machine that was perfectly able to reach the forge.
#
# The authoritative question is whether a call actually succeeds, so ask that.
if ! gh api user --jq .login > /dev/null 2>&1; then
    gh_state=$("$(dirname -- "${BASH_SOURCE[0]}")/gh-auth-state.sh" 2>/dev/null || printf 'state=unknown')
    die_blocked "gh cannot reach the forge FROM THIS PROCESS -- $gh_state

A token in the OS keyring is reachable from a login shell and may not be from
wherever these commands run, so \"it works in my terminal\" and this failure can
both be true. Nothing was written."
fi

self_dir=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
resolver="$self_dir/repo-config.sh"

# --- discover the repository ------------------------------------------------
# Slug and default branch in ONE call. Deliberately NOT `git remote show origin`:
# that contacts the remote over the network, and a bootstrap should not depend on
# git transport when it already has an authenticated forge client.
# Resolved from --repo-root, not from the process cwd. gh infers the repository
# from wherever it is invoked, so running this from repository A with
# `--repo-root /path/to/B` wrote A's slug, base branch and Project metadata into
# B -- a committed file, silently naming the wrong repository.
repo_json=$(cd -- "$repo_root" && gh repo view --json nameWithOwner,defaultBranchRef 2> /dev/null) ||
    die "could not resolve the repository from gh in $repo_root"
slug=$(jq -r '.nameWithOwner // empty' <<< "$repo_json" 2> /dev/null || true)
[[ $slug =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "gh returned an unusable slug: ${slug:-none}"
owner=${slug%%/*}
name=${slug#*/}

base_branch=$(jq -r '.defaultBranchRef.name // empty' <<< "$repo_json" 2> /dev/null || true)
if [[ -z $base_branch ]]; then
    # Local ref only; still no network.
    base_branch=$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null |
        sed 's|^origin/||' || true)
fi
[[ -n $base_branch ]] || die 'could not determine the base branch'

# --- discover the project ---------------------------------------------------
# Ask the REPOSITORY which boards it is linked to, not the owner which boards it
# owns. An organization can own dozens of boards while any given repo is linked
# to one, and the owner-wide list turns an unambiguous repo into a prompt.
# shellcheck disable=SC2016  # GraphQL variables, bound by gh's -F flags.
readonly LINKED_QUERY='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    projectsV2(first: 20) { nodes { id number title closed } }
  }
}'

projects_source='linked to this repository'
projects_json=$(gh api graphql -F "owner=$owner" -F "name=$name" -f "query=$LINKED_QUERY" 2> /dev/null |
    jq -c '{projects: (.data.repository.projectsV2.nodes // [])}' 2> /dev/null ||
    printf '{"projects":[]}')

if [[ $(jq '.projects | length' <<< "$projects_json" 2> /dev/null || printf 0) -eq 0 ]]; then
    # Not linked to anything, or the query failed: fall back to the owner's boards.
    projects_source="owned by $owner"
    projects_json=$(gh project list --owner "$owner" --format json 2> /dev/null) ||
        die "could not list projects for $owner"
fi

if [[ -n $project_number ]]; then
    project=$(jq -c --argjson n "$project_number" \
        'first(.projects[]? | select(.number == $n)) // empty' <<< "$projects_json")
    [[ -n $project ]] || die "owner $owner has no project number $project_number"
else
    open_count=$(jq '[.projects[]? | select(.closed != true)] | length' <<< "$projects_json")
    if [[ $open_count != 1 ]]; then
        warn "found $open_count open projects $projects_source; pass --project N to choose one:"
        jq -r '.projects[]? | select(.closed != true) | "  \(.number)  \(.title)"' \
            <<< "$projects_json" >&2
        die 'refusing to guess between boards'
    fi
    project=$(jq -c 'first(.projects[]? | select(.closed != true))' <<< "$projects_json")
fi

project_id=$(jq -r '.id // empty' <<< "$project")
project_num=$(jq -r '.number // empty' <<< "$project")
project_title=$(jq -r '.title // empty' <<< "$project")
[[ -n $project_id && -n $project_num ]] || die 'the selected project is missing an id or number'

# --- discover the Status field ---------------------------------------------
fields_json=$(gh project field-list "$project_num" --owner "$owner" --format json 2> /dev/null) ||
    die "could not list fields for project $project_num"

status_field=$(jq -c 'first(.fields[]? | select(.name == "Status" and (.options | type) == "array"))
    // empty' <<< "$fields_json")
if [[ -z $status_field ]]; then
    warn "project $project_num has no single-select Status field; fields found:"
    jq -r '.fields[]? | "  \(.name)"' <<< "$fields_json" >&2
    die 'a Status column is required'
fi

status_field_id=$(jq -r '.id // empty' <<< "$status_field")
option_count=$(jq '.options | length' <<< "$status_field")
[[ -n $status_field_id && $option_count -gt 0 ]] || die 'the Status field has no options'

# Vocabulary comes from the discovered option order, so a board with
# non-canonical column names is described accurately rather than forced into
# the canonical five.
status_vocab=$(jq -r '[.options[].name] | join(",")' <<< "$status_field")

# --- stage both files -------------------------------------------------------
staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
mkdir -p "$staging/.agent"

jq -n \
    --argjson v "$BOARD_SCHEMA_VERSION" \
    --arg owner "$owner" \
    --argjson num "$project_num" \
    --arg pid "$project_id" \
    --arg ptitle "$project_title" \
    --arg fid "$status_field_id" \
    --argjson opts "$(jq -c '[.options[] | {key: .name, value: .id}] | from_entries' \
        <<< "$status_field")" \
    '{schemaVersion: $v, owner: $owner,
      project: {number: $num, id: $pid, title: $ptitle},
      statusField: {id: $fid, name: "Status", options: $opts}}' \
    > "$staging/.agent/board.json"

# Fingerprint the stable parts only, so a title edit does not read as a board
# change while a renamed column does.
fingerprint_input=$(jq -S -c '{p: .project.id, f: .statusField.id,
    o: (.statusField.options | to_entries | sort_by(.key) | map(.value))}' \
    < "$staging/.agent/board.json")
fingerprint="sha256:$(printf '%s' "$fingerprint_input" | sha256sum | cut -d' ' -f1)"

generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq --arg fp "$fingerprint" --arg at "$generated_at" \
    '. + {generatedAt: $at, fingerprint: $fp}' \
    < "$staging/.agent/board.json" > "$staging/.agent/board.next"
mv -- "$staging/.agent/board.next" "$staging/.agent/board.json"

# The label taxonomy cannot be inferred -- only the repository owner knows which
# labels are types, areas, or priorities. So list the real ones as commented
# suggestions rather than guessing a split that would then be wrong everywhere.
labels=$(gh label list --repo "$slug" --limit 100 --json name -q '[.[].name] | join(",")' \
    2> /dev/null || true)

# Detect candidate verify commands. Like labels, these are SUGGESTIONS: only the
# repository owner knows which of several surfaces is canonical, so emit them
# commented and let a human choose.
#
# This used to hardcode one package manager and one ecosystem -- on a
# repository locked with a different node package manager it still suggested
# npm, and never looked for a lint script at all.
# detect-toolchains.sh finds every component by its own marker files instead,
# so a monorepo with several ecosystems gets a suggestion for each. Resolved
# as a sibling of THIS script, not $self_dir (the resolver's dir, which the
# staging validation below also depends on and must not be repurposed).
# Absent or failing detector: emit nothing and carry on -- bootstrap must
# never fail over a suggestion.
detector="$(dirname -- "${BASH_SOURCE[0]}")/detect-toolchains.sh"
suggestions=''
if [[ -x $detector ]]; then
    suggestions=$("$detector" --repo-root "$repo_root" --format suggestions 2> /dev/null) || suggestions=''
fi

adr_dir=''
for candidate in docs/adr docs/adrs docs/decisions docs/architecture/decisions adr doc/adr; do
    if [[ -d $repo_root/$candidate ]]; then
        adr_dir=$candidate
        break
    fi
done

{
    printf '# .agent/config.env -- repository facts for agent skills.\n'
    printf '# Generated by %s. Parsed line-wise, never sourced.\n' "$PROGRAM"
    printf '# Regenerate with: %s --force\n\n' "$PROGRAM"
    printf 'AGENT_REPO_SLUG=%s\n' "$slug"
    printf 'AGENT_BASE_BRANCH=%s\n' "$base_branch"
    printf 'AGENT_PROJECT_OWNER=%s\n' "$owner"
    printf 'AGENT_PROJECT_NUMBER=%s\n' "$project_num"
    printf 'AGENT_STATUS_VOCAB=%s\n' "$status_vocab"
    [[ -n $adr_dir ]] && printf 'AGENT_ADR_DIR=%s\n' "$adr_dir"
    printf 'AGENT_WORKTREE_ROOT=.worktrees\n'
    if [[ -n $labels ]]; then
        printf '\n# This repository'"'"'s labels, for you to split by intent. Uncomment and\n'
        printf '# classify the ones agents should reuse instead of inventing new labels.\n'
        printf '#   %s\n' "$labels"
        printf '# AGENT_LABEL_TYPES=\n# AGENT_LABEL_AREAS=\n# AGENT_LABEL_PRIORITIES=\n'
    fi
    if [[ -n $suggestions ]]; then
        printf '\n# Candidate verify commands found in this repository. Uncomment the ones\n'
        printf '# agents should run, as AGENT_CMD_<NAME>=<command>. Commands are argv:\n'
        printf '# no shell, no pipes, no redirects. For anything more, use .agent/runner.\n'
        printf '%s\n' "$suggestions"
        printf '# AGENT_CMD_VERIFY=\n# AGENT_CMD_TEST=\n# AGENT_CMD_LINT=\n'
    fi
    # --force regenerates DISCOVERED facts; it must not throw away DECLARED ones.
    #
    # Everything above is rediscoverable from the forge. The verify commands and
    # label classifications are not -- they are judgement work someone did once,
    # and on a real repository they represented a run of the full test suite to
    # confirm each command actually worked. Regenerating over them silently
    # destroyed all of it; the agent that hit this happened to notice and put it
    # back by hand, which is not a mechanism.
    #
    # So every declared key this generator does not own is carried across
    # verbatim, and reported.
    if [[ -f $repo_root/.agent/config.env ]]; then
        carried=$(grep -E '^[[:space:]]*AGENT_[A-Z0-9_]+=' "$repo_root/.agent/config.env" 2> /dev/null |
            grep -vE '^[[:space:]]*(AGENT_REPO_SLUG|AGENT_BASE_BRANCH|AGENT_PROJECT_OWNER|AGENT_PROJECT_NUMBER|AGENT_STATUS_VOCAB|AGENT_ADR_DIR|AGENT_WORKTREE_ROOT)=' || true)
        if [[ -n $carried ]]; then
            printf '\n# Carried forward from the previous config: declarations this generator\n'
            printf '# does not produce and therefore must not discard.\n'
            printf '%s\n' "$carried"
        fi
    fi
} > "$staging/.agent/config.env"

# grep -c prints its count AND exits non-zero when that count is zero, so a
# `|| printf 0` fallback appended a SECOND zero -- "0\n0" -- and the arithmetic
# test below then failed with a syntax error on every bootstrap of a fresh
# repository. Guard on the input instead of the exit status.
carried_count=0
if [[ -n ${carried:-} ]]; then
    carried_count=$(grep -cE '^[[:space:]]*AGENT_' <<< "$carried" || true)
fi

# --- validate what we are about to write ------------------------------------
if [[ -x $resolver ]]; then
    if ! resolver_warnings=$("$resolver" --repo-root "$staging" --list 2>&1 > /dev/null); then
        die 'the resolver rejected the generated config.env'
    fi
    if [[ -n $resolver_warnings ]]; then
        warn "$resolver_warnings"
        die 'refusing to write a config.env its own resolver warns about'
    fi
fi
jq -e '.schemaVersion and .project.id and .statusField.id and
    (.statusField.options | length > 0)' < "$staging/.agent/board.json" > /dev/null ||
    die 'the generated board.json is incomplete'

# --- emit or install --------------------------------------------------------
if ((dry_run)); then
    printf -- '--- %s/.agent/config.env ---\n' "$repo_root"
    cat -- "$staging/.agent/config.env"
    printf -- '\n--- %s/.agent/board.json ---\n' "$repo_root"
    cat -- "$staging/.agent/board.json"
    printf '\ndry run: nothing written\n'
    exit 0
fi

if ((!force)); then
    for existing in config.env board.json; do
        [[ -e $repo_root/.agent/$existing ]] &&
            die ".agent/$existing already exists; pass --force to overwrite"
    done
fi

mkdir -p -- "$repo_root/.agent"
mv -- "$staging/.agent/config.env" "$repo_root/.agent/config.env"
mv -- "$staging/.agent/board.json" "$repo_root/.agent/board.json"

printf 'wrote %s/.agent/config.env\n' "$repo_root"
printf 'wrote %s/.agent/board.json  (project %s, %s status options)\n' \
    "$repo_root" "$project_num" "$option_count"
((carried_count == 0)) ||
    printf 'carried forward %s existing declaration(s); nothing was discarded\n' "$carried_count"

# Ignore rules are WRITTEN, not suggested.
#
# This printed "add to .gitignore: .agent/cache/" and left it at that, so a
# bootstrapped repository could reach steady state with no rule at all -- which
# is what happened in the first repository this was used on. And the suggested
# pattern was too narrow: it left env-contract.txt stageable, and that file
# carries the local home path, the CA bundle location, and the authenticated
# account name.
#
# An allowlist states the intent directly: everything under .agent/ is working
# state except the two declared files. With it in place, a blanket `git add`
# is simply correct, enforced by git for every tool and every human rather than
# by a guard that has to recognise a command shape.
readonly IGNORE_MARKER='# agentkit: .agent/ is working state; these two files are the declaration'
ignore_file="$repo_root/.gitignore"

if grep -qF "$IGNORE_MARKER" "$ignore_file" 2> /dev/null; then
    printf 'ignore rules already present in .gitignore\n'
elif {
    [[ ! -s $ignore_file ]] || printf '\n'
    printf '%s\n.agent/*\n!.agent/config.env\n!.agent/board.json\n' "$IGNORE_MARKER"
} >> "$ignore_file" 2> /dev/null; then
    printf 'added ignore rules to .gitignore\n'
else
    printf 'WARNING: could not write %s -- add these by hand:\n' "$ignore_file" >&2
    printf '  .agent/*\n  !.agent/config.env\n  !.agent/board.json\n' >&2
fi

# Having written the rule is not the same as the rule working, and only the
# second is worth reporting. A repository carried the allowlist in .gitignore
# and a broader `.agent/` in .git/info/exclude; git does not descend into an
# excluded DIRECTORY, so the negation was never reached. This script said
# "ignore rules already present" -- true of the text, false of the effect --
# and onboarding then failed at `git add`, in a different tool, one step later.
#
# --no-index is required: check-ignore stays silent about a tracked path
# otherwise, and these two files are normally tracked.
#
# The oracle is check-ignore WITHOUT -v: it lists only paths that are actually
# excluded. With -v it reports the last matching pattern even when that pattern
# is a negation, and exits 0 either way -- so a WORKING allowlist matches
# `!.agent/config.env` and looks identical to a broken one. Decide plainly,
# then re-ask with -v purely to name the rule.
if git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    if defeated=$(git -C "$repo_root" check-ignore --no-index -- \
        .agent/config.env .agent/board.json 2> /dev/null) && [[ -n $defeated ]]; then
        printf 'WARNING: the allowlist has no effect -- these files are still excluded:\n' >&2
        git -C "$repo_root" check-ignore --no-index -v -- \
            .agent/config.env .agent/board.json 2> /dev/null | sed 's/^/  /' >&2
        printf 'A rule ending in "/" excludes the directory itself, and git does not\n' >&2
        printf 'descend into an excluded directory, so "!.agent/config.env" is never\n' >&2
        printf 'reached. Narrow it (.agent/ -> .agent/*) in the file named above.\n' >&2
    fi
fi

# Files already in the index are not affected by an ignore rule. Report them
# rather than removing them: untracking is a history decision, not this
# script's call to make.
tracked=$(git -C "$repo_root" ls-files -- .agent 2> /dev/null |
    grep -vE '^\.agent/(config\.env|board\.json)$' || true)
if [[ -n $tracked ]]; then
    printf 'NOTE: already tracked despite the new rules -- untrack when convenient:\n' >&2
    printf '%s\n' "$tracked" | sed 's/^/  /' >&2
    printf '  git rm --cached <path>\n' >&2
fi

exit 0
