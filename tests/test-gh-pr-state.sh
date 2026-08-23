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
    *" api repos/owner/repo/commits/abcdef0123456789/status"*)
        printf '%s\n' '{"statuses":[]}'
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
assert_contains "$output" 'pr=14 draft=true mergeable=MERGEABLE head=feat/test sha=abcdef0123456789' \
    'digest reports pull-request metadata'
assert_not_contains "$output" $'sha=abcdef0\n' \
    'the digest never truncates the head SHA to a 7-character prefix'
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
assert_contains "$output" 'next: coderabbit=1 -> canonical reply then settle (Step 5)' \
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

# --- a base advance confined to declared AGENT_GENERATED_PATHS is not stale
# (agent-kit#394: record-tier0.yml-style post-merge commits must not force a
# merge-down plus a full CI re-run on every queued PR) ------------------------

automation_repo_root="$tmp/automation-repo"
mkdir -p "$automation_repo_root/.agent"
cat >"$automation_repo_root/.agent/config.env" <<'EOF'
AGENT_GENERATED_PATHS=bench/results/
EOF

mkdir -p "$tmp/case-automation-only"
cat >"$tmp/case-automation-only/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/810 "*)
        printf '%s\n' '{"number":810,"draft":false,"mergeable":true,"head":{"ref":"feat/automation","sha":"autosha1"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/autosha1/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *"compare/main...feat/automation"*)
        printf '%s\n' '{"status":"behind","ahead_by":0,"behind_by":1,"total_commits":1,"commits":[]}'
        ;;
    *"compare/feat/automation...main"*)
        printf '%s\n' '{"files":[{"filename":"bench/results/tier0.jsonl"}]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-automation-only/gh"
automation_only_err="$tmp/automation-only.err"
automation_only_output=$(PATH="$tmp/case-automation-only:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 810 --repo owner/repo --repo-root "$automation_repo_root" 2>"$automation_only_err")
assert_contains "$automation_only_output" 'base: ref=main behind=1 stale=no' \
    'a base advance confined to declared AGENT_GENERATED_PATHS is not reported stale'
assert_contains "$automation_only_output" 'ci=1/1 green pending=0 failing=0' \
    'passing checks under an automation-only base advance report green, not stale'
assert_contains "$(cat "$automation_only_err")" 'not staling' \
    'the automation-only exemption is named in the diagnostic'

# A base advance NOT entirely confined to declared paths still stales.
mkdir -p "$tmp/case-automation-mixed"
cat >"$tmp/case-automation-mixed/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/811 "*)
        printf '%s\n' '{"number":811,"draft":false,"mergeable":true,"head":{"ref":"feat/mixed","sha":"mixedsha1"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/mixedsha1/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *"compare/main...feat/mixed"*)
        printf '%s\n' '{"status":"behind","ahead_by":0,"behind_by":1,"total_commits":1,"commits":[]}'
        ;;
    *"compare/feat/mixed...main"*)
        printf '%s\n' '{"files":[{"filename":"bench/results/tier0.jsonl"},{"filename":"src/app.py"}]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-automation-mixed/gh"
automation_mixed_output=$(PATH="$tmp/case-automation-mixed:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 811 --repo owner/repo --repo-root "$automation_repo_root")
assert_contains "$automation_mixed_output" 'base: ref=main behind=1 stale=yes' \
    'a base advance touching even one file outside declared paths still stales'

# Without any AGENT_GENERATED_PATHS declaration, the same automation-only
# advance still stales -- the exemption is strictly opt-in, never a default.
undeclared_repo_root="$tmp/undeclared-repo"
mkdir -p "$undeclared_repo_root"
undeclared_output=$(PATH="$tmp/case-automation-only:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 810 --repo owner/repo --repo-root "$undeclared_repo_root")
assert_contains "$undeclared_output" 'base: ref=main behind=1 stale=yes' \
    'with no declared AGENT_GENERATED_PATHS the same advance still stales (opt-in only)'

# Regression pin: this repository's OWN .agent/config.env must declare a
# prefix that actually covers record-tier0.yml's bench/results/tier0.jsonl --
# the mechanism above being correct is not enough if agent-kit's own
# declaration never lists the path the workflow commits (agent-kit#394).
# This reads the real repo-root config, not a synthetic fixture; it fails the
# moment someone trims AGENT_GENERATED_PATHS back to excluding bench/results.
mkdir -p "$tmp/case-repo-declared-tier0"
cat >"$tmp/case-repo-declared-tier0/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/812 "*)
        printf '%s\n' '{"number":812,"draft":false,"mergeable":true,"head":{"ref":"feat/tier0","sha":"tier0sha1"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/tier0sha1/check-runs"*)
        printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}'
        ;;
    *"compare/main...feat/tier0"*)
        printf '%s\n' '{"status":"behind","ahead_by":0,"behind_by":1,"total_commits":1,"commits":[]}'
        ;;
    *"compare/feat/tier0...main"*)
        printf '%s\n' '{"files":[{"filename":"bench/results/tier0.jsonl"}]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-repo-declared-tier0/gh"
repo_declared_output=$(PATH="$tmp/case-repo-declared-tier0:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 812 --repo owner/repo --repo-root "$root")
assert_contains "$repo_declared_output" 'base: ref=main behind=1 stale=no' \
    "this repository's own AGENT_GENERATED_PATHS declaration covers record-tier0.yml's bench/results/tier0.jsonl (agent-kit#394 regression pin)"

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
assert_contains "$all_zero_output" 'ci=0/0 none pending=0 failing=0' \
    'zero checks outside --wait-ci still report none, never none-configured'

# --- --wait-ci: zero registered checks right after a push (agent-kit#396) --

# A stub that returns 0 checks for the first two rounds, then a real pending
# check, then a completed one. --wait-ci must not settle on the initial 0/0 --
# it has to keep polling through the grace window until real evidence arrives.
mkdir -p "$tmp/case-wait-grace"
cat >"$tmp/case-wait-grace/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/601 "*)
        printf '%s\n' '{"number":601,"draft":true,"mergeable":true,"head":{"ref":"feat/wait","sha":"6010601060"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/6010601060/check-runs"*)
        n=$(( $(cat "$COUNT_FILE" 2>/dev/null || printf 0) + 1 ))
        printf '%s' "$n" >"$COUNT_FILE"
        case $n in
            1|2) printf '%s\n' '{"check_runs":[]}' ;;
            3)   printf '%s\n' '{"check_runs":[{"name":"tests","status":"in_progress"}]}' ;;
            *)   printf '%s\n' '{"check_runs":[{"name":"tests","status":"completed","conclusion":"success"}]}' ;;
        esac
        ;;
    *" api repos/owner/repo/commits/6010601060/status"*)
        printf '%s\n' '{"statuses":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-wait-grace/gh"
cat >"$tmp/case-wait-grace/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/case-wait-grace/sleep"
wait_grace_err="$tmp/wait-grace.err"
wait_grace_output=$(COUNT_FILE="$tmp/wait-grace-count" PATH="$tmp/case-wait-grace:$PATH" \
    bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 601 --repo owner/repo --wait-ci --rounds 4 --interval 1 2>"$wait_grace_err")
assert_contains "$wait_grace_output" 'ci=1/1 green pending=0 failing=0' \
    'zero checks right after a push settle once real checks register and complete'
assert_contains "$(cat "$wait_grace_err")" 'treating as pending' \
    '--wait-ci treats zero registered checks as pending during the grace window'
assert_eq '4' "$(cat "$tmp/wait-grace-count")" \
    '--wait-ci polls through all four rounds before the late-arriving check settles'

# A stub that never registers any check at all. After the grace window
# elapses, --wait-ci must report none-configured explicitly -- and stop
# polling rather than burning the rest of the --rounds budget.
mkdir -p "$tmp/case-wait-none"
cat >"$tmp/case-wait-none/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/602 "*)
        printf '%s\n' '{"number":602,"draft":true,"mergeable":true,"head":{"ref":"feat/none","sha":"6020602060"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/6020602060/check-runs"*)
        n=$(( $(cat "$COUNT_FILE" 2>/dev/null || printf 0) + 1 ))
        printf '%s' "$n" >"$COUNT_FILE"
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" api repos/owner/repo/commits/6020602060/status"*)
        printf '%s\n' '{"statuses":[]}'
        ;;
    *" graphql "*)
        printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-wait-none/gh"
cp "$tmp/case-wait-grace/sleep" "$tmp/case-wait-none/sleep"
wait_none_err="$tmp/wait-none.err"
wait_none_output=$(COUNT_FILE="$tmp/wait-none-count" PATH="$tmp/case-wait-none:$PATH" \
    bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 602 --repo owner/repo --wait-ci --rounds 5 --interval 1 2>"$wait_none_err")
assert_contains "$wait_none_output" 'ci=0/0 none-configured pending=0 failing=0' \
    'checks that never register within the grace window report none-configured explicitly'
assert_contains "$(cat "$wait_none_err")" 'reporting none-configured' \
    '--wait-ci names the none-configured outcome in its diagnostic'
assert_eq '3' "$(cat "$tmp/wait-none-count")" \
    '--wait-ci stops at the grace window instead of consuming the full --rounds budget'

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
assert_contains "$graphql_dead_output" 'pr=404 draft=true mergeable=MERGEABLE head=feat/rest sha=2222222222' \
    'REST metadata still produces a digest when GraphQL is depleted'
assert_contains "$graphql_dead_output" 'ci=1/1 green pending=0 failing=0' \
    'REST check runs still produce CI counts when GraphQL is depleted'
assert_contains "$graphql_dead_output" 'threads: unavailable' \
    'thread data is explicitly marked unavailable when GraphQL is depleted'
assert_contains "$(cat "$graphql_dead_err")" 'review-thread data unavailable' \
    'GraphQL depletion names the isolated review-thread capability'
assert_contains "$(cat "$graphql_dead_err")" 'named wait: GraphQL review-thread reset' \
    'GraphQL depletion reports the bounded named wait for that capability'
assert_contains "$graphql_dead_output" 'nitpicks: unavailable' \
    'unavailable thread data makes nitpick de-duplication explicitly unavailable'
assert_not_contains "$graphql_dead_output" 'next: nitpicks' \
    'unavailable thread data never emits an actionable nitpick hint'

# Durable --full artifacts must fail closed when the GraphQL capability is
# unavailable; a synthetic empty threads artifact would be ambiguous downstream.
full_dead_root="$tmp/full-dead"
mkdir -- "$full_dead_root"
chmod 700 -- "$full_dead_root"
full_dead_err="$tmp/full-dead.err"
set +e
full_dead_output=$(PATH="$tmp/case-graphql-dead:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 404 --repo owner/repo --full --tmpdir "$full_dead_root" 2>"$full_dead_err")
full_dead_rc=$?
set -e
assert_eq 1 "$full_dead_rc" '--full fails closed when GraphQL thread data is unavailable'
assert_not_contains "$full_dead_output" 'saved:' '--full does not report durable artifacts after thread failure'
assert_eq no "$( [[ -e "$full_dead_root/pr_404_threads.json" ]] && printf yes || printf no )" \
    '--full never publishes a synthetic empty threads artifact'

# A successful GraphQL response with a missing reviewThreads field is malformed,
# not a rate-limit capability outage, and must preserve raw evidence.
mkdir -p "$tmp/case-graphql-malformed"
cat >"$tmp/case-graphql-malformed/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/707 "*)
        printf '%s\n' '{"number":707,"draft":true,"mergeable":true,"head":{"ref":"feat/malformed","sha":"7070707070"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/7070707070/check-runs"*) printf '%s\n' '{"check_runs":[]}' ;;
    *" api repos/owner/repo/commits/7070707070/status"*) printf '%s\n' '{"statuses":[]}' ;;
    *" graphql "*) printf '%s\n' '{"data":{"repository":{"pullRequest":{}}}}' ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-graphql-malformed/gh"
malformed_err="$tmp/graphql-malformed.err"
set +e
malformed_output=$(PATH="$tmp/case-graphql-malformed:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 707 --repo owner/repo 2>"$malformed_err")
malformed_rc=$?
set -e
assert_eq 1 "$malformed_rc" 'a malformed successful GraphQL response fails closed'
assert_eq '' "$malformed_output" 'a malformed GraphQL response emits no digest'
assert_contains "$(cat "$malformed_err")" 'no reviewThreads' \
    'malformed GraphQL evidence names the missing reviewThreads field'
assert_contains "$(cat "$malformed_err")" 'raw evidence preserved' \
    'malformed GraphQL evidence preserves the raw response for diagnosis'

# Legacy commit-status contexts are part of the CI contract too. A failing and
# pending context must survive REST normalization and affect the digest.
mkdir -p "$tmp/case-legacy-status"
cat >"$tmp/case-legacy-status/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
    *" api repos/owner/repo/pulls/505 "*)
        printf '%s\n' '{"number":505,"draft":false,"mergeable":true,"head":{"ref":"feat/status","sha":"5050505050"},"base":{"ref":"main"}}'
        ;;
    *" api repos/owner/repo/commits/5050505050/check-runs"*)
        printf '%s\n' '{"check_runs":[]}'
        ;;
    *" api repos/owner/repo/commits/5050505050/status"*)
        printf '%s\n' '{"statuses":[{"context":"required/legacy","state":"failure"},{"context":"deploy/pending","state":"pending"}]}'
        ;;
    *"code-scanning/alerts"*) printf '%s\n' '[]' ;;
    *" graphql "*) printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}}}' ;;
    *) printf '%s\n' '[]' ;;
esac
EOF
chmod +x "$tmp/case-legacy-status/gh"
legacy_status_output=$(PATH="$tmp/case-legacy-status:$PATH" bash "$root/agentkit/skills/review-remote-pr/scripts/gh-pr-state.sh" \
    --pr 505 --repo owner/repo)
assert_contains "$legacy_status_output" 'ci=0/2 failing pending=1 failing=1' \
    'failing and pending legacy commit statuses affect CI counts'

finish
