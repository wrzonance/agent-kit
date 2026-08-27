#!/usr/bin/env bash
# Pre-merge review-completion gate for --auto-merge. Proves every review
# surface (CodeRabbit, code-scanning, github-code-quality, human review) is
# fully complete against the PR's current head before pr-to-green is allowed
# to hand the PR to merge-pr.sh. An unreadable surface is BLOCKED, never
# treated as clean -- see agentkit/skills/pr-to-green/references/auto-merge.md.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
GH_BIN=${MERGE_GATE_GH:-gh}
readonly SHA_RE='^[0-9a-f]{40}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'

repo=''
pr=''
head_sha=''
base=''
digest_file=''
provider_result=''
human_decided=''
adversarial_status=''
cq_scan_state=''
cq_state_file=''
work_dir=''
scan_settling_rounds=${MERGE_GATE_SCAN_ROUNDS:-3}
scan_runs_state=unreadable
scan_runs_names=''
scan_runs_skipped=''
scan_runs_failed=''
declare -a reasons=()

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

# Ownership alone does not protect gate evidence from another user in the
# same group -- reject a file group- or world-writable, matching the
# finding-ledger.sh / post-receipt.sh house style for run-dir artifacts.
file_mode() {
    local path=$1 mode
    if mode=$(stat -c %a -- "$path" 2>/dev/null) && [[ $mode =~ ^[0-7]+$ ]]; then
        printf '%s\n' "$mode"
        return 0
    fi
    if mode=$(stat -f %Lp -- "$path" 2>/dev/null) && [[ $mode =~ ^[0-7]+$ ]]; then
        printf '%s\n' "$mode"
        return 0
    fi
    return 1
}

reject_writable_by_others() {
    local path=$1 label=$2 writer=${3:-} mode
    mode=$(file_mode "$path") || die "could not inspect $label permissions: $path"
    (( (8#$mode & 0022) == 0 )) || die "$label must not be group- or world-writable: $path${writer:+ (written by $writer)}"
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO --pr N --head-sha SHA40 --base REF
       --pr-state-digest FILE --provider-result RESULT
       --human-items-decided yes|no
       --adversarial-review-status STATUS
       [--code-quality-scan-state complete|pending|not-enabled]
       [--code-quality-state-file FILE]

At least one of --code-quality-scan-state or --code-quality-state-file is
required. --code-quality-state-file names a code-quality-state.sh --head
output file (its scan-state=complete|pending|not-enabled|unknown token is
read live). When both are given they must agree, byte-for-byte on the
scan-state token, or the gate refuses outright -- never silently prefers
one over the other.

--adversarial-review-status STATUS (issue #477) takes the verdict word
review-ledger.sh status prints for this PR's current head as the adversarial-
review completion signal, replacing reliance on an operator's memory that a
review happened. STATUS must be one of: covered-head, covered-diff, or
covered-lineage (each passes, exactly like an AUTO_REVIEW/LANDED CodeRabbit
result), stale, absent,
or blocked (each of those three blocks the merge, naming the reason), or
not-required (this repository's adversarial review requirement is disabled;
never re-derived here -- the caller decides that upstream).
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --pr) (($# >= 2)) || usage; pr=$2; shift 2 ;;
        --head-sha) (($# >= 2)) || usage; head_sha=$2; shift 2 ;;
        --base) (($# >= 2)) || usage; base=$2; shift 2 ;;
        --pr-state-digest) (($# >= 2)) || usage; digest_file=$2; shift 2 ;;
        --provider-result) (($# >= 2)) || usage; provider_result=$2; shift 2 ;;
        --human-items-decided) (($# >= 2)) || usage; human_decided=$2; shift 2 ;;
        --adversarial-review-status) (($# >= 2)) || usage; adversarial_status=$2; shift 2 ;;
        --code-quality-scan-state) (($# >= 2)) || usage; cq_scan_state=$2; shift 2 ;;
        --code-quality-state-file) (($# >= 2)) || usage; cq_state_file=$2; shift 2 ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $repo =~ $SLUG_RE ]] || die '--repo must have the form OWNER/REPO'
[[ $pr =~ ^[1-9][0-9]*$ ]] || die '--pr must be a positive integer'
[[ $head_sha =~ $SHA_RE ]] || die '--head-sha must be a full 40-character SHA'
[[ -n $base ]] || die '--base is required'
[[ -f $digest_file && ! -L $digest_file && -O $digest_file ]] ||
    die '--pr-state-digest must be an owned regular file, not a symlink'
reject_writable_by_others "$digest_file" '--pr-state-digest' 'gh-pr-state.sh'
case $provider_result in
    AUTO_REVIEW|TRIGGERED|ALREADY_SPENT|LANDED|STALE_HEAD|OBSERVE_ONLY|DISABLED|BLOCKED|NONE) ;;
    *) die "--provider-result is not a recognized transition-engine result: $provider_result" ;;
esac
case $human_decided in yes|no) ;; *) die '--human-items-decided must be yes or no' ;; esac
[[ -n $adversarial_status ]] || die '--adversarial-review-status is required'
case $adversarial_status in
    covered-head|covered-diff|covered-lineage|stale|absent|blocked|not-required) ;;
    *) die "--adversarial-review-status is not a recognized review-ledger.sh verdict: $adversarial_status" ;;
esac
[[ -n $cq_scan_state || -n $cq_state_file ]] ||
    die '--code-quality-scan-state or --code-quality-state-file is required'
if [[ -n $cq_scan_state ]]; then
    case $cq_scan_state in
        complete|pending|not-enabled) ;;
        *) die '--code-quality-scan-state must be complete, pending, or not-enabled' ;;
    esac
fi
if [[ -n $cq_state_file ]]; then
    [[ -f $cq_state_file && ! -L $cq_state_file && -O $cq_state_file ]] ||
        die '--code-quality-state-file must be an owned regular file, not a symlink'
    reject_writable_by_others "$cq_state_file" '--code-quality-state-file'
fi
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
command -v jq >/dev/null 2>&1 || die 'jq is required; gate evidence unavailable'
[[ $scan_settling_rounds =~ ^[1-9][0-9]*$ && $scan_settling_rounds -le 60 ]] ||
    die 'MERGE_GATE_SCAN_ROUNDS must be an integer from 1 to 60'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate.XXXXXX") || die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

block() { reasons+=("$1"); }

# --- Code Quality scan-state: an optional live helper file reconciled       -
# against (or standing in for) the manually-supplied flag. code-quality-
# state.sh --head SHA is the only sanctioned producer of complete/pending
# (see auto-merge.md); this never re-derives that token itself.
cq_file_state=''
cq_file_reason=''
if [[ -n $cq_state_file ]]; then
    cq_line=$(grep -E '^scan-state=(complete|pending|not-enabled|unknown)( .*)?$' \
        "$cq_state_file" | head -n 1) || true
    [[ -n $cq_line ]] || die 'code-quality state file is malformed (no readable scan-state= line)'
    cq_file_state=$(sed -nE 's/^scan-state=([a-z-]+).*$/\1/p' <<<"$cq_line")
    # complete/pending each require EXACTLY one well-formed, full 40-char
    # head= field, matched via a whole-line anchored regex rather than a
    # loose extraction -- this is what makes it impossible for a
    # findings-on-head=N suffix (which also contains the substring "head=")
    # to be mistaken for the real field, and impossible for a missing,
    # short, or otherwise malformed head= to slip through unchecked
    # (issue #472 review, F2). A mismatch against the live --head-sha is a
    # stale-evidence block; a field that doesn't even parse is malformed
    # evidence and dies outright, exactly like any other unreadable input
    # this gate refuses to guess about.
    case $cq_file_state in
        complete)
            [[ $cq_line =~ ^scan-state=complete\ head=([0-9a-f]{40})\ findings-on-head=[0-9]+$ ]] ||
                die 'code-quality state file is malformed (complete requires a full 40-character head= and findings-on-head=)'
            [[ ${BASH_REMATCH[1]} == "$head_sha" ]] ||
                block 'code-quality state file predates the current head (stale evidence)'
            ;;
        pending)
            [[ $cq_line =~ ^scan-state=pending\ head=([0-9a-f]{40})$ ]] ||
                die 'code-quality state file is malformed (pending requires a full 40-character head=)'
            [[ ${BASH_REMATCH[1]} == "$head_sha" ]] ||
                block 'code-quality state file predates the current head (stale evidence)'
            ;;
        unknown)
            cq_file_reason=$(sed -nE 's/^.*reason=(.*)$/\1/p' <<<"$cq_line")
            ;;
    esac
fi

cq_effective_state=$cq_scan_state
if [[ -n $cq_state_file ]]; then
    if [[ -n $cq_scan_state && $cq_scan_state != "$cq_file_state" ]]; then
        die "--code-quality-scan-state ($cq_scan_state) and --code-quality-state-file ($cq_file_state) disagree"
    fi
    cq_effective_state=$cq_file_state
fi

# --- Live PR state: the freshest possible read, independent of the digest ---
"$GH_BIN" api "repos/$repo/pulls/$pr" >"$work_dir/pr.json" 2>"$work_dir/api.err" ||
    die "pull request metadata unavailable: $(head -n 1 "$work_dir/api.err")"
jq -e --argjson pr "$pr" '
  .number == $pr and
  ((.state | type) == "string") and
  ((.draft | type) == "boolean") and
  ((.head.sha | type) == "string" and (.head.sha | test("^[0-9a-f]{40}$"))) and
  ((.base.ref | type) == "string") and
  ((.mergeable == null) or ((.mergeable | type) == "boolean")) and
  ((.requested_reviewers | type) == "array") and
  ((.requested_teams | type) == "array")
' "$work_dir/pr.json" >/dev/null 2>&1 || die 'pull request metadata was malformed'

live_state=$(jq -r '.state' "$work_dir/pr.json")
live_draft=$(jq -r '.draft' "$work_dir/pr.json")
live_sha=$(jq -r '.head.sha' "$work_dir/pr.json")
live_base=$(jq -r '.base.ref' "$work_dir/pr.json")
live_mergeable=$(jq -r '.mergeable' "$work_dir/pr.json")

[[ $live_state == open ]] || block 'pull request is not open'
[[ $live_draft == false ]] || block 'pull request is still a draft'
[[ $live_sha == "$head_sha" ]] || block 'pull request head changed since evidence was captured'
[[ $live_base == "$base" ]] || block 'pull request base changed since evidence was captured'
[[ $live_mergeable == true ]] || block "pull request is not mergeable (mergeable=$live_mergeable)"

if [[ $(jq -r '(.requested_reviewers | length) + (.requested_teams | length)' "$work_dir/pr.json") != 0 ]]; then
    block 'a requested reviewer is still pending'
fi

# --- Human review decisions: latest actionable review per human reviewer ---
"$GH_BIN" api "repos/$repo/pulls/$pr/reviews?per_page=100" --paginate --slurp \
    >"$work_dir/reviews.raw" 2>"$work_dir/api.err" ||
    die "review evidence unavailable: $(head -n 1 "$work_dir/api.err")"
jq 'if type == "array" and length > 0 and all(.[]; type == "array") then add else . end' \
    "$work_dir/reviews.raw" >"$work_dir/reviews.json" 2>/dev/null ||
    die 'review evidence returned malformed JSON'
jq -e 'type == "array"' "$work_dir/reviews.json" >/dev/null 2>&1 ||
    die 'review evidence returned malformed JSON'

changes_requested=$(jq -r '
  [ .[] | select(((.user.type // "") != "Bot") and
                  (((.user.login // "") | ascii_downcase) | endswith("[bot]") | not)) ] as $human |
  ($human | group_by(.user.login) |
    map(sort_by(.submitted_at // "") |
        map(select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")) |
        last // {state:""}) |
    map(select(.state == "CHANGES_REQUESTED")) | length)
' "$work_dir/reviews.json")
[[ $changes_requested == 0 ]] || block 'a human review is CHANGES_REQUESTED and undecided'

# --- pr-state digest: CI, base freshness, provider threads, findings, alerts ---
if grep -qE '^pr=[0-9]+ draft=(true|false) mergeable=[A-Z_]+ head=\S+ sha=[0-9a-f]{7,40}$' "$digest_file"; then
    digest_pr=$(sed -nE 's/^pr=([0-9]+) .*$/\1/p' "$digest_file" | head -n 1)
    digest_mergeable=$(sed -nE 's/^pr=[0-9]+ draft=(true|false) mergeable=([A-Z_]+) .*$/\2/p' "$digest_file" | head -n 1)
    digest_sha=$(sed -nE 's/^.*sha=([0-9a-f]{7,40})$/\1/p' "$digest_file" | head -n 1)
    [[ $digest_pr == "$pr" ]] || block 'pr-state digest is for a different pull request'
    [[ $digest_mergeable == MERGEABLE ]] || block "pr-state digest reports mergeable=$digest_mergeable"
    # The binding is exactly as strong as whatever length the digest provides
    # -- a 7-char digest still binds a 7-char prefix; once gh-pr-state.sh
    # emits a full 40-char SHA this comparison is full-strength automatically,
    # with no further change here.
    [[ ${head_sha:0:${#digest_sha}} == "$digest_sha" ]] ||
        block 'pr-state digest predates the current head (stale evidence)'
else
    block 'pr-state digest is missing its pr= summary line'
fi

if grep -qE '^base: ref=\S+ behind=[0-9]+ stale=(yes|no)$' "$digest_file"; then
    [[ $(sed -nE 's/^base: ref=\S+ behind=[0-9]+ stale=(yes|no)$/\1/p' "$digest_file" | head -n 1) == no ]] ||
        block 'pull request base is stale'
else
    block 'pr-state digest could not determine base freshness'
fi

if grep -qE '^ci=[0-9]+/[0-9]+ [a-z]+ pending=[0-9]+ failing=[0-9]+$' "$digest_file"; then
    ci_line=$(grep -E '^ci=[0-9]+/[0-9]+ [a-z]+ pending=[0-9]+ failing=[0-9]+$' "$digest_file" | head -n 1)
    ci_word=$(sed -nE 's/^ci=[0-9]+\/[0-9]+ ([a-z]+) .*$/\1/p' <<<"$ci_line")
    ci_pending=$(sed -nE 's/^.*pending=([0-9]+) .*$/\1/p' <<<"$ci_line")
    ci_failing=$(sed -nE 's/^.*failing=([0-9]+)$/\1/p' <<<"$ci_line")
    [[ $ci_word == green && $ci_pending == 0 && $ci_failing == 0 ]] || block 'CI is not fully green'
else
    block 'pr-state digest could not determine CI state'
fi

if grep -qE '^threads: coderabbit=[0-9]+ unresolved  code-quality=[0-9]+ open  human=[0-9]+  generic=[0-9]+' "$digest_file"; then
    threads_line=$(grep -E '^threads: coderabbit=[0-9]+ unresolved  code-quality=[0-9]+ open  human=[0-9]+  generic=[0-9]+' "$digest_file" | head -n 1)
    cr_unresolved=$(sed -nE 's/^threads: coderabbit=([0-9]+) .*$/\1/p' <<<"$threads_line")
    cq_open=$(sed -nE 's/^.*code-quality=([0-9]+) open.*$/\1/p' <<<"$threads_line")
    [[ $cr_unresolved == 0 ]] || block "$cr_unresolved unresolved CodeRabbit thread(s)"
    [[ $cq_open == 0 ]] || block "$cq_open open github-code-quality finding(s)"
else
    block 'pr-state digest carries no readable thread evidence'
fi

if grep -qE '^nitpicks: [0-9]+ unhandled$' "$digest_file"; then
    [[ $(sed -nE 's/^nitpicks: ([0-9]+) unhandled$/\1/p' "$digest_file" | head -n 1) == 0 ]] ||
        block 'a CodeRabbit body nitpick is still unhandled'
else
    block 'pr-state digest carries no readable nitpick evidence'
fi

# --- Code scanning completion: proven from the analyses endpoint, not from
# check-run app slugs. GitHub records workflow-uploaded SARIF (a CodeQL
# workflow, clippy, etc.) under check-run app.slug=github-advanced-security,
# not github-code-scanning -- a slug-only lookup false-blocks every head with
# real, clean analyses recorded that way (issue #390). GET
# code-scanning/analyses is the surface that actually records a completed
# analysis regardless of which app posted the check run, so it is the
# primary signal here; the check-run lookup is kept only as a secondary "is a
# scan still running" signal, demoted from its old load-bearing role, and is
# consulted first precisely because it is never stale the way a matched
# analysis can be (a rerun or a second SARIF upload can already be in flight
# for a head an earlier analysis already covers). A refs/pull/N/merge-ref
# analysis records the GitHub-generated MERGE commit as its commit_sha, not
# the PR's own head SHA -- matching is done against both. Never dispatch a
# workflow to manufacture analysis evidence for this gate -- that is
# gate-gaming, not a remedy (see auto-merge.md).

# Queries code-scanning/analyses for one ref into $2. ref is passed as its
# own -f field, never interpolated into the URL -- a base branch containing
# & or # would otherwise split or truncate the query string. Prints "ok" (a
# readable JSON array, possibly empty), "empty" (the endpoint's definitive
# 404 "no analysis found" body for this ref/repo), or "error" (403, a
# malformed body, or any other unreadable response) -- the caller must treat
# "error" as unreadable, never as "empty".
analyses_for_ref() {
    local ref=$1 out=$2
    if "$GH_BIN" api -X GET "repos/$repo/code-scanning/analyses" -f "ref=$ref" -F per_page=100 \
        >"$out" 2>"$work_dir/api.err"; then
        if jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
            printf 'ok\n'
        else
            printf 'error\n'
        fi
        return 0
    fi
    if jq -e '(.status == "404") and ((.message // "") == "no analysis found")' \
        "$out" >/dev/null 2>&1; then
        printf 'empty\n'
    else
        printf 'error\n'
    fi
    return 0
}

# Queries the repository's own recent analyses with no ref filter (a single
# page, most-recent-first). Used only to discriminate a repository that
# genuinely never scans pull requests from one whose scan for THIS PR
# specifically is missing or failed -- see the scheduled-only branch below.
# Prints "ok" or "error"; there is no meaningful "empty" case here, since an
# empty array is itself a readable (if uninformative) answer. The scheduled-
# only exemption this feeds is bounded by this single page: a repository
# with more than 100 newer schedule-driven analyses could push a genuine
# refs/pull/* entry off page one and past this check. That residual gap is
# still covered by the readable, zero-count alerts-line requirement below --
# a false scheduled-only read still cannot pass with an unread or non-zero
# PR-attributable alert count.
analyses_recent() {
    local out=$1
    if "$GH_BIN" api -X GET "repos/$repo/code-scanning/analyses" -F per_page=100 \
        >"$out" 2>"$work_dir/api.err" &&
        jq -e 'type == "array"' "$out" >/dev/null 2>&1; then
        printf 'ok\n'
        return 0
    fi
    printf 'error\n'
    return 0
}

# Secondary signal: classify code-scanning-related check runs for this head.
# The API failure is deliberately non-authoritative: analysis evidence below
# still decides the gate. A readable all-skipped set is the one safe proof of
# a path-filtered workflow; a failed/cancelled run remains a named block.
scan_check_runs() {
    local runs_file="$work_dir/cs-runs.json"
    scan_runs_state=unreadable
    scan_runs_names=''
    scan_runs_skipped=''
    scan_runs_failed=''
    "$GH_BIN" api "repos/$repo/commits/$head_sha/check-runs?per_page=100" \
        >"$runs_file" 2>"$work_dir/api.err" || return 0
    jq -e 'type == "object" and (.check_runs | type) == "array"' \
        "$runs_file" >/dev/null 2>&1 || return 0

    scan_runs_names=$(jq -r '
      [.check_runs[]
       | select(((.app.slug // "") == "github-code-scanning") or
                ((.app.slug // "") == "github-advanced-security"))
       | (.name // .workflow_name // "code-scanning")] | unique | join(", ")
    ' "$runs_file") || return 0
    if [[ -z $scan_runs_names ]]; then
        scan_runs_state=none
        return 0
    fi
    scan_runs_skipped=$(jq -r '
      [.check_runs[]
       | select(((.app.slug // "") == "github-code-scanning") or
                ((.app.slug // "") == "github-advanced-security"))
       | select((.status // "") == "completed" and (.conclusion // "") == "skipped")
       | (.name // .workflow_name // "code-scanning")] | unique | join(", ")
    ' "$runs_file") || return 0
    scan_runs_failed=$(jq -r '
      [.check_runs[]
       | select(((.app.slug // "") == "github-code-scanning") or
                ((.app.slug // "") == "github-advanced-security"))
       | select((.status // "") == "completed" and
                ((.conclusion // "") | ascii_downcase
                 | IN("failure", "cancelled", "timed_out", "action_required", "stale", "startup_failure")))
       | (.name // .workflow_name // "code-scanning")] | unique | join(", ")
    ' "$runs_file") || return 0
    if jq -e '
      any(.check_runs[]?;
          (((.app.slug // "") == "github-code-scanning") or
           ((.app.slug // "") == "github-advanced-security")) and
          ((.status // "") != "completed"))
    ' "$runs_file" >/dev/null 2>&1; then
        scan_runs_state=pending
    elif [[ -n $scan_runs_failed ]]; then
        scan_runs_state=failed
    elif [[ -n $scan_runs_skipped && $scan_runs_skipped == "$scan_runs_names" ]]; then
        scan_runs_state=not-applicable
    else
        scan_runs_state=terminal
    fi
}

# A pull_request-event CodeQL/SARIF upload sets GITHUB_SHA to the GitHub-
# generated MERGE commit for the refs/pull/N/merge ref, not the PR's own
# head SHA -- so an analysis genuinely recorded against that ref legitimately
# carries merge_commit_sha as its commit_sha, not head_sha. Comparing only
# against head_sha there false-blocked every such PR (issue #390 follow-up).
# Read merge_commit_sha from the PR metadata already fetched above (no
# second call); a null/absent value (not yet computed, or unmergeable) must
# never widen matching, so it is only compared when non-empty. refs/pull/N/head
# is queried too and matched against head_sha alone, for tools whose workflow
# checks out and scans the head ref directly rather than the merge ref.
merge_commit_sha=$(jq -r '.merge_commit_sha // empty' "$work_dir/pr.json")

pr_ref="refs/pull/$pr/merge"
pr_head_ref="refs/pull/$pr/head"
pr_analyses_state=$(analyses_for_ref "$pr_ref" "$work_dir/cs-analyses-pr.json")
pr_head_analyses_state=$(analyses_for_ref "$pr_head_ref" "$work_dir/cs-analyses-pr-head.json")

cs_head_matches=0
if [[ $pr_analyses_state == ok ]]; then
    cs_head_matches=$(jq --arg sha "$head_sha" --arg msha "$merge_commit_sha" '
        [.[] | select(.commit_sha == $sha or ($msha != "" and .commit_sha == $msha))] | length
    ' "$work_dir/cs-analyses-pr.json" 2>/dev/null) || cs_head_matches=''
fi

cs_head_ref_matches=0
if [[ $pr_head_analyses_state == ok ]]; then
    cs_head_ref_matches=$(jq --arg sha "$head_sha" '[.[] | select(.commit_sha == $sha)] | length' \
        "$work_dir/cs-analyses-pr-head.json" 2>/dev/null) || cs_head_ref_matches=''
fi

cs_any_head_match=no
if [[ $cs_head_matches =~ ^[0-9]+$ ]] && ((cs_head_matches > 0)); then
    cs_any_head_match=yes
elif [[ $cs_head_ref_matches =~ ^[0-9]+$ ]] && ((cs_head_ref_matches > 0)); then
    cs_any_head_match=yes
fi

# --- Code scanning non-use corroboration: a repository is only established
# as demonstrably not using code scanning via TWO independent positive
# signals together. Signal 1 (default-setup state == not-configured) is NOT
# sufficient alone -- a repository can run an advanced, workflow-based
# CodeQL setup that uploads SARIF while default-setup still reads
# not-configured, and that repository has genuine code-scanning evidence
# that must keep being gated. Signal 2 is the alerts endpoint's definitive
# 404 "no analysis found" body: GitHub's own readable, structured answer
# that no analysis of any kind has ever been recorded for this repository
# (gh still writes that JSON body to stdout on the non-2xx response). A 403,
# a malformed body, a "configured" state, a 2xx alerts response, or either
# probe simply failing to run leaves this "no" -- n/a is still never read as
# "zero findings" anywhere below.
default_setup_state=''
if "$GH_BIN" api "repos/$repo/code-scanning/default-setup" \
    >"$work_dir/cs-default-setup.json" 2>"$work_dir/api.err"; then
    default_setup_state=$(jq -r '.state // empty' "$work_dir/cs-default-setup.json" 2>/dev/null) ||
        default_setup_state=''
fi
alerts_probe_definitive_404=no
if ! "$GH_BIN" api "repos/$repo/code-scanning/alerts?per_page=1" \
    >"$work_dir/cs-alerts-probe.json" 2>"$work_dir/api.err"; then
    if jq -e '(.status == "404") and ((.message // "") == "no analysis found")' \
        "$work_dir/cs-alerts-probe.json" >/dev/null 2>&1; then
        alerts_probe_definitive_404=yes
    fi
fi
cs_definitively_unused=no
if [[ $default_setup_state == not-configured && $alerts_probe_definitive_404 == yes ]]; then
    cs_definitively_unused=yes
fi

# --- Resolve completion status. scan_check_run_pending is consulted FIRST,
# unconditionally: a still-running check run (either app slug) always blocks
# as pending, even when an earlier or partial analysis already matches the
# current head -- a rerun or a second SARIF upload in flight is real,
# incomplete evidence that a stale "current" read must never mask. Beyond
# that: a matching analysis for the current head wins; otherwise an
# unreadable primary probe blocks; otherwise a repository that plainly runs
# code scanning elsewhere (its base ref carries analyses) AND has never
# recorded an analysis against any refs/pull/* ref is reported scheduled-
# only, not blocked -- a repository whose recent history DOES include a
# pull-request analysis demonstrably scans PRs, so this PR's own missing
# analysis is ambiguous absence, not a schedule, and stays blocked; otherwise
# the two-signal non-use exception above applies; otherwise this is the
# ambiguous "no evidence yet" case, and it blocks.
cs_status=''
cs_last_ref=''
cs_last_date=''
scan_check_runs
if [[ $scan_runs_state == pending ]]; then
    cs_status=pending
elif [[ $scan_runs_state == failed ]]; then
    cs_status=failed
elif [[ $scan_runs_state == not-applicable ]]; then
    cs_status=not-applicable
elif [[ $cs_any_head_match == yes ]]; then
    cs_status=current
elif [[ $pr_analyses_state == error ]]; then
    cs_status=unreadable
else
    base_ref="refs/heads/$base"
    base_analyses_state=$(analyses_for_ref "$base_ref" "$work_dir/cs-analyses-base.json")
    base_has_analyses=no
    if [[ $base_analyses_state == ok ]] &&
        jq -e 'length > 0' "$work_dir/cs-analyses-base.json" >/dev/null 2>&1; then
        base_has_analyses=yes
    fi

    # An unreadable recent-history probe never corroborates scheduled-only --
    # this stays "no" (blocked below, same fail-closed default as everywhere
    # else in this gate) unless the repository's history is actually read
    # and shows no refs/pull/* analysis anywhere in it.
    repo_confirmed_no_pr_scans=no
    if [[ $base_has_analyses == yes ]]; then
        recent_state=$(analyses_recent "$work_dir/cs-analyses-recent.json")
        if [[ $recent_state == ok ]] &&
            ! jq -e 'any(.[]?; (.ref // "") | startswith("refs/pull/"))' \
                "$work_dir/cs-analyses-recent.json" >/dev/null 2>&1; then
            repo_confirmed_no_pr_scans=yes
        fi
    fi

    if [[ $base_has_analyses == yes && $repo_confirmed_no_pr_scans == yes ]]; then
        cs_status=scheduled-only
        cs_last_date=$(jq -r 'sort_by(.created_at // "") | last | .created_at // "unknown"' \
            "$work_dir/cs-analyses-base.json")
        cs_last_ref=$(jq -r --arg r "$base_ref" 'sort_by(.created_at // "") | last | .ref // $r' \
            "$work_dir/cs-analyses-base.json")
    elif [[ $cs_definitively_unused == yes ]]; then
        cs_status=unused
    else
        cs_status=absent
    fi
fi

case $cs_status in
    current|scheduled-only|unused|not-applicable) ;;
    pending)
        printf 'code-scanning: SETTLING rounds=1/%s runs=%s\n' \
            "$scan_settling_rounds" "${scan_runs_names:-code-scanning}"
        block 'code-scanning analysis has not completed for the current head'
        ;;
    failed)
        printf 'code-scanning: FAILED runs=%s\n' "$scan_runs_failed"
        block "scan-failed: $scan_runs_failed"
        ;;
    absent)
        printf 'scan-missing: codeql (human action: inspect the CodeQL workflow and dispatch it or update its path filter)\n'
        block 'no code-scanning analysis is recorded for the current head'
        ;;
    *) block 'code-scanning analysis status is unreadable for the current head' ;;
esac

if [[ $cs_status == scheduled-only ]]; then
    printf 'code-scanning: scheduled-only, last analysis %s on %s\n' "$cs_last_date" "$cs_last_ref"
elif [[ $cs_status == not-applicable ]]; then
    printf 'code-scanning: not-applicable (path-filtered), runs skipped: %s\n' "$scan_runs_skipped"
fi

# A scheduled-only repository is exempt from the completion-status block
# above, but NOT from producing readable PR-attributable alert evidence --
# only the two-signal "never used at all" exception waives that below. n/a
# stays blocked for a scheduled-only repository the same as for any other.
cs_completion_exempt=no
[[ $cs_status == unused ]] && cs_completion_exempt=yes

if grep -qE '^alerts: code-scanning open=[0-9]+$' "$digest_file"; then
    [[ $(sed -nE 's/^alerts: code-scanning open=([0-9]+)$/\1/p' "$digest_file" | head -n 1) == 0 ]] ||
        block 'an open code-scanning alert is attributable to this PR'
elif [[ $cs_completion_exempt != yes ]]; then
    block 'code-scanning evidence is unreadable (n/a is never treated as zero findings)'
fi

case $provider_result in
    TRIGGERED) block 'CodeRabbit review is still in flight for the current head' ;;
    BLOCKED) block 'CodeRabbit provider capability plan reported BLOCKED' ;;
    STALE_HEAD) block 'CodeRabbit review is against a stale head, not evidence for the current head' ;;
esac

# --- Adversarial review completion: review-ledger.sh's own verdict word for
# the current head, taken as-is (never re-derived here -- see auto-merge.md
# for why this gate never re-runs evidence collection itself). covered-head
# and covered-diff are the only passing verdicts, matching AUTO_REVIEW/LANDED
# above; stale/absent/blocked each block and name themselves distinctly so an
# operator can tell "never reviewed" from "reviewed, but not this tree" from
# "the ledger itself is corrupt".
case $adversarial_status in
    covered-head|covered-diff|covered-lineage|not-required) ;;
    stale) block 'adversarial review ledger is stale for the current head (reviewed a different tree)' ;;
    absent) block 'no adversarial review is recorded in the ledger for the current head' ;;
    blocked) block 'adversarial review ledger is present but unparseable (fails closed, never read as absent)' ;;
esac

[[ $human_decided == yes ]] || block 'an observed human item has no explicit per-item decision'
# not-enabled (issue #403) means Code Quality is disabled for the repository
# -- a stable fact, not a scan in flight -- so it gates exactly like
# complete; pending and unknown still block ("unknown" comes only from
# code-quality-state.sh --head reporting an unreadable analysis probe --
# never fabricated here, and never treated as complete).
case $cq_effective_state in
    complete|not-enabled) ;;
    pending) block 'github-code-quality scan is still pending on the current head' ;;
    unknown)
        block "github-code-quality scan state is unknown${cq_file_reason:+ ($cq_file_reason)}"
        ;;
    *) block "github-code-quality scan state is unrecognized: $cq_effective_state" ;;
esac

if ((${#reasons[@]} > 0)); then
    for reason in "${reasons[@]}"; do
        printf 'blocked reason=%s\n' "$reason"
    done
    printf 'gate=BLOCKED pr=%s\n' "$pr"
    exit 1
fi
printf 'gate=PASS pr=%s sha=%s\n' "$pr" "$head_sha"
