#!/usr/bin/env bash
# Suite: triage-issues.sh classification, precedence, cache, and degradation.
#
# fixtures/triage-real.json is a SANITIZED RECORDING of a live Projects v2
# response, so the response shape under test is the API's, not an invention.
set -uo pipefail

TEST_NAME='triage-issues'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tr_sh="$root/agentkit/skills/.shared/scripts/triage-issues.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

mkdir -p "$tmp/stub"
cp "$here/stub/gh" "$tmp/stub/gh"
chmod +x "$tmp/stub/gh"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent"
    printf 'AGENT_REPO_SLUG=example-org/example-repo\n' > "$dir/.agent/config.env"
    printf '%s' "$dir"
}

run_triage() {
    local repo=$1 fixture=$2
    shift 2
    GH_STUB_LOG="$tmp/gh.log" GH_STUB_RESPONSE="$here/fixtures/$fixture" \
        PATH="$tmp/stub:$PATH" "$tr_sh" --repo-root "$repo" "$@"
}

line_for() { printf '%s\n' "$out" | grep -E "^#$1[[:space:]]" || true; }

# --- one call --------------------------------------------------------------
repo=$(make_repo)
: > "$tmp/gh.log"
out=$(run_triage "$repo" triage-mixed.json 2> /dev/null)
assert_eq '1' "$(wc -l < "$tmp/gh.log")" 'the whole triage costs one gh call'
assert_contains "$(cat "$tmp/gh.log")" 'graphql' 'the one call is graphql'
assert_eq 'yes' "$([[ -f "$repo/.agent/cache/triage-response.json" ]] && echo yes || echo no)" \
    'raw triage response is persisted before parsing'
assert_contains "$(cat "$repo/.agent/cache/triage-response.json")" '"data"' \
    'persisted triage response retains fetched evidence'

# --- verdicts --------------------------------------------------------------
assert_contains "$(line_for 57)" 'clean' '#57 with no referencing PR is clean'
assert_contains "$(line_for 54)" 'merged-ref' '#54 with a merged PR is merged-ref'
assert_contains "$(line_for 54)" '#212' '#54 names the merged PR'
assert_contains "$(line_for 62)" 'in-flight' '#62 with an open PR is in-flight'
assert_contains "$(line_for 48)" 'active' '#48 In progress is active'
assert_contains "$(line_for 41)" 'attempted' '#41 with a closed-unmerged PR is attempted'
assert_contains "$(line_for 39)" 'clean' '#39 on no board is clean'

# The script must never claim an interpretation it cannot prove.
assert_not_contains "$out" 'fully addressed' 'never claims fully addressed'
assert_not_contains "$out" 'partially addressed' 'never claims partially addressed'

# --- precedence ------------------------------------------------------------
assert_eq '' "$(line_for 30)" 'Done issues are excluded from the digest'
assert_contains "$(line_for 28)" 'in-flight' 'open beats merged in precedence'
assert_contains "$(line_for 28)" '#310' 'names the PR that produced the verdict'
assert_contains "$(line_for 28)" '+1 more' 'flags the additional referencing PR'

# --- status column ---------------------------------------------------------
assert_contains "$(line_for 62)" 'Backlog' 'shows the board status'
assert_contains "$(line_for 39)" '-' 'shows a dash for no board membership'

# --- item-id cache ---------------------------------------------------------
cache="$repo/.agent/cache/board-items.json"
assert_eq 'yes' "$([[ -f $cache ]] && echo yes || echo no)" 'writes the item-id cache'
assert_eq '1' "$(jq -r '.schemaVersion' < "$cache")" 'cache declares schemaVersion 1'
assert_eq 'PVT_ex' "$(jq -r '.project' < "$cache")" 'cache is keyed by project node id'
assert_eq 'PVTI_ex57' "$(jq -r '.items["57"]' < "$cache")" 'cache maps issue number to item id'
assert_eq 'null' "$(jq -r '.items["39"]' < "$cache")" 'issues on no board are absent from the cache'

# --- ADR candidates --------------------------------------------------------
repo=$(make_repo)
mkdir -p "$repo/docs/adr"
printf '# Parser resilience strategy\nstatus: accepted\n' > "$repo/docs/adr/0012-parser-resilience.md"
printf '# Unrelated topic\nstatus: accepted\n' > "$repo/docs/adr/0003-unrelated.md"
printf 'AGENT_ADR_DIR=docs/adr\n' >> "$repo/.agent/config.env"
out=$(run_triage "$repo" triage-mixed.json 2> /dev/null)
assert_contains "$(line_for 57)" '0012-parser-resilience' '#57 surfaces the matching ADR'
assert_not_contains "$(line_for 62)" '0012' 'a non-matching issue surfaces no ADR'

# --- header ----------------------------------------------------------------
assert_contains "$out" 'triage= repo=example-org/example-repo' 'header names the repo'
assert_contains "$out" 'calls=1' 'header reports the call count'

# --- a real, sanitized API recording ---------------------------------------
# The live shape differs from a hand-written fixture in one way that matters:
# an issue-to-issue cross-reference arrives as {"source":{}} -- an empty object,
# not null -- and must not be mistaken for a referencing pull request.
repo=$(make_repo)
out=$(run_triage "$repo" triage-real.json 2> /dev/null)
assert_contains "$out" '#578' 'classifies the real board-resident issue'
assert_contains "$(line_for 578)" 'Ready' 'reads Status from the real response'
assert_contains "$(line_for 581)" 'in-flight' 'the real open cross-reference is in-flight'
assert_not_contains "$(line_for 581)" '+1 more' 'an empty {"source":{}} is not counted as a pull request'
assert_eq 'PVTI_realshape001' "$(jq -r '.items["578"]' < "$repo/.agent/cache/board-items.json")" \
    'caches the item id from the real response'

# --- partial response ------------------------------------------------------
repo=$(make_repo)
out=$(run_triage "$repo" triage-partial.json 2> /dev/null)
assert_contains "$out" 'unknown' 'a partial response yields unknown, not a fabricated verdict'
assert_rc 0 'a partial response still exits 0' -- env \
    GH_STUB_LOG="$tmp/gh.log" GH_STUB_RESPONSE="$here/fixtures/triage-partial.json" \
    PATH="$tmp/stub:$PATH" "$tr_sh" --repo-root "$repo"

# --- environment-blocked ---------------------------------------------------
repo=$(make_repo)
mkdir -p "$tmp/emptybin"
assert_rc 3 'no gh on PATH exits 3' -- env PATH="$tmp/emptybin" /bin/bash "$tr_sh" --repo-root "$repo"

# A missing parser blocks the triage evidence check rather than yielding an
# empty issue set. Keep gh available in the stripped path so jq is the failure.
mkdir -p "$tmp/no-jq"
cp "$tmp/stub/gh" "$tmp/no-jq/gh"
chmod +x "$tmp/no-jq/gh"
repo=$(make_repo)
set +e
missing_parser_output=$(GH_STUB_LOG="$tmp/gh-missing-parser.log" \
    GH_STUB_RESPONSE="$here/fixtures/triage-mixed.json" PATH="$tmp/no-jq" \
    /bin/bash "$tr_sh" --repo-root "$repo" 2>"$tmp/triage-parser.err")
missing_parser_rc=$?
set -e
assert_eq '3' "$missing_parser_rc" 'missing jq blocks triage evidence parsing'
assert_eq '' "$missing_parser_output" 'missing jq emits no empty triage digest'
assert_contains "$(cat "$tmp/triage-parser.err")" 'jq' 'missing triage parser error names jq'
assert_contains "$(cat "$tmp/triage-parser.err")" 'evidence unavailable' \
    'missing triage parser error says evidence is unavailable'

# --- fuzzy is opt-in -------------------------------------------------------
repo=$(make_repo)
: > "$tmp/gh.log"
run_triage "$repo" triage-mixed.json > /dev/null 2>&1
assert_not_contains "$(cat "$tmp/gh.log")" 'pr list' 'the fuzzy PR search is not run by default'

# --- explicit mode is still one call ---------------------------------------
repo=$(make_repo)
: > "$tmp/gh.log"
run_triage "$repo" triage-mixed.json --issues 57,54 > /dev/null 2>&1
assert_eq '1' "$(wc -l < "$tmp/gh.log")" 'explicit mode is also a single call'

# --- usage -----------------------------------------------------------------
assert_rc 2 'unknown flag is a usage error' -- env PATH="$tmp/stub:$PATH" \
    "$tr_sh" --repo-root "$repo" --bogus

finish
