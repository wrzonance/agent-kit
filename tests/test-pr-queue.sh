#!/usr/bin/env bash
# Boundary tests for persisted and forge-derived PR queue scheduling.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='pr queue'

assert_matches() {
    local value=$1 pattern=$2 desc=$3
    if [[ $value =~ $pattern ]]; then
        assert_eq true true "$desc"
    else
        assert_eq "matches $pattern" "$value" "$desc"
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
queue="$root/agentkit/skills/pr-to-green/scripts/pr-queue.sh"
repo_root="$tmp/repo"
mkdir -p "$repo_root/.agent"

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
endpoint=''
for arg in "$@"; do
    [[ $arg == repos/* ]] && endpoint=$arg
done
case $endpoint in
repos/owner/repo)
    printf '%s\n' '{"default_branch":"main"}'
    ;;
repos/owner/repo/pulls/11)
    sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    [[ ${QUEUE_DRIFT:-0} == 0 ]] || sha=dddddddddddddddddddddddddddddddddddddddd
    printf '{"number":11,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/root","sha":"%s"},"base":{"ref":"main"},"additions":5,"deletions":2,"changed_files":3}\n' "$sha"
    ;;
repos/owner/repo/pulls/12)
    printf '%s\n' '{"number":12,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/child","sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"base":{"ref":"feat/root"}}'
    ;;
repos/owner/repo/pulls/13)
    printf '%s\n' '{"number":13,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-03T00:00:00Z","head":{"ref":"feat/independent","sha":"cccccccccccccccccccccccccccccccccccccccc"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/14)
    printf '%s\n' '{"number":14,"state":"open","draft":false,"merged":false,"mergeable":true,"created_at":"2026-08-04T00:00:00Z","head":{"ref":"feat/ready","sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/15)
    printf '%s\n' '{"number":15,"state":"open","draft":false,"merged":false,"mergeable":null,"created_at":"2026-08-05T00:00:00Z","head":{"ref":"feat/unknown","sha":"ffffffffffffffffffffffffffffffffffffffff"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/16)
    printf '%s\n' '{"number":16,"state":"closed","draft":false,"merged":false,"mergeable":true,"created_at":"2026-08-06T00:00:00Z","head":{"ref":"feat/closed","sha":"1616161616161616161616161616161616161616"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/61)
    printf '%s\n' '{"number":61,"state":"closed","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-07T00:00:00Z","head":{"ref":"feat/race-closed","sha":"6161616161616161616161616161616161616161"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/21)
    printf '%s\n' '{"number":21,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/a","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"feat/b"}}'
    ;;
repos/owner/repo/pulls/22)
    printf '%s\n' '{"number":22,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/b","sha":"2222222222222222222222222222222222222222"},"base":{"ref":"feat/a"}}'
    ;;
repos/owner/repo/pulls/31)
    printf '%s\n' '{"number":31,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/root","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"main"}}'
    ;;
repos/owner/repo/pulls/32)
    printf '%s\n' '{"number":32,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/a","sha":"2222222222222222222222222222222222222222"},"base":{"ref":"feat/root"}}'
    ;;
repos/owner/repo/pulls/33)
    printf '%s\n' '{"number":33,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-03T00:00:00Z","head":{"ref":"feat/b","sha":"3333333333333333333333333333333333333333"},"base":{"ref":"feat/root"}}'
    ;;
repos/owner/repo/pulls/41)
    printf '%s\n' '{"number":41,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/a","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"release"}}'
    ;;
repos/owner/repo/pulls/*/files*)
    files_pr=$(sed -E 's#.*/pulls/([0-9]+)/files.*#\1#' <<<"$endpoint")
    fail_var="QUEUE_FILES_${files_pr}_FAIL"
    if [[ ${!fail_var:-0} == 1 ]]; then
        printf 'injected files failure\n' >&2
        exit 1
    fi
    content_var="QUEUE_FILES_${files_pr}"
    if [[ ${!content_var:-default} == toomany ]]; then
        jq -cn '[range(301) | {filename:("f" + (.|tostring) + ".txt"),sha:"blob",patch:"@@"}]'
    elif [[ -n ${!content_var:-} ]]; then
        printf '%s\n' "${!content_var}"
    else
        printf '%s\n' '[{"filename":"default.txt","sha":"blobdefault","patch":"@@ +1 -0@@"}]'
    fi
    ;;
repos/owner/repo/pulls\?state=open*)
    case ${QUEUE_MODE:-normal} in
    normal)
        printf '%s\n' '[{"number":14,"state":"open","draft":false,"created_at":"2026-08-04T00:00:00Z","head":{"ref":"feat/ready"},"base":{"ref":"main"}},{"number":13,"state":"open","draft":true,"created_at":"2026-08-03T00:00:00Z","head":{"ref":"feat/independent"},"base":{"ref":"main"}},{"number":12,"state":"open","draft":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/child"},"base":{"ref":"feat/root"}},{"number":11,"state":"open","draft":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/root"},"base":{"ref":"main"}}]'
        ;;
    cycle)
        printf '%s\n' '[{"number":21,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/a","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"feat/b"}},{"number":22,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/b","sha":"2222222222222222222222222222222222222222"},"base":{"ref":"feat/a"}}]'
        ;;
    fork)
        printf '%s\n' '[{"number":31,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/root","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"main"}},{"number":32,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-02T00:00:00Z","head":{"ref":"feat/a","sha":"2222222222222222222222222222222222222222"},"base":{"ref":"feat/root"}},{"number":33,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-03T00:00:00Z","head":{"ref":"feat/b","sha":"3333333333333333333333333333333333333333"},"base":{"ref":"feat/root"}}]'
        ;;
    wrong-base)
        printf '%s\n' '[{"number":41,"state":"open","draft":true,"merged":false,"mergeable":true,"created_at":"2026-08-01T00:00:00Z","head":{"ref":"feat/a","sha":"1111111111111111111111111111111111111111"},"base":{"ref":"release"}}]'
        ;;
    closed-race)
        printf '%s\n' '[{"number":61,"state":"open","draft":true,"created_at":"2026-08-07T00:00:00Z","head":{"ref":"feat/race-closed"},"base":{"ref":"main"}}]'
        ;;
    malformed) printf '%s\n' 'not-json' ;;
    esac
    ;;
*)
    printf 'unexpected endpoint: %s\n' "$endpoint" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/gh"

cat >"$tmp/dispatch-plan.json" <<'EOF'
{
  "schemaVersion":2,
  "generatedAt":"2026-08-17T20:00:00Z",
  "entries":[{"issue":11},{"issue":12},{"issue":13}],
  "conflictMap":{"pairs":[],"revisions":[]},
  "independent":[{"issue":13,"pr":13,"branch":"feat/independent","chainBaseSha":null,"headSha":"cccccccccccccccccccccccccccccccccccccccc"}],
  "chains":[[
    {"issue":11,"pr":11,"branch":"feat/root","chainBaseSha":null,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    {"issue":12,"pr":12,"branch":"feat/child","chainBaseSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
  ]]
}
EOF

run_queue() {
    GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" \
        bash "$queue" --repo owner/repo "$@"
}

help=$(bash "$queue" --help 2>&1)
assert_contains "$help" '--merge-plan FILE, --dispatch-plan FILE' \
    'help documents the merge-plan and dispatch-plan aliases together'
assert_contains "$help" 'same file after the ready-flip upgrade' \
    'help explains the alias pair as two lifecycle stages'

missing_schema="$tmp/missing-schema.json"
jq 'del(.schemaVersion)' "$tmp/dispatch-plan.json" >"$missing_schema"
missing_schema_rc=0
run_queue --merge-plan "$missing_schema" --format records \
    >"$tmp/missing-schema.out" 2>"$tmp/missing-schema.err" || missing_schema_rc=$?
assert_eq '1' "$missing_schema_rc" 'a document without a plan schema fails closed'
assert_contains "$(cat "$tmp/missing-schema.err")" 'not a recognized dispatch/merge plan' \
    'an unrecognized document is not mislabeled as bad topology'

schema_one="$tmp/schema-one.json"
jq '.schemaVersion = 1 | del(.generatedAt, .independent, .chains)' \
    "$tmp/dispatch-plan.json" >"$schema_one"
schema_one_rc=0
run_queue --dispatch-plan "$schema_one" --format records \
    >"$tmp/schema-one.out" 2>"$tmp/schema-one.err" || schema_one_rc=$?
assert_eq '1' "$schema_one_rc" 'a schema-1 dispatch plan requires its lifecycle upgrade'
assert_contains "$(cat "$tmp/schema-one.err")" 'write-merge-plan.sh' \
    'the stale-plan refusal names the ready-flip upgrade helper'

: >"$tmp/gh.log"
out=$(run_queue --merge-plan "$tmp/dispatch-plan.json" --format records)
assert_eq $'pr=11 issue=11 state=RUNNABLE source=plan base=main head=feat/root sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\npr=12 issue=12 state=WAITING_FOR_MERGE source=plan base=feat/root head=feat/child sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\npr=13 issue=13 state=RUNNABLE source=plan base=main head=feat/independent sha=cccccccccccccccccccccccccccccccccccccccc' \
    "$out" 'a valid merge plan emits a stable base-to-tip serial queue'
assert_eq '0' "$(grep -c 'pulls?state=open' "$tmp/gh.log" || true)" \
    'a current merge plan performs zero discovery graph-walk calls'
assert_eq '3' "$(grep -Ec 'pulls/(11|12|13)$' "$tmp/gh.log" || true)" \
    'a current merge plan performs verification reads for each recorded PR'

json=$(run_queue --merge-plan "$tmp/dispatch-plan.json" --format json)
assert_eq 'RUNNABLE' "$(jq -r '.[0].state' <<<"$json")" \
    'JSON output preserves the confirmed queue for authorization evidence'
fp11_default=$(jq -r '.[0].diffFingerprint' <<<"$json")
assert_matches "$fp11_default" '^[0-9a-f]{64}$' \
    'JSON output carries a content-sensitive diff fingerprint sourced from the live per-file read'

# issue #450 review finding F2: an aggregate additions/deletions/changed-files
# count is not a content identity -- a descendant commit can swap reviewed
# content while preserving those counts. The fingerprint must be sensitive to
# actual file content (blob sha + patch text), not just file-count shape.
fp11_rerun=$(jq -r '.[0].diffFingerprint' <<<"$(run_queue --pr 11 --format json)")
assert_eq "$fp11_default" "$fp11_rerun" \
    'the same file content yields the same diff fingerprint (deterministic)'
fp11_a=$(QUEUE_FILES_11='[{"filename":"a.txt","sha":"blobA","patch":"@@ +1 -0@@ hello"}]' \
    run_queue --pr 11 --format json | jq -r '.[0].diffFingerprint')
fp11_b=$(QUEUE_FILES_11='[{"filename":"a.txt","sha":"blobB","patch":"@@ +1 -0@@ world"}]' \
    run_queue --pr 11 --format json | jq -r '.[0].diffFingerprint')
assert_matches "$fp11_a" '^[0-9a-f]{64}$' 'fileset A yields a well-formed fingerprint'
assert_matches "$fp11_b" '^[0-9a-f]{64}$' 'fileset B yields a well-formed fingerprint'
fp_a_ne_b=true
[[ $fp11_a != "$fp11_b" ]] || fp_a_ne_b=false
assert_eq true "$fp_a_ne_b" \
    'one changed file (same single-file shape, different blob sha and patch) changes the fingerprint'

json15_fail=$(QUEUE_FILES_15_FAIL=1 run_queue --pr 15 --format json)
assert_eq 'null' "$(jq -r '.[0].diffFingerprint' <<<"$json15_fail")" \
    'an unreadable per-file evidence read yields a null fingerprint rather than a fabricated one'

json_toomany=$(QUEUE_FILES_15=toomany run_queue --pr 15 --format json)
assert_eq 'null' "$(jq -r '.[0].diffFingerprint' <<<"$json_toomany")" \
    'more files than this will fetch and hash yields a null fingerprint, never a partial one'

confirmed="$repo_root/.agent/pr-to-green-confirmed-queue.json"
display=$(GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" bash "$queue" \
    --repo owner/repo --repo-root "$repo_root" --merge-plan "$tmp/dispatch-plan.json" \
    --write-confirmed-queue --no-providers --format table)
assert_contains "$display" '#11' 'the confirmation writer preserves the displayed queue'
assert_eq '600' "$(stat -c '%a' "$confirmed")" \
    'the displayed queue snapshot is owner-only'
assert_eq '["providers","queue","repository"]' "$(jq -c 'keys | sort' "$confirmed")" \
    'the displayed queue snapshot records provider decisions'
assert_eq '[]' "$(jq -c '.providers' "$confirmed")" \
    'an explicit no-provider decision is durably recorded'
assert_eq 'owner/repo' "$(jq -r '.repository' "$confirmed")" \
    'the displayed queue snapshot is repository-bound'
assert_eq '11:RUNNABLE:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:main' \
    "$(jq -r '.queue[0] | [.pr,.state,.headSha,.base] | join(":")' "$confirmed")" \
    'the snapshot head and base come from the exact displayed queue derivation'

: >"$tmp/gh.log"
display_provider=$(GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" bash "$queue" \
    --repo owner/repo --repo-root "$repo_root" --merge-plan "$tmp/dispatch-plan.json" \
    --write-confirmed-queue --provider coderabbit:observe:operator-instruction --format table)
assert_contains "$display_provider" '#11' 'provider confirmation still preserves the displayed queue'
assert_eq 'coderabbit:observe:operator-instruction' \
    "$(jq -r '.providers[0] | [.name,.action,.source] | join(":")' "$confirmed")" \
    'the displayed provider action and source are durably recorded'

out=$(QUEUE_DRIFT=1 run_queue --merge-plan "$tmp/dispatch-plan.json" --format records 2>"$tmp/drift.err")
assert_contains "$(cat "$tmp/drift.err")" 'recorded head drift' \
    'head drift is reported before forge-graph fallback'
assert_contains "$out" 'pr=11 issue=11 state=RUNNABLE source=fallback' \
    'head drift falls back to verified forge relationships'

: >"$tmp/gh.log"
out=$(run_queue --format records)
assert_not_contains "$out" 'pr=14' 'automatic discovery excludes already-ready PRs'
assert_contains "$out" 'pr=12 issue=0 state=WAITING_FOR_MERGE source=forge' \
    'automatic discovery derives the selected stack from live base refs'
assert_eq '3' "$(grep -Ec 'pulls/(11|12|13)$' "$tmp/gh.log" || true)" \
    'discovery succeeds through per-PR fetches when the list omits merged/mergeable'

out=$(run_queue --pr 14 --format records)
assert_contains "$out" 'pr=14 issue=0 state=RUNNABLE source=forge' \
    'an explicitly named ready PR can resume'

out=$(run_queue --pr 15 --format records)
assert_contains "$out" 'pr=15 issue=0 state=MERGEABLE_UNKNOWN source=forge' \
    'a PR with unresolved mergeability never yields RUNNABLE'
assert_not_contains "$out" 'state=RUNNABLE' \
    'unknown mergeability fails closed rather than open'

closed_err="$tmp/closed.err"
assert_rc 1 'an explicitly named closed PR is refused before classification' -- \
    env GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" bash "$queue" \
    --repo owner/repo --pr 16 --format records
env GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" bash "$queue" \
    --repo owner/repo --pr 16 --format records >/dev/null 2>"$closed_err" || true
assert_contains "$(cat "$closed_err")" 'pull request #16 is not open' \
    'the closed-PR refusal names the PR and the reason'

: >"$tmp/gh.log"
out=$(QUEUE_MODE=closed-race run_queue --format records)
assert_eq '' "$out" \
    'a PR that closed between listing and fetch is dropped, never classified RUNNABLE'

for mode in cycle fork wrong-base malformed; do
    assert_rc 1 "$mode forge data fails closed" -- env QUEUE_MODE="$mode" \
        GH_LOG="$tmp/gh.log" PR_QUEUE_GH="$tmp/gh" bash "$queue" \
        --repo owner/repo --format records
done

jq '.chains += [[.independent[0], .chains[0][1]]]' "$tmp/dispatch-plan.json" >"$tmp/join-plan.json"
join_rc=0
run_queue --merge-plan "$tmp/join-plan.json" --format records \
    >"$tmp/join.out" 2>"$tmp/join.err" || join_rc=$?
assert_eq '1' "$join_rc" 'a plan with a multi-predecessor join fails closed'
assert_contains "$(cat "$tmp/join.err")" 'schema-2 merge plan has invalid topology' \
    'bad schema-2 topology is distinguished from lifecycle failures'

finish
