#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='gh-pr-state'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/14 "*)
        printf '%s\n' '{"number":14,"draft":true,"mergeable":true,"head":{"ref":"feat/test","sha":"abcdef0123456789"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/abcdef0123456789/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"},{"name":"coderabbitai","status":"in_progress"},{"name":"lint","status":"completed","conclusion":"failure"}]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"advanced security","author":{"login":"github-advanced-security[bot]","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"scanner","author":{"login":"security-scanner","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"known provider","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"<!-- review-remote-pr:agent-reply -->\nagent bookkeeping","author":{"login":"agent-account","__typename":"User"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"human quoted <!-- review-remote-pr:agent-doc --> marker","author":{"login":"botond","__typename":"User"}}]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[{"body":"human missing author","author":null}]}}
        ]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/gh"

output=$(PATH="$tmp:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 14 --repo owner/repo)
assert_contains "$output" 'pr=14 draft=true mergeable=MERGEABLE head=feat/test sha=abcdef0' \
    'digest reports pull-request metadata'
assert_contains "$output" 'ci=1/3 failing pending=1 failing=1' \
    'digest reports check counts'
assert_contains "$output" 'threads: coderabbit=1 unresolved  code-quality=0 open  human=2  generic=2' \
    'known and generic bot lanes stay separate from human threads'
assert_contains "$output" 'classification: known-provider=1 type=Bot=1 login-suffix=1 human=2' \
    'state dump excludes agent-marked-only replies from the human signal'
assert_not_contains "$output" '{"number"' 'digest does not leak raw API JSON'
assert_contains "$output" 'provider: coderabbit=none' \
    'no coderabbit issue comment reports provider state none'
assert_contains "$output" 'agent-docs: 0 eligible' \
    'no unresolved marked-first-comment thread reports zero agent-docs'
assert_contains "$output" 'next: coderabbit=1 -> reply then resolve last (Step 5)' \
    'a non-zero coderabbit lane prints its next hint'
assert_contains "$output" 'next: human=2 -> per-item confirmation gate (Step 1a)' \
    'a non-zero human lane prints its next hint'
assert_contains "$output" 'next: generic=2 -> smallest fix or decline reply (Step 5)' \
    'a non-zero generic lane prints its next hint'
assert_not_contains "$output" 'next: code-quality' \
    'a zero code-quality lane prints no next hint'
assert_not_contains "$output" 'next: nitpicks' \
    'a zero nitpicks lane prints no next hint'
assert_not_contains "$output" 'next: agent-docs' \
    'a zero agent-docs lane prints no next hint'

# --- a child whose base advanced after its checks completed -----------------

mkdir -p "$tmp/case-stale-base"
cat >"$tmp/case-stale-base/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/77 "*)
        printf '%s\n' '{"number":77,"draft":false,"mergeable":true,"head":{"ref":"feat/child","sha":"childsha"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/childsha/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *"compare/main...feat/child"*)
        printf '%s\n' '{"status":"behind","ahead_by":1,"behind_by":1,"total_commits":2,"commits":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-stale-base/gh"
stale_base_output=$(PATH="$tmp/case-stale-base:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 77 --repo owner/repo)
assert_contains "$stale_base_output" 'ci=1/1 stale pending=0 failing=0' \
    'passing checks predating a base advance are reported stale, not green'
assert_contains "$stale_base_output" 'base: ref=main behind=1 stale=yes' \
    'digest identifies stale ancestry evidence'

# A stale ancestry signal must not mask a pending check.
mkdir -p "$tmp/case-stale-pending"
cp "$tmp/case-stale-base/gh" "$tmp/case-stale-pending/gh"
sed -i 's/"status":"completed","conclusion":"success"/"status":"in_progress"/' "$tmp/case-stale-pending/gh"
stale_pending_output=$(PATH="$tmp/case-stale-pending:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 77 --repo owner/repo)
assert_contains "$stale_pending_output" 'ci=0/1 pending pending=1 failing=0' \
    'pending checks take precedence over stale ancestry'

# A deleted/unavailable base leaves evidence unknown but still prints the digest.
mkdir -p "$tmp/case-base-unavailable"
cat >"$tmp/case-base-unavailable/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/78 "*)
        printf '%s\n' '{"number":78,"draft":false,"mergeable":null,"head":{"ref":"feat/child","sha":"childsha"},"base":{"ref":"deleted-parent"}}'
        ;;
    *" api repos/owner/repo/commits/childsha/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *"compare/deleted-parent...feat/child"*)
        printf '%s\n' 'base branch not found' >&2
        exit 1
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-base-unavailable/gh"
base_unavailable_err="$tmp/base-unavailable.err"
base_unavailable_output=$(PATH="$tmp/case-base-unavailable:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 78 --repo owner/repo 2>"$base_unavailable_err")
assert_contains "$base_unavailable_output" 'ci=1/1 green pending=0 failing=0' \
    'unknown ancestry does not relabel otherwise green checks'
assert_contains "$base_unavailable_output" 'base: ref=deleted-parent behind=unknown stale=unknown' \
    'base lookup failure keeps base evidence explicitly unknown'
assert_contains "$(cat "$base_unavailable_err")" 'base comparison unavailable' \
    'base lookup failure emits a diagnostic without aborting the digest'

# --- provider state: last-signal-wins over the issue comments --------------

mkdir -p "$tmp/case-reviewed"
cat >"$tmp/case-reviewed/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/99 "*)
        printf '%s\n' '{"number":99,"draft":true,"mergeable":true,"head":{"ref":"feat/x","sha":"1111111111"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/1111111111/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"issues/99/comments"*)
        printf '%s\n' '[{"user":{"login":"coderabbitai[bot]"},"body":"Actionable comments posted: 2"}]'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-reviewed/gh"
reviewed_output=$(PATH="$tmp/case-reviewed:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 99 --repo owner/repo)
assert_contains "$reviewed_output" 'provider: coderabbit=reviewed' \
    'an actionable-comments body reports provider state reviewed'

mkdir -p "$tmp/case-rate-limited"
cat >"$tmp/case-rate-limited/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/99 "*)
        printf '%s\n' '{"number":99,"draft":true,"mergeable":true,"head":{"ref":"feat/x","sha":"1111111111"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/1111111111/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"issues/99/comments"*)
        printf '%s\n' '[{"user":{"login":"coderabbitai[bot]"},"body":"Review limit reached; upgrade for more"}]'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-rate-limited/gh"
rate_limited_output=$(PATH="$tmp/case-rate-limited:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 99 --repo owner/repo)
assert_contains "$rate_limited_output" 'provider: coderabbit=rate-limited' \
    'a rate-limit body reports provider state rate-limited'

mkdir -p "$tmp/case-stale-then-rate-limited"
cat >"$tmp/case-stale-then-rate-limited/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/99 "*)
        printf '%s\n' '{"number":99,"draft":true,"mergeable":true,"head":{"ref":"feat/x","sha":"1111111111"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/1111111111/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"issues/99/comments"*)
        printf '%s\n' '[{"user":{"login":"coderabbitai[bot]"},"body":"<summary>walkthrough</summary>"},{"user":{"login":"coderabbitai[bot]"},"body":"Review limit reached on this trigger"}]'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-stale-then-rate-limited/gh"
stale_output=$(PATH="$tmp/case-stale-then-rate-limited:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 99 --repo owner/repo)
assert_contains "$stale_output" 'provider: coderabbit=rate-limited' \
    'a later rate-limit body overrides an earlier stale walkthrough'

# --- agent-doc eligibility: unresolved, first-comment-marked, bot-only only -

mkdir -p "$tmp/case-agent-docs"
cat >"$tmp/case-agent-docs/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/99 "*)
        printf '%s\n' '{"number":99,"draft":true,"mergeable":true,"head":{"ref":"feat/x","sha":"1111111111"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/1111111111/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"body":"This was written agentically; verify its assertions:\n<!-- review-remote-pr:agent-doc -->","author":{"login":"workflow-account","__typename":"User"}}
          ]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"body":"This was written agentically; verify its assertions:\n<!-- review-remote-pr:agent-doc -->","author":{"login":"workflow-account","__typename":"User"}},
            {"body":"actually I disagree with this fix","author":{"login":"reviewer-jane","__typename":"User"}}
          ]}},
          {"isResolved":true,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"body":"This was written agentically; verify its assertions:\n<!-- review-remote-pr:agent-doc -->","author":{"login":"workflow-account","__typename":"User"}}
          ]}},
          {"isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
            {"body":"This was written agentically; verify its assertions:\n<!-- review-remote-pr:agent-doc -->","author":{"login":"workflow-account","__typename":"User"}}
          ]}}
        ]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-agent-docs/gh"
agent_docs_output=$(PATH="$tmp/case-agent-docs:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 99 --repo owner/repo)
# Deliberately asymmetric (2 untouched bot-only marked threads vs. 1
# human-touched marked thread): a predicate inverted from "unresolved, marked,
# NOT human-touched" to "unresolved, marked, human-touched" would report 1
# eligible either way if the fixture only had one of each, hiding the
# inversion. With 2-vs-1 the counts disagree and the wrong predicate fails.
assert_contains "$agent_docs_output" 'agent-docs: 2 eligible' \
    'only the untouched unresolved marked threads count as eligible'
assert_contains "$agent_docs_output" 'threads: coderabbit=0 unresolved  code-quality=0 open  human=1  generic=0' \
    'a human reply joining a marked thread converts it to the human lane'
assert_contains "$agent_docs_output" 'next: agent-docs=2 -> resolve at exit if still bot-only' \
    'a non-zero agent-docs lane prints its next hint'
assert_contains "$agent_docs_output" 'next: human=1 -> per-item confirmation gate (Step 1a)' \
    'the human-joined marked thread still surfaces its own next hint'

# --- next: lines are entirely absent once every lane is at zero ------------

mkdir -p "$tmp/case-all-zero"
cat >"$tmp/case-all-zero/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/99 "*)
        printf '%s\n' '{"number":99,"draft":true,"mergeable":true,"head":{"ref":"feat/x","sha":"1111111111"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/1111111111/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-all-zero/gh"
all_zero_output=$(PATH="$tmp/case-all-zero:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 99 --repo owner/repo)
assert_not_contains "$all_zero_output" 'next:' 'every lane at zero prints no next: line at all'

bare_output=$(PATH="$tmp:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    14 --repo owner/repo)
assert_contains "$bare_output" 'pr=14' 'a bare positional PR number is accepted'

set +e
bare_err=$(PATH="$tmp:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    nope --repo owner/repo 2>&1)
bare_rc=$?
set -e
assert_eq '1' "$bare_rc" 'a nonnumeric bare PR is a usage error'
assert_contains "$bare_err" 'did you mean --pr N?' \
    'a bare PR usage error gives the exact option guidance'

# A missing parser is a blocked evidence check, never an empty digest.
mkdir -p "$tmp/no-jq"
cp "$tmp/gh" "$tmp/no-jq/gh"
chmod +x "$tmp/no-jq/gh"
set +e
missing_parser_output=$(PATH="$tmp/no-jq" /bin/bash \
    "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 14 --repo owner/repo 2>"$tmp/missing-parser.err")
missing_parser_rc=$?
set -e
assert_eq '1' "$missing_parser_rc" 'missing jq blocks PR evidence parsing'
assert_eq '' "$missing_parser_output" 'missing jq emits no empty digest'
assert_contains "$(cat "$tmp/missing-parser.err")" 'jq' 'missing parser error names jq'
assert_contains "$(cat "$tmp/missing-parser.err")" 'evidence unavailable' \
    'missing parser error says evidence is unavailable'

# A depleted GraphQL pool must only remove thread data; REST metadata, checks,
# comments, and the digest remain available.
mkdir -p "$tmp/case-graphql-dead"
cat >"$tmp/case-graphql-dead/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/404 "*)
        printf '%s\n' '{"number":404,"draft":true,"mergeable":true,"head":{"ref":"feat/rest","sha":"2222222222"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/2222222222/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *" api graphql "*)
        printf '%s\n' 'API rate limit exceeded: graphql remaining=0' >&2
        exit 1
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-graphql-dead/gh"
graphql_dead_err="$tmp/graphql-dead.err"
graphql_dead_output=$(PATH="$tmp/case-graphql-dead:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 404 --repo owner/repo 2>"$graphql_dead_err")
assert_contains "$graphql_dead_output" 'pr=404 draft=true mergeable=MERGEABLE head=feat/rest sha=2222222' \
    'REST metadata still produces a digest when GraphQL is depleted'
assert_contains "$graphql_dead_output" 'ci=1/1 green pending=0 failing=0' \
    'REST check runs still produce CI counts when GraphQL is depleted'
assert_contains "$graphql_dead_output" 'threads: unavailable' \
    'thread data is explicitly marked unavailable when GraphQL is depleted'
assert_contains "$(cat "$graphql_dead_err")" 'review-thread data unavailable' \
    'GraphQL depletion names the isolated review-thread capability'
assert_contains "$(cat "$graphql_dead_err")" 'named wait: GraphQL review-thread reset' \
    'GraphQL depletion reports the bounded named wait for that capability'

finish
