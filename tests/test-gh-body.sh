#!/usr/bin/env bash
# Suite: PR and issue mutation bodies are posted and byte-verified by one helper.
# shellcheck disable=SC2016  # literal body fixtures must stay unexpanded
set -uo pipefail

TEST_NAME='gh-body'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >>"$GH_LOG"
printf '\n' >>"$GH_LOG"

body_file=''
for ((i = 1; i <= $#; i++)); do
    case ${!i} in
        --body-file)
            i=$((i + 1))
            body_file=${!i}
            ;;
        --body-file=*) body_file=${!i#*=} ;;
    esac
done

if [[ ${1-} == pr || ${1-} == issue ]]; then
    [[ -n $body_file && -f $body_file ]] || exit 21
    cp -- "$body_file" "$GH_STORED_BODY"
    if [[ ${2-} == create ]]; then
        host=${GH_CREATE_HOST:-github.com}
        if [[ ${1-} == pr ]]; then
            printf 'https://%s/%s/pull/%s\n' "$host" "${GH_CREATE_SLUG:-owner/repo}" "${GH_CREATE_NUMBER:-41}"
        else
            printf 'https://%s/%s/issues/%s\n' "$host" "${GH_CREATE_SLUG:-owner/repo}" "${GH_CREATE_NUMBER:-42}"
        fi
    fi
    exit 0
fi

if [[ ${1-} == api ]]; then
    shift
    api_host=''
    if [[ ${1-} == --hostname ]]; then
        api_host=${2-}
        shift 2
    fi
    if [[ ${1-} == graphql ]]; then
        printf 'host=%s endpoint=graphql\n' "${api_host:-<ambient>}" >>"$GH_API_LOG"
        if [[ ${GH_CLOSING_PAGE2:-0} == 1 ]]; then
            # The expected issue lives past the first page: page one carries an
            # unrelated linkage and a cursor, page two carries #42.
            if printf '%s\n' "$@" | grep -q '^after=CUR1$'; then
                jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: [{number: 42}], pageInfo: {hasNextPage: false, endCursor: null}}}}}}'
            else
                jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: [{number: 99}], pageInfo: {hasNextPage: true, endCursor: "CUR1"}}}}}}'
            fi
            exit 0
        fi
        if [[ ${GH_CLOSING_LATE:-0} == 1 ]]; then
            attempts=0
            [[ ! -f ${GH_CLOSING_STATE_FILE:?} ]] || attempts=$(<"$GH_CLOSING_STATE_FILE")
            attempts=$((attempts + 1))
            printf '%s\n' "$attempts" >"$GH_CLOSING_STATE_FILE"
            if ((attempts >= 3)); then
                jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: [{number: 42}]}}}}}'
            else
                jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: []}}}}}'
            fi
            exit 0
        fi
        if [[ ${GH_INCLUDE_CLOSING:-0} == 1 ]]; then
            jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: [{number: 42}]}}}}}'
        else
            jq -n '{data: {repository: {pullRequest: {closingIssuesReferences: {nodes: []}}}}}'
        fi
        exit 0
    fi
    [[ $# -eq 1 ]] || {
        printf 'gh api received unexpected arguments: %q\n' "$*" >&2
        exit 23
    }
    printf 'host=%s endpoint=%s\n' "${api_host:-<ambient>}" "$1" >>"$GH_API_LOG"
    case $1 in
        repos/owner/repo/pulls/41|repos/owner/repo/issues/42|repos/url-owner/url-repo/issues/42) ;;
        repos/ent-owner/ent-repo/pulls/7|repos/ent-owner/ent-repo/pulls/8) ;;
        *)
            printf 'gh api received unexpected endpoint: %s\n' "$1" >&2
            exit 23
            ;;
    esac
    if [[ ${GH_VERIFY_FAILURE:-0} == 1 ]]; then
        printf 'verification unavailable\n' >&2
        exit 24
    fi
    if [[ ${GH_MISMATCH:-0} == 1 ]]; then
        jq -n '{body: "tampered"}'
    elif [[ $1 == repos/*/pulls/* ]]; then
        # Closing-issue base-awareness reads .base.ref / .base.repo.default_branch
        # from this same pull-request fetch; default both to "main" so existing
        # scenarios keep exercising the default-branch (registration-required) path.
        jq -Rs --arg base "${GH_PR_BASE:-main}" --arg default_branch "${GH_PR_DEFAULT_BRANCH:-main}" \
            '{body: ., base: {ref: $base, repo: {default_branch: $default_branch}}}' \
            <"$GH_STORED_BODY"
    else
        jq -Rs '{body: .}' <"$GH_STORED_BODY"
    fi
    exit 0
fi

printf 'unexpected gh invocation\n' >&2
exit 22
EOF
chmod +x "$tmp/gh"

body="$tmp/body.md"
printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    'literal `sha` and $(printf should-not-run)' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' >"$body"

run_body() {
    GH_BODY_GH="$tmp/gh" GH_LOG="$tmp/gh.log" GH_API_LOG="$tmp/api.log" \
        GH_STORED_BODY="$tmp/stored.md" \
        GH_MISMATCH="${GH_MISMATCH:-0}" \
        GH_VERIFY_FAILURE="${GH_VERIFY_FAILURE:-0}" \
        GH_INCLUDE_CLOSING="${GH_INCLUDE_CLOSING:-0}" \
        GH_CLOSING_PAGE2="${GH_CLOSING_PAGE2:-0}" \
        GH_CLOSING_LATE="${GH_CLOSING_LATE:-0}" \
        GH_CLOSING_STATE_FILE="$tmp/closing-attempts" \
        GH_BODY_CLOSING_RETRY_DELAY="${GH_BODY_CLOSING_RETRY_DELAY:-0}" \
        GH_PR_BASE="${GH_PR_BASE:-main}" \
        GH_PR_DEFAULT_BRANCH="${GH_PR_DEFAULT_BRANCH:-main}" \
        bash "$root/agentkit/skills/.shared/scripts/gh-body.sh" "$@"
}

output=$(run_body pr create --repo owner/repo --body-file "$body" --draft --title 'A `title`')
assert_contains "$output" 'https://github.com/owner/repo/pull/41' \
    'PR create returns the gh result after exact verification'
if cmp -s "$body" "$tmp/stored.md"; then
    _pass 'PR create forwards the exact body file bytes'
else
    _fail 'PR create forwards the exact body file bytes' 'stored body differs from source file'
fi
assert_contains "$(cat "$tmp/gh.log")" '--body-file' 'PR create uses gh body-file transport'
assert_contains "$(cat "$tmp/gh.log")" '--draft' 'PR create forwards non-body options'

output=$(run_body pr edit 41 --repo owner/repo --body-file "$body" --title 'edited')
assert_contains "$output" 'updated pr #41' 'PR edit verifies a target with no gh stdout URL'

output=$(run_body issue create --repo owner/repo --body-file="$body" --title 'An issue')
assert_contains "$output" 'https://github.com/owner/repo/issues/42' \
    'issue create returns the gh result after exact verification'

output=$(run_body issue edit https://github.com/url-owner/url-repo/issues/42 \
    --repo owner/repo --body-file "$body")
assert_contains "$output" 'updated issue #42' 'issue edit accepts a canonical target URL'
assert_contains "$(cat "$tmp/api.log")" 'repos/url-owner/url-repo/issues/42' \
    'URL edit verification preserves the repository parsed from the target URL'

# A URL carries the host the mutation actually landed on. gh api would otherwise
# resolve the ambient host (repo context, GH_HOST, else github.com), verifying an
# Enterprise mutation against the wrong server.
: >"$tmp/api.log"
output=$(run_body pr edit https://ghe.example/ent-owner/ent-repo/pull/7 --body-file "$body")
assert_contains "$output" 'updated pr #7' 'Enterprise URL edit target is verified'
assert_contains "$(cat "$tmp/api.log")" 'host=ghe.example' \
    'Enterprise edit target verifies against its originating host'
assert_contains "$(cat "$tmp/api.log")" 'endpoint=repos/ent-owner/ent-repo/pulls/7' \
    'Enterprise edit target keeps the repository parsed from the URL'

: >"$tmp/api.log"
export GH_CREATE_HOST=ghe.example GH_CREATE_SLUG=ent-owner/ent-repo GH_CREATE_NUMBER=8
output=$(run_body pr create --body-file "$body" --title 'ent')
unset GH_CREATE_HOST GH_CREATE_SLUG GH_CREATE_NUMBER
assert_contains "$output" 'https://ghe.example/ent-owner/ent-repo/pull/8' \
    'Enterprise create returns the created URL'
assert_contains "$(cat "$tmp/api.log")" 'host=ghe.example' \
    'Enterprise create verifies against the host in the returned URL'

# A numeric target carries no host, so ambient resolution must be preserved --
# that is the same host gh itself used for the mutation.
: >"$tmp/api.log"
output=$(run_body pr edit 41 --repo owner/repo --body-file "$body")
assert_contains "$(cat "$tmp/api.log")" 'host=<ambient>' \
    'a numeric target leaves host resolution to gh'
assert_not_contains "$(cat "$tmp/api.log")" '--hostname' \
    'a numeric target never pins a host'

canonical="$tmp/canonical.md"
printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    '## Testing' \
    '' \
    '- [ ] canonical footer' \
    '' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' \
    '' \
    'Closes #42' >"$canonical"
output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical")
assert_contains "$output" 'updated pr #41' \
    'canonical separate signature and closing line pass byte verification'

wrong_link="$tmp/wrong-link.md"
printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    'body has the wrong closing issue' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' \
    '' \
    'Closes #99' >"$wrong_link"
gh_calls_before=$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')
set +e
wrong_link_output=$(run_body pr create --repo owner/repo --body-file "$wrong_link" \
    --expect-closing-issue 42 2>"$tmp/wrong-link.err")
wrong_link_rc=$?
set -e
assert_eq '1' "$wrong_link_rc" \
    'body with a different closing issue fails before mutation'
assert_eq '' "$wrong_link_output" \
    'wrong body-side closing issue emits no success output'
assert_contains "$(cat "$tmp/wrong-link.err")" \
    'expected closing keyword for #42' \
    'wrong body-side closing issue names the expected issue'
gh_calls_after=$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')
assert_eq "$gh_calls_before" "$gh_calls_after" \
    'wrong body-side closing issue never calls gh'

export GH_INCLUDE_CLOSING=1
output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42)
unset GH_INCLUDE_CLOSING
assert_contains "$output" 'updated pr #41' \
    'explicit closing-reference verification passes when GitHub registers the issue'
assert_contains "$(cat "$tmp/api.log")" 'endpoint=graphql' \
    'explicit closing-reference verification queries GitHub GraphQL'
assert_contains "$output" 'closing-issue #42: confirmed' \
    'default-branch PR reports a confirmed closing-issue outcome'

rm -f -- "$tmp/closing-attempts"
export GH_CLOSING_LATE=1
late_output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42)
unset GH_CLOSING_LATE
assert_contains "$late_output" 'updated pr #41' \
    'late-populated closing linkage succeeds within the bounded retry'
assert_eq '3' "$(cat "$tmp/closing-attempts")" \
    'late-populated closing linkage uses three bounded attempts'

set +e
missing_link_output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42 2>"$tmp/missing-link.err")
missing_link_rc=$?
set -e
assert_eq '1' "$missing_link_rc" \
    'explicit closing-reference verification fails when GitHub registers no issue'
assert_eq '' "$missing_link_output" \
    'missing linkage emits no success output'
assert_contains "$(cat "$tmp/missing-link.err")" 'closingIssuesReferences' \
    'missing linkage failure names the machine evidence'

set +e
missing_create_output=$(run_body pr create --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42 2>"$tmp/missing-create.err")
missing_create_rc=$?
set -e
assert_eq '1' "$missing_create_rc" \
    'created PR with genuinely missing linkage still fails after retries'
assert_contains "$missing_create_output" 'https://github.com/owner/repo/pull/41' \
    'missing-link create preserves the created PR URL for the ledger'
assert_contains "$(cat "$tmp/missing-create.err")" \
    'PR was created at https://github.com/owner/repo/pull/41' \
    'missing-link failure identifies the created PR URL'
assert_contains "$(cat "$tmp/missing-create.err")" \
    'body-side Closes #42 verification passed' \
    'missing-link failure states that body-side linkage passed'

invalid="$tmp/invalid.md"
printf '%s\n' 'body without the required front banner' '🤖 Co-authored by Codex gpt-5.6-luna.' >"$invalid"
set +e
invalid_output=$(run_body pr create --repo owner/repo --body-file "$invalid" 2>"$tmp/invalid.err")
invalid_rc=$?
set -e
assert_eq '1' "$invalid_rc" 'missing attribution banner fails before posting'
assert_eq '' "$invalid_output" 'invalid attribution has no success output'
assert_contains "$(cat "$tmp/invalid.err")" 'front banner' \
    'front-banner failure is explained'

missing_footer="$tmp/missing-footer.md"
printf '%s\n' 'This was written agentically; verify its assertions:' 'body without footer' >"$missing_footer"
set +e
footer_output=$(run_body issue edit 42 --repo owner/repo --body-file "$missing_footer" 2>"$tmp/footer.err")
footer_rc=$?
set -e
assert_eq '1' "$footer_rc" 'missing attribution footer fails before posting'
assert_eq '' "$footer_output" 'missing footer has no success output'
assert_contains "$(cat "$tmp/footer.err")" 'closing attribution' \
    'closing-attribution failure is explained'

set +e
export GH_MISMATCH=1
mismatch_output=$(run_body pr edit 41 --repo owner/repo --body-file "$body" 2>"$tmp/mismatch.err")
mismatch_rc=$?
unset GH_MISMATCH
set -e
assert_eq '1' "$mismatch_rc" 'stored body mismatch fails the mutation'
assert_eq '' "$mismatch_output" 'mismatch emits no success result'
assert_contains "$(cat "$tmp/mismatch.err")" 'stored body does not match' \
    'mismatch reports the failed byte comparison'

set +e
export GH_MISMATCH=1
create_mismatch_output=$(run_body pr create --repo owner/repo --body-file "$body" \
    2>"$tmp/create-mismatch.err")
create_mismatch_rc=$?
unset GH_MISMATCH
set -e
assert_eq '1' "$create_mismatch_rc" 'create byte mismatch fails verification'
assert_contains "$create_mismatch_output" 'https://github.com/owner/repo/pull/41' \
    'create byte mismatch preserves the created URL'
assert_contains "$(cat "$tmp/create-mismatch.err")" 'stored body does not match' \
    'create byte mismatch still reports the failed byte comparison'

set +e
export GH_VERIFY_FAILURE=1
refetch_output=$(run_body issue create --repo owner/repo --body-file "$body" \
    2>"$tmp/refetch.err")
refetch_rc=$?
unset GH_VERIFY_FAILURE
set -e
assert_eq '1' "$refetch_rc" 'create re-fetch failure fails verification'
assert_contains "$refetch_output" 'https://github.com/owner/repo/issues/42' \
    'create re-fetch failure preserves the created URL'
assert_contains "$(cat "$tmp/refetch.err")" 'body re-fetch failed' \
    'create re-fetch failure explains the unverified mutation'



# --- closing linkage past the first page -----------------------------------
# closingIssuesReferences(first:100) reads one page. A linkage sitting beyond it
# is present but unreadable in a single fetch, so a one-page verifier reports
# valid linkage as missing and refuses a correct PR.
export GH_CLOSING_PAGE2=1
page2_output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42)
unset GH_CLOSING_PAGE2
assert_contains "$page2_output" 'updated pr #41' \
    'closing linkage on the second page is found, not rejected'

# --- closing-issue registration is base-aware ------------------------------
# GitHub only registers closingIssuesReferences for a PR whose base is the
# repository's default branch. A stacked PR (base = a feature branch, as
# --auto-serialize produces) can never register the link at creation time,
# so the proof must defer rather than fail -- the real check moves to
# retarget time, outside this helper.
: >"$tmp/api.log"
export GH_PR_BASE=feat/issue-299 GH_PR_DEFAULT_BRANCH=main
stacked_output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical" \
    --expect-closing-issue 42)
unset GH_PR_BASE GH_PR_DEFAULT_BRANCH
assert_contains "$stacked_output" 'updated pr #41' \
    'stacked PR still verifies the byte-exact body'
assert_contains "$stacked_output" 'closing-issue #42: deferred' \
    'stacked PR reports a deferred closing-issue outcome instead of failing'
assert_not_contains "$stacked_output" 'closing-issue #42: confirmed' \
    'deferred outcome is not reported as confirmed'
assert_not_contains "$(cat "$tmp/api.log")" 'endpoint=graphql' \
    'a stacked base never spends a GraphQL closing-reference query'

# The deferred outcome is a genuinely different string than a plain verified
# edit with no --expect-closing-issue at all, so the two are never conflated.
plain_output=$(run_body pr edit 41 --repo owner/repo --body-file "$canonical")
assert_not_contains "$plain_output" 'closing-issue #42' \
    'omitting --expect-closing-issue emits no closing-issue line at all'

# A stacked base is not a free pass: a body missing the closing keyword still
# fails before any mutation runs, regardless of base.
stacked_missing_keyword="$tmp/stacked-missing-keyword.md"
printf '%s\n' \
    'This was written agentically; verify its assertions:' \
    '' \
    'no closing keyword in this body' \
    '🤖 Co-authored by Codex gpt-5.6-luna.' >"$stacked_missing_keyword"
gh_calls_before=$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')
export GH_PR_BASE=feat/issue-299 GH_PR_DEFAULT_BRANCH=main
set +e
stacked_missing_output=$(run_body pr create --repo owner/repo \
    --body-file "$stacked_missing_keyword" --expect-closing-issue 42 \
    2>"$tmp/stacked-missing.err")
stacked_missing_rc=$?
set -e
unset GH_PR_BASE GH_PR_DEFAULT_BRANCH
assert_eq '1' "$stacked_missing_rc" \
    'stacked PR with a missing closing keyword still fails'
assert_eq '' "$stacked_missing_output" \
    'stacked PR missing-keyword failure emits no success output'
assert_contains "$(cat "$tmp/stacked-missing.err")" \
    'expected closing keyword for #42' \
    'stacked PR missing-keyword failure names the expected issue'
gh_calls_after=$(wc -l <"$tmp/gh.log" | tr -d '[:space:]')
assert_eq "$gh_calls_before" "$gh_calls_after" \
    'stacked PR missing-keyword failure never calls gh'

# The default-branch path is unchanged: it still requires a non-empty closing
# reference and fails loudly when it is absent (missing_link_output and
# missing_create_output above already exercise this with the suite's default
# GH_PR_BASE=GH_PR_DEFAULT_BRANCH=main fixture, i.e. the retarget-time shape).

finish
