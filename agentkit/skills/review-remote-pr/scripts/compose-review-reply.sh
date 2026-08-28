#!/usr/bin/env bash
# Compose and transport the canonical automated-review reply.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
readonly SHA_RE='^[0-9a-fA-F]{7,64}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly LOGIN_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,38}(\[bot\])?$'

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
COMMENT_HELPER=${COMPOSE_REVIEW_COMMENT:-$SCRIPT_DIR/gh-comment.sh}
# shellcheck source=../../.shared/scripts/lib/review-provider-catalog.sh
source "$SCRIPT_DIR/../../.shared/scripts/lib/review-provider-catalog.sh"

pr=''
repo=''
provider=''
provider_login=''
reply_to=''
disposition=''
sha=''
reasoning_file=''
agent_identity=${COMPOSE_REVIEW_AGENT_IDENTITY:-'Codex gpt-5.6-luna'}
work_dir=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --pr N --repo OWNER/REPO --reply-to COMMENT_ID
       --provider coderabbit|github-code-quality|generic
       [--provider-login LOGIN] --disposition fixed|dismissed|deferred
       --sha SHA --reasoning-file FILE [--agent-identity ID]
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --) shift; break ;;
        --pr) (($# >= 2)) || usage; pr=$2; shift 2 ;;
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --provider) (($# >= 2)) || usage; provider=$2; shift 2 ;;
        --provider-login) (($# >= 2)) || usage; provider_login=$2; shift 2 ;;
        --reply-to) (($# >= 2)) || usage; reply_to=$2; shift 2 ;;
        --disposition) (($# >= 2)) || usage; disposition=$2; shift 2 ;;
        --sha) (($# >= 2)) || usage; sha=$2; shift 2 ;;
        --reasoning-file) (($# >= 2)) || usage; reasoning_file=$2; shift 2 ;;
        --agent-identity) (($# >= 2)) || usage; agent_identity=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $pr =~ $UINT_RE ]] || die '--pr must be a positive integer'
[[ $reply_to =~ $UINT_RE ]] || die '--reply-to must be a positive integer'
[[ $repo =~ $SLUG_RE ]] || die '--repo must have the form OWNER/REPO'
[[ $sha =~ $SHA_RE ]] || die '--sha must be 7-64 hexadecimal characters'
case $disposition in fixed|dismissed|deferred) ;; *) die 'unsupported disposition' ;; esac
[[ -f $reasoning_file && ! -L $reasoning_file && -O $reasoning_file ]] ||
    die '--reasoning-file must be an owned regular file, not a symlink'
[[ -s $reasoning_file ]] || die '--reasoning-file must not be empty'
[[ -n $agent_identity && $agent_identity != *$'\n'* && $agent_identity != *$'\r'* ]] ||
    die '--agent-identity must be one non-empty line'
[[ -x $COMMENT_HELPER ]] || die "comment transport is not executable: $COMMENT_HELPER"

case $provider in
    generic)
        [[ $provider_login =~ $LOGIN_RE ]] ||
            die 'generic --provider-login must be a safe authoritative bot login'
        provider_login=${provider_login%\[bot\]}
        ;;
    *)
        [[ -z $provider_login ]] || die '--provider-login is not allowed for a known provider'
        [[ $provider != none ]] || die 'disabled provider has no reply identity'
        provider_login=$(review_provider_login "$provider" 2>/dev/null) ||
            die 'unsupported provider'
        ;;
esac

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/compose-review-reply.XXXXXX") ||
    die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM
body_file=$work_dir/body.md

{
    printf '%s\n' 'This was written agentically; verify its assertions:'
    printf '<!-- review-remote-pr:agent-reply disposition=%s provider=%s -->\n' \
        "$disposition" "$provider"
    printf '@%s\n' "$provider_login"
    # shellcheck disable=SC2016 # Backticks are canonical Markdown delimiters.
    printf 'Commit: `%s`\n' "$sha"
    printf 'Disposition: %s\n' "$disposition"
    printf 'Reasoning: '
    cat -- "$reasoning_file"
    [[ $(tail -c 1 "$reasoning_file" | wc -l) -gt 0 ]] || printf '\n'
    printf '🤖 Co-authored by %s.\n' "$agent_identity"
} >"$body_file"

post_output=''
post_rc=0
post_output=$(bash "$COMMENT_HELPER" --pr "$pr" --repo "$repo" \
    --body-file "$body_file" --reply-to "$reply_to") || post_rc=$?
((post_rc == 0)) || die 'comment transport failed; reply settlement did not start'
[[ $post_output == *'verified=exact'* ]] ||
    die 'comment transport returned no verified=exact proof'

printf '%s\n' "$post_output"
printf 'provider=%s disposition=%s settlement=AWAITING_BOT_RESPONSE\n' \
    "$provider" "$disposition"
