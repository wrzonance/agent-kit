#!/usr/bin/env bash
# Post canonical bot replies and settle them only after a fresh bot response.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly UINT_RE='^[1-9][0-9]*$'
readonly SHA_RE='^[0-9a-fA-F]{7,64}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly AGENT_MARKER='<!-- review-remote-pr:agent-reply '

SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
GH_BIN=${THREAD_ACTION_GH:-gh}
COMMENT_HELPER=${THREAD_ACTION_COMMENT:-$SCRIPT_DIR/gh-comment.sh}
COMPOSER=${THREAD_ACTION_COMPOSER:-$SCRIPT_DIR/compose-review-reply.sh}
# shellcheck source=../../.shared/scripts/lib/review-provider-catalog.sh
source "$SCRIPT_DIR/../../.shared/scripts/lib/review-provider-catalog.sh"

pr=''
repo=''
artifact=''
thread_id=''
comment_id=''
settle=0
disposition=''
reasoning_file=''
sha=''
agent_identity=${THREAD_ACTION_AGENT_IDENTITY:-'Codex gpt-5.6-luna'}
work_dir=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --pr N --repo OWNER/REPO --threads-artifact FILE
       (--thread-id ID | --comment-id N)
       [--settle | --disposition fixed|dismissed|deferred
        --reasoning-file FILE --sha SHA [--agent-identity ID]]
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --pr) (($# >= 2)) || usage; pr=$2; shift 2 ;;
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --threads-artifact|--artifact) (($# >= 2)) || usage; artifact=$2; shift 2 ;;
        --thread-id) (($# >= 2)) || usage; thread_id=$2; shift 2 ;;
        --comment-id) (($# >= 2)) || usage; comment_id=$2; shift 2 ;;
        --settle) settle=1; shift ;;
        --disposition) (($# >= 2)) || usage; disposition=$2; shift 2 ;;
        --reasoning-file) (($# >= 2)) || usage; reasoning_file=$2; shift 2 ;;
        --sha) (($# >= 2)) || usage; sha=$2; shift 2 ;;
        --agent-identity) (($# >= 2)) || usage; agent_identity=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $pr =~ $UINT_RE ]] || die '--pr must be a positive integer'
[[ $repo =~ $SLUG_RE ]] || die '--repo must have the form OWNER/REPO'
[[ -n $thread_id || -n $comment_id ]] || die '--thread-id or --comment-id is required'
[[ -z $comment_id || $comment_id =~ $UINT_RE ]] || die '--comment-id must be a positive integer'
[[ -f $artifact && ! -L $artifact && -O $artifact ]] ||
    die '--threads-artifact must be an owned regular file, not a symlink'
command -v jq >/dev/null 2>&1 || die 'jq is required; settlement evidence unavailable'
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"

if ((settle)); then
    [[ -z $disposition && -z $reasoning_file && -z $sha ]] ||
        die '--settle cannot be combined with reply composition options'
else
    case $disposition in fixed|dismissed|deferred) ;; *) die 'unsupported disposition' ;; esac
    [[ $sha =~ $SHA_RE ]] || die '--sha must be 7-64 hexadecimal characters'
    [[ -f $reasoning_file && ! -L $reasoning_file && -O $reasoning_file ]] ||
        die '--reasoning-file must be an owned regular file, not a symlink'
    [[ -x $COMPOSER ]] || die "canonical reply composer is not executable: $COMPOSER"
    [[ -x $COMMENT_HELPER ]] || die "comment transport is not executable: $COMMENT_HELPER"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/thread-action.XXXXXX") ||
    die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

jq -e '.data.repository.pullRequest.reviewThreads.nodes | type == "array"' \
    "$artifact" >/dev/null 2>&1 || die 'artifact has no reviewThreads.nodes array'

# The artifact's identity is never implicit: an evidence file gathered for a
# different PR or repo must never settle or reply to this one.
artifact_repo=$(jq -er '.data.repository.nameWithOwner | select(type == "string" and length > 0)' \
    "$artifact" 2>/dev/null) || die 'artifact has no repository.nameWithOwner identity'
artifact_pr=$(jq -er '.data.repository.pullRequest.number | select(type == "number" and . > 0)' \
    "$artifact" 2>/dev/null) || die 'artifact has no pull request number identity'
[[ $artifact_repo == "$repo" ]] || die 'artifact repository does not match --repo'
[[ $artifact_pr == "$pr" ]] || die 'artifact pull request number does not match --pr'

# A first(100) page that is not actually complete is partial evidence: never
# settle or reply from a thread list (or a thread's own comments) that GitHub
# reports as truncated.
jq -e '(.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage // false) == false' \
    "$artifact" >/dev/null 2>&1 ||
    die 'artifact is truncated; refusing settlement from partial evidence'

count=$(jq -r --arg thread "$thread_id" --arg comment "$comment_id" '
  [.data.repository.pullRequest.reviewThreads.nodes[] |
   select((($thread == "") or ((.id // "") | tostring == $thread)) and
          (($comment == "") or
           any(.comments.nodes[]?; ((.databaseId // "") | tostring) == $comment)))] |
  length
' "$artifact") || die 'could not inspect threads artifact'
[[ $count == 1 ]] || die 'selector does not identify exactly one artifact thread'
jq -c --arg thread "$thread_id" --arg comment "$comment_id" '
  [.data.repository.pullRequest.reviewThreads.nodes[] |
   select((($thread == "") or ((.id // "") | tostring == $thread)) and
          (($comment == "") or
           any(.comments.nodes[]?; ((.databaseId // "") | tostring) == $comment)))] | .[0]
' "$artifact" >"$work_dir/target.json"
target_thread=$(jq -er '.id | select(type == "string" and length > 0)' "$work_dir/target.json") ||
    die 'selected thread has no node ID'

jq -e '(.comments.pageInfo.hasNextPage // false) == false' "$work_dir/target.json" >/dev/null 2>&1 ||
    die 'artifact is truncated; refusing settlement from partial evidence'

if jq -e '.isResolved == true' "$work_dir/target.json" >/dev/null; then
    if ((settle)); then
        printf 'thread=%s settlement=SETTLED already-resolved=true\n' "$target_thread"
        exit 0
    fi
    die 'target thread is already resolved'
fi

original_login=$(jq -r '.comments.nodes[0].author.login // "" | ascii_downcase' \
    "$work_dir/target.json")
original_type=$(jq -r '.comments.nodes[0].author.__typename // .comments.nodes[0].author.type // ""' \
    "$work_dir/target.json")
if provider=$(review_provider_from_login "$original_login" 2>/dev/null); then
    :
elif [[ $original_login == *'[bot]' || $original_type == Bot ]]; then
    provider=generic
else
    provider=human
fi

# An agent marker identifies only that individual comment -- and only when
# posted by the authenticated workflow account. A human quoting the marker
# does not get to exempt their own comment from the human-touched gate.
workflow_login=$("$GH_BIN" api user 2>"$work_dir/api.err" | jq -er '.login | select(type == "string" and length > 0)' 2>/dev/null) ||
    die "authenticated workflow identity unavailable: $(head -n 1 "$work_dir/api.err" 2>/dev/null)"

human_count=$(jq -r --arg marker "$AGENT_MARKER" --arg login "$workflow_login" '
  [.comments.nodes[]? | select(
    ((((.body // "") | contains($marker)) and
      (((.author.login // "") | ascii_downcase) == ($login | ascii_downcase))) | not) and
    (((.author.login // "") | ascii_downcase) as $c_login |
      (($c_login == "coderabbitai") or ($c_login == "coderabbitai[bot]") or
       ($c_login == "github-code-quality") or ($c_login == "github-code-quality[bot]") or
       (($c_login | test("\\[bot\\]$"))) or
       ((.author.__typename // .author.type // "") == "Bot")) | not)
  )] | length
' "$work_dir/target.json") || die 'could not classify thread authors'
((human_count == 0)) || die 'target thread is human-touched; refusing automated handling'
[[ $provider != human ]] || die 'target thread is human-authored'

resolve_thread() {
    local query response
    # shellcheck disable=SC2016 # GraphQL variables are literal API syntax.
    query='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{isResolved}}}'
    response=$("$GH_BIN" api graphql -F "threadId=$target_thread" -f "query=$query") ||
        die 'resolveReviewThread failed after settlement'
    jq -e '.data.resolveReviewThread.thread.isResolved == true' <<<"$response" >/dev/null ||
        die 'resolveReviewThread did not prove isResolved=true'
}

if ((settle)); then
    # The marker alone is forgeable: only a marker posted by the authenticated
    # workflow account counts as the canonical agent reply that settlement
    # evidence is measured from.
    marker_index=$(jq -r --arg marker "$AGENT_MARKER" --arg login "$workflow_login" '
      [.comments.nodes | to_entries[] |
       select(((.value.body // "") | contains($marker)) and
              (((.value.author.login // "") | ascii_downcase) == ($login | ascii_downcase))) |
       .key] | last // -1
    ' "$work_dir/target.json")
    ((marker_index >= 0)) || die 'thread has no canonical agent reply to settle'

    # An unrelated authoritative account replying after the agent's reply is
    # not acknowledgement evidence: only a response from the thread's own
    # provider (or, for the generic lane, its own recorded original author)
    # can settle or push back.
    if [[ $provider == generic ]]; then
        expected_login=$original_login
    else
        expected_login=$(review_provider_login "$provider") ||
            die "settle mode has no expected login for provider: $provider"
    fi
    jq --argjson marker "$marker_index" --arg login "$expected_login" '
      [.comments.nodes | to_entries[] | select(.key > $marker) | .value] |
      map(select((((.author.login // "") | ascii_downcase) == ($login | ascii_downcase)) or
                  (((.author.login // "") | ascii_downcase) == (($login | ascii_downcase) + "[bot]"))))
    ' "$work_dir/target.json" >"$work_dir/responses.json"
    response_count=$(jq 'length' "$work_dir/responses.json")
    if ((response_count == 0)); then
        printf 'thread=%s settlement=AWAITING_BOT_RESPONSE\n' "$target_thread"
        exit 0
    fi
    latest_body=$(jq -r '.[-1].body // ""' "$work_dir/responses.json")
    latest_id=$(jq -r '.[-1].databaseId // "unknown"' "$work_dir/responses.json")
    # Checked first, and fail-closed: a negated positive term ("not addressed",
    # "never verified") must never fall through to the positive-signal match
    # below, which would otherwise settle a thread the bot just pushed back on.
    if grep -Eiq '(^|[^a-z])(still|remain|not fixed|not resolved|incorrect|fails?|however|but)([^a-z]|$)' \
        <<<"$latest_body" ||
        grep -Eiq "(^|[^a-z])(not|never|isn'?t|wasn'?t|hasn'?t|un)-? ?(yet )?(fixed|resolved|verified|addressed|correct|sufficient|good)([^a-z]|\$)" \
        <<<"$latest_body"; then
        printf 'thread=%s settlement=PUSHBACK response=%s\n' "$target_thread" "$latest_id"
        exit 3
    fi
    if grep -Eiq '(^|[^a-z])(verified|resolved|looks good|addressed|acknowledged|no further action|thanks?)([^a-z]|$)' \
        <<<"$latest_body"; then
        resolve_thread
        printf 'thread=%s settlement=SETTLED response=%s\n' "$target_thread" "$latest_id"
        exit 0
    fi
    printf 'thread=%s settlement=PUSHBACK response=%s\n' "$target_thread" "$latest_id"
    exit 3
fi

[[ $provider != github-code-quality ]] ||
    die 'github-code-quality findings must auto-clear or use the supported dismissal workflow'
[[ $provider != human ]] || die 'human threads require per-item confirmation and are never resolved here'
if [[ -z $comment_id ]]; then
    comment_id=$(jq -er '.comments.nodes[0].databaseId | select(type == "number" and . > 0)' \
        "$work_dir/target.json") || die 'original thread comment has no database ID'
fi

args=(--pr "$pr" --repo "$repo" --reply-to "$comment_id" --provider "$provider"
      --disposition "$disposition" --sha "$sha" --reasoning-file "$reasoning_file"
      --agent-identity "$agent_identity")
[[ $provider != generic ]] || args+=(--provider-login "$original_login")
COMPOSE_REVIEW_COMMENT="$COMMENT_HELPER" bash "$COMPOSER" "${args[@]}"
