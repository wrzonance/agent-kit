#!/usr/bin/env bash
# bench/verify-config-env.sh -- prove bench/fixtures/tally/.agent/config.env
# is resolver-parseable at BOTH benchmark-arm SHAs (issue #325 acceptance
# criterion). Extracts agentkit/skills/.shared/scripts/repo-config.sh as it
# existed at each SHA (self-contained: it sources nothing) and runs it
# against the fixture's config.env, asserting every key the fixture sets
# actually resolves -- not just that the resolver exits 0 (exit 0 is also
# what happens when every key gets silently dropped).
set -euo pipefail

program=${0##*/}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
repo_root=$(cd -- "$script_dir/.." && pwd -P) || die 'could not resolve repo root'
config_file="$repo_root/bench/fixtures/tally/.agent/config.env"
[[ -f $config_file ]] || die "fixture config not found: $config_file"

tmp=$(mktemp -d) || die 'could not create temp directory'
trap 'rm -rf -- "$tmp"' EXIT

# Every key the fixture's config.env declares (see that file); checked
# against each arm's resolver output below.
declare -a expect_keys=(
    AGENT_REPO_SLUG AGENT_BASE_BRANCH AGENT_WORKTREE_ROOT
    AGENT_BRANCH_PREFIXES AGENT_LABEL_TYPES AGENT_LABEL_AREAS
    AGENT_LABEL_PRIORITIES AGENT_CMD_TEST
)

check_at() {
    local sha=$1 resolver="$tmp/repo-config-$1.sh"
    git -C "$repo_root" cat-file -e "${sha}:agentkit/skills/.shared/scripts/repo-config.sh" 2> /dev/null ||
        die "repo-config.sh does not exist at $sha"
    git -C "$repo_root" show "${sha}:agentkit/skills/.shared/scripts/repo-config.sh" > "$resolver" ||
        die "could not extract repo-config.sh at $sha"
    chmod +x -- "$resolver"

    local listing key
    listing=$("$resolver" --config-file "$config_file" --list 2>&1) ||
        die "repo-config.sh --list failed at $sha: $listing"

    for key in "${expect_keys[@]}"; do
        grep -q "^${key}=" <<< "$listing" ||
            die "key $key did not resolve at $sha (config.env not parseable as expected there); resolver output:"$'\n'"$listing"
    done
    printf 'verify-config-env: %s -- all %d keys resolve\n' "$sha" "${#expect_keys[@]}"
}

check_at 06d18cf
check_at 53e7e8c

printf 'PASS verify-config-env: bench/fixtures/tally/.agent/config.env is resolver-parseable at both arm SHAs\n'
