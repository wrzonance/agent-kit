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
#   bootstrap-repo.sh [--repo-root DIR] [--project N] [--owner LOGIN]
#                     [--dry-run] [--force] [--refresh] [--reset]
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
    printf 'usage: %s [--repo-root DIR] [--project N] [--dry-run] [--force] [--refresh] [--reset]\n' "$PROGRAM" >&2
    exit 2
}

repo_root=''
project_number=''
# The owner of the BOARD, which is not always the owner of the repository: a
# personal repo can be tracked on an organization's board, and GitHub refuses to
# link those two together, so nothing can discover the pairing for you.
board_owner=''
dry_run=0
force=0
refresh=0
reset=0

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
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
        --owner)
            shift
            (($#)) || die_usage '--owner requires a login'
            board_owner=$1
            ;;
        --dry-run) dry_run=1 ;;
        --force) force=1 ;;
        --refresh) refresh=1; force=1 ;;
        --reset) reset=1; force=1 ;;
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

# --- trunk-carried declarations: refuse on trunk, before any network call --
# Repositories that COMMIT .agent/config.env / .agent/board.json (via a
# .gitignore negation, then `git add`) are the documented layout for
# worktree fleets and CI (onboard-repo Step 7): a per-machine, locally
# ignored file simply is not present in a fresh clone or a CI checkout. Ask
# git's index, not the ignore rules, since a negation can exist without
# anything having been committed under it yet.
config_tracked=0
if git -C "$repo_root" ls-files --error-unmatch -- .agent/config.env > /dev/null 2>&1; then
    config_tracked=1
fi
board_tracked=0
if git -C "$repo_root" ls-files --error-unmatch -- .agent/board.json > /dev/null 2>&1; then
    board_tracked=1
fi

if ((!dry_run)) && ((refresh || force)) && ((config_tracked || board_tracked)); then
    current_branch=$(git -C "$repo_root" symbolic-ref --short -q HEAD 2> /dev/null || true)

    # `refs/remotes/origin/HEAD` is only ever set by `git clone` (or an
    # explicit `git remote set-head`); it is routinely absent after
    # `init` + `remote add`, in many CI checkouts, and it can be pruned.
    # Falling back to a literal guess here would silently miss a non-`main`
    # trunk (e.g. `master`) and let a refresh patch tracked declarations
    # directly on trunk -- the exact outcome this guard exists to prevent.
    # Stay network-free (this check deliberately runs before the gh
    # preflight): prefer the local remote-HEAD ref, then the repository's
    # OWN declared AGENT_BASE_BRANCH -- a tracked config.env exists by
    # definition whenever config_tracked is set. If neither is available,
    # refuse rather than guess: proceeding on an unproven trunk name risks
    # writing to trunk itself, which is the destructive direction.
    trunk_branch=$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2> /dev/null |
        sed 's|^origin/||' || true)
    if [[ -z $trunk_branch && -r $repo_root/.agent/config.env ]]; then
        trunk_branch=$(sed -nE 's/^[[:space:]]*AGENT_BASE_BRANCH=[[:space:]]*(.*)$/\1/p' \
            "$repo_root/.agent/config.env" 2> /dev/null | tail -1)
    fi
    if [[ -z $trunk_branch ]]; then
        die "could not determine the trunk branch for $repo_root to check the trunk-carried refresh guard

No local refs/remotes/origin/HEAD and no AGENT_BASE_BRANCH declaration were
found. Guessing here risks patching trunk-carried .agent declarations
directly on trunk, so refusing instead. Set the remote HEAD
(git remote set-head origin -a) or declare AGENT_BASE_BRANCH in
.agent/config.env, then re-run. Nothing was written."
    fi
    if [[ -z $current_branch || $current_branch == "$trunk_branch" ]]; then
        die "refusing to refresh trunk-carried .agent declarations on ${current_branch:-a detached HEAD} (trunk: $trunk_branch)

This repository commits .agent/config.env and/or .agent/board.json -- the
documented layout for worktree fleets and CI (onboard-repo Step 7). The
trunk-carried refresh path (neither --refresh nor --force runs it against
trunk) patches only the drifted generator-owned keys in the working tree,
prints the diff, and leaves commit/PR to the onboarding flow. Check out a
non-trunk branch and re-run:
  $PROGRAM --refresh --repo-root $repo_root
Nothing was written."
    fi
fi

# --- preflight: environment-blocked is exit 3, not a failure ---------------
# This runs before ANY external command, including the coreutils used to locate
# the resolver below. Otherwise a stripped PATH dies at 127 on `dirname` and
# reports a missing-command error instead of the honest "gh is not installed".
for tool in gh jq dirname readlink sha256sum date mktemp diff; do
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

# secure_mkdir_p (issue #474): guarded like the plugin-manifest lookup below --
# a copy of this script run without its lib/ sibling (an install layout that
# resolves nothing outside the single file) still runs, falling back to a
# plain `mkdir -p` at the call site instead of dying on a missing source.
SECURE_MKDIR_LIB="$self_dir/lib/secure-mkdir.sh"
if [[ -r $SECURE_MKDIR_LIB ]]; then
    # shellcheck disable=SC1090,SC1091  # sibling library is resolved at runtime
    source "$SECURE_MKDIR_LIB"
fi

generator_version=$(jq -r '.version // empty' "$self_dir/../../..//.codex-plugin/plugin.json" 2> /dev/null || true)
generator_stamp=''
[[ -n $generator_version ]] && generator_stamp="agentkit/$generator_version"

# Discovery above fails softly -- no jq, an unreadable or malformed plugin.json,
# an install layout this relative path does not resolve in. AGENT_ONBOARDED_BY is
# generator-owned, so the carry-forward filter further down deliberately drops the
# previous one; with no replacement to emit, a refresh would erase the only
# provenance record and make generator drift permanently undetectable -- the exact
# condition the stamp exists to detect. Keep the old value when we have nothing
# better. --reset is the one case that intends to forget it.
if [[ -z $generator_stamp && $reset -eq 0 && -r $repo_root/.agent/config.env ]]; then
    generator_stamp=$(sed -nE 's/^[[:space:]]*AGENT_ONBOARDED_BY=[[:space:]]*(.*)$/\1/p' \
        "$repo_root/.agent/config.env" 2> /dev/null | tail -1)
fi

if ((refresh)) && [[ -r $repo_root/.agent/config.env && -x $self_dir/onboard-refresh.sh ]]; then
    "$self_dir/onboard-refresh.sh" --repo-root "$repo_root" --report 2> /dev/null || true
fi

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

projects_linked=1
projects_source='linked to this repository'
projects_json='{"projects":[]}'
if [[ -z $board_owner ]]; then
    projects_json=$(gh api graphql -F "owner=$owner" -F "name=$name" -f "query=$LINKED_QUERY" 2> /dev/null |
        jq -c '{projects: (.data.repository.projectsV2.nodes // [])}' 2> /dev/null ||
        printf '{"projects":[]}')
fi

if [[ $(jq '.projects | length' <<< "$projects_json" 2> /dev/null || printf 0) -eq 0 ]]; then
    # Not linked to anything, or the query failed: fall back to the owner's
    # boards. This is a REAL loss of evidence and is treated as one below --
    # "this owner has a board" is not "this board is this repository's".
    projects_linked=0
    list_owner=${board_owner:-$owner}
    projects_source="owned by $list_owner"
    projects_json=$(gh project list --owner "$list_owner" --format json 2> /dev/null) ||
        die "could not list projects for $list_owner"
fi

if [[ -n $project_number ]]; then
    project=$(jq -c --argjson n "$project_number" \
        'first(.projects[]? | select(.number == $n)) // empty' <<< "$projects_json")
    [[ -n $project ]] || die "owner $owner has no project number $project_number"
else
    open_count=$(jq '[.projects[]? | select(.closed != true)] | length' <<< "$projects_json")
    # An UNLINKED board is never adopted silently, however few there are.
    #
    # The single-candidate shortcut used to skip this: a personal repository
    # whose owner had exactly one board took that board, and the board was an
    # unrelated homelab project holding someone else's in-flight issue. Its ids
    # would have gone into a committed board.json, and the next lifecycle move
    # would have mutated it. The session that hit this only noticed because the
    # columns happened to be wrong.
    #
    # "This owner has one board" is not evidence that the board belongs to this
    # repository. Only the link is, and cross-owner GitHub refuses to create one
    # at all -- so for those the answer has to be typed.
    if ((projects_linked == 0)); then
        warn "no board is LINKED to $slug; found $open_count open project(s) $projects_source:"
        jq -r '.projects[]? | select(.closed != true) | "  \(.number)  \(.title)"' \
            <<< "$projects_json" >&2
        warn 'a board this repository is not linked to has to be named explicitly:'
        warn "  $PROGRAM --project N${board_owner:+ --owner $board_owner}"
        die 'refusing to adopt an unlinked board'
    fi
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
fields_json=$(gh project field-list "$project_num" --owner "${board_owner:-$owner}" --format json 2> /dev/null) ||
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

# The BOARD's owner. board-list.sh and the mover pass this to gh as --owner, so
# a repo tracked on another account's board needs that account here, not its own.
jq -n \
    --argjson v "$BOARD_SCHEMA_VERSION" \
    --arg owner "${board_owner:-$owner}" \
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

proposal_inventory=''
if [[ -x $self_dir/onboard-refresh.sh ]]; then
    # `|| true` would keep whatever the command printed before it died, and a
    # half-written inventory becomes the recorded baseline that later drift is
    # measured against. Take the status separately and keep only a clean run.
    if ! proposal_inventory=$("$self_dir/onboard-refresh.sh" --repo-root "$repo_root" --inventory 2> /dev/null); then
        proposal_inventory=''
    fi
fi

adr_dir=''
for candidate in docs/adr docs/adrs docs/decisions docs/architecture/decisions adr doc/adr; do
    if [[ -d $repo_root/$candidate ]]; then
        adr_dir=$candidate
        break
    fi
done

# Provider selection is a maintainer decision, not something bootstrap can
# infer from the forge. Keep the proposal visible until a valid declaration is
# selected; a carried declaration then appears once as active config below.
review_providers_declared=0
if [[ -f $repo_root/.agent/config.env && $reset -eq 0 ]]; then
    if grep -qE '^[[:space:]]*AGENT_REVIEW_PROVIDERS=(coderabbit|github-code-quality|none|coderabbit,github-code-quality|github-code-quality,coderabbit)[[:space:]]*$' \
        "$repo_root/.agent/config.env" 2> /dev/null; then
        review_providers_declared=1
    fi
fi

# Same "propose once, then defer to the maintainer's choice" treatment as
# review providers -- but unlike that raw-grep check, this one goes through
# the resolver: a raw grep on `AGENT_WORKER_MODEL(_FALLBACK)?=` would count a
# malformed value (whitespace-bearing, a command-substitution string) as
# "declared" and wrongly suppress the proposal, even though repo-config.sh
# itself rejects and drops that value. A syntactically safe but UNSUPPORTED
# model id (e.g. a custom provider name) is not malformed -- the resolver
# still resolves it, so it still counts as declared; only a value the
# resolver actually drops does not.
worker_model_declared=0
if [[ -f $repo_root/.agent/config.env && $reset -eq 0 && -x $resolver ]]; then
    if "$resolver" --repo-root "$repo_root" --get AGENT_WORKER_MODEL > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_WORKER_MODEL_FALLBACK > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_WORKER_MODELS > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_WORKER_MODELS_FALLBACK > /dev/null 2>&1; then
        worker_model_declared=1
    fi
fi

# Same treatment, for the adversarial reviewer: propose it once, then defer to
# the maintainer's choice. The peer-CLI default stays correct with nothing
# declared, so this is a discoverability nudge, not a required key.
adversarial_reviewer_declared=0
if [[ -f $repo_root/.agent/config.env && $reset -eq 0 && -x $resolver ]]; then
    if "$resolver" --repo-root "$repo_root" --get AGENT_ADVERSARIAL_REVIEWER > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_ADVERSARIAL_REVIEWER_FALLBACK > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_ADVERSARIAL_REVIEW_MODEL > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK > /dev/null 2>&1 ||
        "$resolver" --repo-root "$repo_root" --get AGENT_ADVERSARIAL_REVIEW_EFFORT > /dev/null 2>&1; then
        adversarial_reviewer_declared=1
    fi
fi

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
    [[ -n $generator_stamp ]] && printf 'AGENT_ONBOARDED_BY=%s\n' "$generator_stamp"
    if [[ -n $labels ]]; then
        printf '\n# This repository'"'"'s labels, for you to split by intent. Uncomment and\n'
        printf '# classify the ones agents should reuse instead of inventing new labels.\n'
        printf '#   %s\n' "$labels"
        printf '# AGENT_LABEL_TYPES=\n# AGENT_LABEL_AREAS=\n# AGENT_LABEL_PRIORITIES=\n'
    fi
    if [[ -n $suggestions ]]; then
        printf '\n# Candidate verify commands found in this repository. Uncomment the ones\n'
        printf '# agents should run, as AGENT_CMD_<NAME>=<command>. Commands are argv;\n'
        printf '# quote spaces inside one token. No shell, pipes, or redirects.\n'
        printf '# For anything more, use .agent/runner.\n'
        printf '%s\n' "$suggestions"
        printf '# AGENT_CMD_VERIFY=\n# AGENT_CMD_TEST=\n# AGENT_CMD_LINT=\n'
    fi
    if ((worker_model_declared == 0)); then
        printf '\n# Worker model/effort for dispatched implementation workers. Declare the\n'
        printf '# TIER, not a fixed provider model: the resolver reads harness= from the\n'
        printf '# environment contract and maps it to that harness'"'"'s own native worker\n'
        printf '# tier, so the same declaration dispatches correctly whichever harness is\n'
        printf '# actually running (e.g. gpt-5.6-luna on Codex, claude-sonnet-5 elsewhere).\n'
        printf '# AGENT_WORKER_EFFORT (e.g. high) is harness-neutral and applies to any of them.\n'
        printf '# Prefer the harness-neutral roster form instead: AGENT_WORKER_MODELS /\n'
        printf '# AGENT_WORKER_MODELS_FALLBACK take a comma-separated candidate per harness\n'
        printf '# family (e.g. claude-sonnet-5,gpt-5.6-luna); each worker self-detects the\n'
        printf '# running harness and picks its own entry. It takes precedence over the\n'
        printf '# singular keys below when both are declared.\n'
        printf '# AGENT_WORKER_MODELS=\n# AGENT_WORKER_MODELS_FALLBACK=\n'
        printf '# AGENT_WORKER_MODEL=\n# AGENT_WORKER_MODEL_FALLBACK=\n# AGENT_WORKER_EFFORT=\n'
    fi
    if ((adversarial_reviewer_declared == 0)); then
        printf '\n# Adversarial reviewer for pull requests (the single most expensive\n'
        printf '# deliberate spend in a run). Default: the peer-cli= CLI from the environment\n'
        printf '# contract, its strongest reasoning model. Declare AGENT_ADVERSARIAL_REVIEWER\n'
        printf '# (codex or claude) to override which CLI reviews; AGENT_ADVERSARIAL_REVIEW_MODEL\n'
        printf '# names its model, AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK the model used if that\n'
        printf '# CLI is absent on the machine (falls back to the running harness, never silently).\n'
        printf '# AGENT_ADVERSARIAL_REVIEW_EFFORT (low/medium/high/xhigh/max) is harness-neutral.\n'
        printf '# AGENT_ADVERSARIAL_REVIEWER also accepts a roster <model-id>-<effort> compound\n'
        printf '# (e.g. gpt-5.6-sol-xhigh); pair it with AGENT_ADVERSARIAL_REVIEWER_FALLBACK for\n'
        printf '# the second candidate. The candidate belonging to a family other than the\n'
        printf '# running harness is preferred, self-detected the same way as the worker roster.\n'
        printf '# AGENT_ADVERSARIAL_REVIEWER=\n# AGENT_ADVERSARIAL_REVIEWER_FALLBACK=\n'
        printf '# AGENT_ADVERSARIAL_REVIEW_MODEL=\n'
        printf '# AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK=\n# AGENT_ADVERSARIAL_REVIEW_EFFORT=\n'
    fi
    if ((review_providers_declared == 0)); then
        printf '\n# Automated review providers expected on pull requests. Choose one or more.\n'
        printf '# Supported choices: coderabbit, github-code-quality, or none (none is exclusive).\n'
        printf '# AGENT_REVIEW_PROVIDERS=\n'
    fi
    if [[ -n $proposal_inventory ]]; then
        printf '\n# Recorded proposal inventory. These lines are observations only; they\n'
        printf '# never declare or execute a command. Refresh replaces this block.\n'
        printf '%s\n' "$proposal_inventory"
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
    if [[ -f $repo_root/.agent/config.env && $reset -eq 0 ]]; then
        carried=$(grep -E '^[[:space:]]*AGENT_[A-Z0-9_]+=' "$repo_root/.agent/config.env" 2> /dev/null |
            grep -vE '^[[:space:]]*(AGENT_REPO_SLUG|AGENT_BASE_BRANCH|AGENT_PROJECT_OWNER|AGENT_PROJECT_NUMBER|AGENT_STATUS_VOCAB|AGENT_ADR_DIR|AGENT_WORKTREE_ROOT|AGENT_ONBOARDED_BY)=' || true)
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
    # The config is staged, but path-shaped declarations belong to the target
    # checkout. Validating against the temporary directory mislabels a real
    # executable as missing and made re-onboarding destroy useful declarations.
    if ! resolver_warnings=$("$resolver" --repo-root "$repo_root" \
        --config-file "$staging/.agent/config.env" --list 2>&1 > /dev/null); then
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

# Declarations are per-machine state. Keep the blanket rule in the repository's
# local exclude rather than creating tracked .gitignore exceptions: a fresh
# clone can regenerate both files without dirtying the checkout on every board
# move. The marker makes the generated local rule identifiable and idempotent.
readonly IGNORE_MARKER='# agentkit: .agent/ is per-machine working state; onboarding owns this local rule'
readonly IGNORE_RULE='.agent/*'
ignore_file=''
if git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    ignore_file=$(git -C "$repo_root" rev-parse --git-path info/exclude 2> /dev/null || true)
    if [[ -n $ignore_file && $ignore_file != /* ]]; then
        ignore_file=$repo_root/$ignore_file
    fi
fi

ensure_local_ignore() {
    [[ -n $ignore_file ]] || return 0
    local parent
    parent=$(dirname -- "$ignore_file")
    mkdir -p -- "$parent" || die "could not create git exclude directory: $parent"
    [[ -e $ignore_file ]] || : > "$ignore_file" ||
        die "could not create local git exclude: $ignore_file"

    # Migrate the old directory spelling in local state to the explicit
    # contents rule, which is equivalent for this fully-ignored model and does
    # not rely on negation exceptions.
    if grep -qE '^[[:space:]]*\.agent/[[:space:]]*$' "$ignore_file" 2> /dev/null; then
        sed -i -E 's|^[[:space:]]*\.agent/[[:space:]]*$|.agent/*|' "$ignore_file" ||
            die "could not update local git exclude: $ignore_file"
    fi
    if ! grep -Fxq "$IGNORE_RULE" "$ignore_file" 2> /dev/null; then
        {
            [[ ! -s $ignore_file ]] || printf '\n'
            printf '%s\n%s\n' "$IGNORE_MARKER" "$IGNORE_RULE"
        } >> "$ignore_file" || die "could not update local git exclude: $ignore_file"
    elif ! grep -Fxq "$IGNORE_MARKER" "$ignore_file" 2> /dev/null; then
        printf '%s\n' "$IGNORE_MARKER" >> "$ignore_file" ||
            die "could not update local git exclude: $ignore_file"
    fi
}

if ((dry_run)); then
    printf 'local ignore: %s (%s)\n' "${ignore_file:-unavailable}" "$IGNORE_RULE"
fi

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
        [[ -e $repo_root/.agent/$existing ]] || continue
        if { [[ $existing == config.env ]] && ((config_tracked)); } ||
            { [[ $existing == board.json ]] && ((board_tracked)); }; then
            die ".agent/$existing already exists and is tracked (trunk-carried layout); pass --refresh or --force on a non-trunk branch to patch its drifted generator-owned keys in place -- neither flag discards a declaration on a tracked file, matching how --force already treats an untracked config.env"
        fi
        die ".agent/$existing already exists; pass --force to overwrite"
    done
fi

if ((reset)); then
    archive_dir=$repo_root/.agent/archive
    archive_stamp=$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p -- "$archive_dir" || die "could not create archive directory: $archive_dir"
    archived=0
    for existing in config.env board.json; do
        source_path=$repo_root/.agent/$existing
        [[ -e $source_path ]] || continue
        target_path=$archive_dir/${existing}.${archive_stamp}
        # A timestamp collision is unlikely but must not overwrite an earlier
        # reset when two invocations happen within one second.
        suffix=0
        while [[ -e $target_path ]]; do
            suffix=$((suffix + 1))
            target_path=$archive_dir/${existing}.${archive_stamp}.${suffix}
        done
        mv -- "$source_path" "$target_path" || die "could not archive $source_path"
        archived=$((archived + 1))
        printf 'reset: archived %s -> %s\n' "$source_path" "$target_path"
    done
    printf 'reset: archived %s existing declaration file(s); regenerated below\n' "$archived"
fi

assert_effective_ignore() {
    local committed_path details
    git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1 || return 0
    for committed_path in "$@"; do
        if ! git -C "$repo_root" check-ignore --no-index -- "$committed_path" > /dev/null 2>&1; then
            details=$(git -C "$repo_root" check-ignore --no-index -v -- \
                "$committed_path" 2> /dev/null || true)
            printf 'ignore rule does not exclude %s:\n' "$repo_root/$committed_path" >&2
            [[ -n $details ]] && printf '  %s\n' "$details" >&2
            printf 'Remove legacy .gitignore negations for .agent/config.env and .agent/board.json;\n' >&2
            die "onboarding cannot establish local ignore for $repo_root/$committed_path; remove the negation"
        fi
    done
}

# --- trunk-carried patch: touch only generator-owned keys, byte-for-byte ---
# A committed config.env (the documented layout above) gets its EXISTING file
# line-patched in place, never regenerated from scratch, so maintainer
# comments, ordering, and every declaration this generator does not own
# survive untouched -- called for BOTH --refresh and --force on a tracked
# file: --force never discarded a declared key even for an untracked
# config.env ("--force regenerates DISCOVERED facts; it must not throw away
# DECLARED ones", below), so a tracked file gets the same guarantee, not a
# blind overwrite. Only the keys "everything above is rediscoverable from
# the forge" owns -- the same list the carry-forward filter protects -- are
# eligible; provider/label/command declarations are a maintainer decision
# this script has never touched and still does not.
# shellcheck disable=SC2016  # single-quoted on purpose: a plain word list, not expansion
readonly GENERATOR_OWNED_KEYS='AGENT_REPO_SLUG AGENT_BASE_BRANCH AGENT_PROJECT_OWNER AGENT_PROJECT_NUMBER AGENT_STATUS_VOCAB AGENT_ADR_DIR AGENT_WORKTREE_ROOT AGENT_ONBOARDED_BY'

patch_tracked_config() {
    local target=$1 fresh=$2
    local key val patched updated=0 unchanged=0
    declare -A new_val=()
    # shellcheck disable=SC2086  # GENERATOR_OWNED_KEYS is a deliberate word list
    for key in $GENERATOR_OWNED_KEYS; do
        val=$(sed -nE "s/^${key}=//p" "$fresh" | tail -n 1)
        [[ -n $val ]] && new_val[$key]=$val
    done

    if [[ ! -e $target ]]; then
        # --reset archived the prior working-tree copy away; there is nothing
        # left to patch, so this is a first write, same as the untracked path.
        cp -- "$fresh" "$target"
        printf 'wrote %s (no prior working-tree copy to patch)\n' "$target"
        return 0
    fi

    patched=$(mktemp "$staging/config-patched.XXXXXX")
    declare -A seen=()
    local line matched_key value_here
    while IFS= read -r line || [[ -n $line ]]; do
        matched_key=''
        for key in "${!new_val[@]}"; do
            if [[ $line == "$key="* ]]; then
                matched_key=$key
                break
            fi
        done
        if [[ -n $matched_key ]]; then
            seen[$matched_key]=1
            value_here=${line#"$matched_key"=}
            if [[ $value_here == "${new_val[$matched_key]}" ]]; then
                printf '%s\n' "$line" >> "$patched"
                unchanged=$((unchanged + 1))
            else
                printf '%s=%s\n' "$matched_key" "${new_val[$matched_key]}" >> "$patched"
                updated=$((updated + 1))
            fi
        else
            printf '%s\n' "$line" >> "$patched"
        fi
    done < "$target"
    for key in "${!new_val[@]}"; do
        [[ -n ${seen[$key]:-} ]] && continue
        printf '%s=%s\n' "$key" "${new_val[$key]}" >> "$patched"
        updated=$((updated + 1))
    done

    if ((updated == 0)); then
        rm -f -- "$patched"
        printf 'no drift: %s already matches the discovered generator-owned keys\n' "$target"
        return 0
    fi

    printf -- '--- %s (trunk-carried refresh) ---\n' "$target"
    diff -u -- "$target" "$patched" || true
    mv -- "$patched" "$target"
    printf 'refreshed %s (trunk-carried): %d key(s) updated, %d unchanged\n' \
        "$target" "$updated" "$unchanged"
}

# board.json is fully generator-owned (no maintainer free-form content), so
# unlike config.env there is no line-level merge to do: only whether the
# discovered document actually changed, ignoring the always-different
# generatedAt timestamp so an unchanged board never churns the working tree.
patch_tracked_board() {
    local target=$1 fresh=$2 old_norm fresh_norm
    if [[ ! -e $target ]]; then
        cp -- "$fresh" "$target"
        printf 'wrote %s (no prior working-tree copy to patch)\n' "$target"
        return 0
    fi
    old_norm=$(jq -S 'del(.generatedAt)' -- "$target" 2> /dev/null) || old_norm=''
    fresh_norm=$(jq -S 'del(.generatedAt)' -- "$fresh")
    if [[ $old_norm == "$fresh_norm" ]]; then
        printf 'no drift: %s already matches the discovered board\n' "$target"
        return 0
    fi
    printf -- '--- %s (trunk-carried refresh) ---\n' "$target"
    diff -u -- "$target" "$fresh" || true
    cp -- "$fresh" "$target"
    printf 'refreshed %s (trunk-carried)\n' "$target"
}

# Install the local rule only after every no-force/archive guard has passed,
# then prove Git's effective oracle before creating or moving declarations.
# A tracked config.env/board.json (the trunk-carried layout above) is
# deliberately excluded from both checks: it is not meant to be ignored, and
# it is patched in place below instead of installed.
ensure_local_ignore
ignore_check_paths=()
((config_tracked)) || ignore_check_paths+=(.agent/config.env)
((board_tracked)) || ignore_check_paths+=(.agent/board.json)
((${#ignore_check_paths[@]} == 0)) || assert_effective_ignore "${ignore_check_paths[@]}"
if command -v secure_mkdir_p > /dev/null 2>&1; then
    secure_mkdir_p "$repo_root/.agent" || die "could not create $repo_root/.agent"
else
    mkdir -p -- "$repo_root/.agent" || die "could not create $repo_root/.agent"
fi

if ((config_tracked)); then
    patch_tracked_config "$repo_root/.agent/config.env" "$staging/.agent/config.env"
else
    mv -- "$staging/.agent/config.env" "$repo_root/.agent/config.env"
    printf 'wrote %s/.agent/config.env\n' "$repo_root"
fi

if ((board_tracked)); then
    patch_tracked_board "$repo_root/.agent/board.json" "$staging/.agent/board.json"
else
    mv -- "$staging/.agent/board.json" "$repo_root/.agent/board.json"
    printf 'wrote %s/.agent/board.json  (project %s, %s status options)\n' \
        "$repo_root" "$project_num" "$option_count"
fi

((carried_count == 0)) ||
    printf 'carried forward %s existing declaration(s); nothing was discarded\n' "$carried_count"
# shellcheck disable=SC2016  # emitted text is literal command syntax
printf 'next step: agentkit=$(sed -n '\''s/^skills= path=//p'\'' "%s/.agent/env-contract.txt" | head -n 1); "$agentkit/.shared/scripts/onboard-state.sh" --repo-root "%s" --report\n' \
    "$repo_root" "$repo_root"

# The declarations must be ignored in the working tree, except a trunk-carried
# file this run just patched in place. --no-index is required so this remains
# a useful invariant for repositories migrating from tracked declarations;
# the tracked-state note below tells the operator to untrack any OTHER stray
# file.
if git -C "$repo_root" rev-parse --is-inside-work-tree > /dev/null 2>&1; then
    ((${#ignore_check_paths[@]} == 0)) || assert_effective_ignore "${ignore_check_paths[@]}"
fi

tracked_declarations=$(git -C "$repo_root" ls-files -- \
    .agent/config.env .agent/board.json 2> /dev/null || true)
((config_tracked)) && tracked_declarations=$(grep -vFx '.agent/config.env' <<< "$tracked_declarations" || true)
((board_tracked)) && tracked_declarations=$(grep -vFx '.agent/board.json' <<< "$tracked_declarations" || true)
if [[ -n $tracked_declarations ]]; then
    printf 'NOTE: declaration files are tracked despite the local rules; untrack when convenient:\n' >&2
    printf '%s\n' "$tracked_declarations" | sed 's/^/  /' >&2
    printf '  git rm --cached .agent/config.env .agent/board.json\n' >&2
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
