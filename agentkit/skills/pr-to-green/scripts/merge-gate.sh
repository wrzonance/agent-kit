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
cq_scan_state=''
work_dir=''
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
    local path=$1 label=$2 mode
    mode=$(file_mode "$path") || die "could not inspect $label permissions: $path"
    (( (8#$mode & 0022) == 0 )) || die "$label must not be group- or world-writable: $path"
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO --pr N --head-sha SHA40 --base REF
       --pr-state-digest FILE --provider-result RESULT
       --human-items-decided yes|no --code-quality-scan-state complete|pending
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
        --code-quality-scan-state) (($# >= 2)) || usage; cq_scan_state=$2; shift 2 ;;
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
reject_writable_by_others "$digest_file" '--pr-state-digest'
case $provider_result in
    AUTO_REVIEW|TRIGGERED|ALREADY_SPENT|OBSERVE_ONLY|DISABLED|BLOCKED|NONE) ;;
    *) die "--provider-result is not a recognized transition-engine result: $provider_result" ;;
esac
case $human_decided in yes|no) ;; *) die '--human-items-decided must be yes or no' ;; esac
case $cq_scan_state in complete|pending) ;; *) die '--code-quality-scan-state must be complete or pending' ;; esac
command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
command -v jq >/dev/null 2>&1 || die 'jq is required; gate evidence unavailable'

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/merge-gate.XXXXXX") || die 'could not create work directory'
chmod 700 "$work_dir"
cleanup() { rm -rf -- "$work_dir"; }
trap cleanup EXIT HUP INT TERM

block() { reasons+=("$1"); }

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

# --- Code scanning completion: a scan still in progress can legitimately
# report zero alerts, so completion for the current head must be established
# from a live query before the alert count below is trusted. The digest
# carries no completion field (gh-pr-state.sh is out of scope for this
# change), so this queries gh directly, the same way the live PR-state read
# above does. An unreadable completion signal is BLOCKED, same as an
# unreadable alert count -- never treated as complete. A response with no
# matching github-code-scanning check run is ALSO blocked, never passed
# through as "completed": it is equally consistent with an analysis that has
# not started yet, and absence of readable evidence is never evidence of
# absence. This does not newly block repositories without code scanning
# configured -- their alerts endpoint already 404s, gh-pr-state.sh already
# emits "alerts: code-scanning n/a", and the existing digest check below
# already blocks that as unreadable.
if "$GH_BIN" api "repos/$repo/commits/$head_sha/check-runs?per_page=100" \
    >"$work_dir/cs-runs.json" 2>"$work_dir/api.err"; then
    cs_status=$(jq -r '
      [.check_runs[]? | select((.app.slug // "") == "github-code-scanning")] as $runs |
      if ($runs | length) == 0 then "none"
      elif ($runs | all(.status == "completed")) then "completed"
      else "pending"
      end
    ' "$work_dir/cs-runs.json" 2>/dev/null) || cs_status=''
else
    cs_status=''
fi
case $cs_status in
    completed) ;;
    pending) block 'code-scanning analysis has not completed for the current head' ;;
    none) block 'no code-scanning analysis is recorded for the current head' ;;
    *) block 'code-scanning analysis status is unreadable for the current head' ;;
esac

if grep -qE '^alerts: code-scanning open=[0-9]+$' "$digest_file"; then
    [[ $(sed -nE 's/^alerts: code-scanning open=([0-9]+)$/\1/p' "$digest_file" | head -n 1) == 0 ]] ||
        block 'an open code-scanning alert is attributable to this PR'
else
    block 'code-scanning evidence is unreadable (n/a is never treated as zero findings)'
fi

case $provider_result in
    TRIGGERED) block 'CodeRabbit review is still in flight for the current head' ;;
    BLOCKED) block 'CodeRabbit provider capability plan reported BLOCKED' ;;
esac

[[ $human_decided == yes ]] || block 'an observed human item has no explicit per-item decision'
[[ $cq_scan_state == complete ]] || block 'github-code-quality scan is still pending on the current head'

if ((${#reasons[@]} > 0)); then
    for reason in "${reasons[@]}"; do
        printf 'blocked reason=%s\n' "$reason"
    done
    printf 'gate=BLOCKED pr=%s\n' "$pr"
    exit 1
fi
printf 'gate=PASS pr=%s sha=%s\n' "$pr" "$head_sha"
