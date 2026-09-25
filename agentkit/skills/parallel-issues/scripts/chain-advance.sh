#!/usr/bin/env bash
# Resolve chain bases and prove a stacked PR is safe after retargeting.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly UINT_RE='^[1-9][0-9]*$'
readonly SHA_RE='^[0-9a-f]{40}$'
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
# The compare API's `files` list is paginated; a behind-commit file list at or
# beyond this size is a lower bound, never the full picture, so
# base_advance_is_generated_only treats it as "not generated-only" rather than
# silently passing on a partial read (mirrors gh-pr-state.sh's own cap).
readonly EVIDENCE_LIST_PAGE_CAP=300

MODE=''
REF=''
PR=''
BASE=''
REPO=''
RUN_STATE=''
ISSUE_COMMENTS=''
PR_STATE_DIGEST=''
ACCEPTED_FINDINGS=''
REVIEW_ATTEMPT=''
PUSHED_BRANCH=''
PREDECESSOR_PR=''
EXACT_PUSH_OBSERVED=''
EXACT_PUSH_ERROR=''
GH_BIN=${CHAIN_ADVANCE_GH:-gh}
RETARGET_APPLIED=false
BOUNDARY_SOURCE=''
BOUNDARY_EPOCH=''
BOUNDARY_EVENT=''
# Populated by check_ancestry (issue #577): the last-measured behind_by count
# and whether that gap was proven confined to declared AGENT_GENERATED_PATHS.
ANCESTRY_BEHIND=''
ANCESTRY_GENERATED_ONLY=no
# Populated by check_ci_fresh (issue #577): comma-joined sanitized labels of
# stale checks excused as declared-review-provider residue, or "none".
PROVIDER_CHECK_RESIDUE=none
GENERATED_PATHS=''
GENERATED_PATHS_RESOLVED=''
REVIEW_PROVIDER_NAMES_RESOLVED=''
declare -a REVIEW_PROVIDER_NAMES_DECLARED=()
# Populated by resolve_exemptions_scope (fix batch, issue #577 F2): whether
# the generated-path and provider-check exemptions below are authorized for
# this run. Both exemptions read repository-declared config from the LOCAL
# checkout's .agent/config.env; when --repo names a different repository than
# this checkout, that config describes a stranger repository and must never
# be trusted to excuse ITS behind_by gap or ITS stale checks. "yes" disables
# both exemptions outright; the strict pre-#577 behavior (behind_by must be
# exactly 0, every check must postdate the boundary) still applies.
EXEMPTIONS_DISABLED=no
LOCAL_REPO_SLUG=''
LOCAL_REPO_SLUG_RESOLVED=''
# Populated by resolve_check_run_slugs (fix batch, issue #577 F1): whether the
# per-head check-runs read that identifies provider checks by authenticated
# `.app.slug` (never by display-name substring alone) succeeded, and the
# lowercase check-run name -> space-joined app.slug list it produced.
CHECK_RUN_FETCH_ATTEMPTED=no
CHECK_RUN_FETCH_OK=no
declare -A CHECK_RUN_SLUGS_BY_LOWER_NAME=()

usage() {
    cat <<EOF
Usage:
  $PROGNAME --resolve-base REF
  $PROGNAME --finalization-status --pr N --run-state FILE [--predecessor-pr N]
  $PROGNAME --finalize-successor --pr N --repo OWNER/REPO --run-state FILE \
      --issue-comments FILE --pr-state-digest FILE --accepted-findings FILE \
      --review-attempt FILE --pushed-branch BRANCH [--predecessor-pr N]
  $PROGNAME --retarget --pr N --base B [--repo OWNER/REPO]
  $PROGNAME --recover-closed --pr N --base B [--repo OWNER/REPO]

--resolve-base is read-only and prints the full commit SHA Git resolves for REF.
--finalization-status is the cheap pre-integration guard. It exits 0 only when
the current head and immediate predecessor still match the sealed tuple, or 10
when merge/final verification is needed.
--finalize-successor validates terminal review, final-head CI, accepted-finding,
review-lineage, and exact pushed-head evidence, then records the PR tuple in the
existing run-state file. The caller owns merge/conflict repair and verification.
--retarget first proves the intended base is not ahead of the current head. It
then edits the PR base and proves the new base, ancestry, CI, approval, and
closing-issue linkage before reporting success. Exit 1 means no base edit was
confirmed; exit 2 means the edit succeeded but a later proof failed.
--recover-closed repairs a PR GitHub closed instead of retargeting when its
base branch was deleted (issue #564): it recreates the deleted base ref at
the PR's own recorded base SHA, reopens the PR, retargets it to B, then
deletes the temporary ref. Idempotent -- safe to re-run after a partial
failure, and a no-op success when the PR is already open on B.
EOF
}

die() {
    if [[ $RETARGET_APPLIED == true ]]; then
        printf '%s: retarget applied base=%s; %s\n' "$PROGNAME" "$BASE" "$*" >&2
        exit 2
    fi
    printf '%s: %s\n' "$PROGNAME" "$*" >&2
    exit 1
}

require_value() {
    [[ -n ${2-} ]] || die "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --resolve-base|--resolve-base=*)
                [[ $1 == *=* ]] || require_value "$1" "${2-}"
                [[ -z $MODE ]] || die '--resolve-base cannot be combined with another mode'
                MODE=resolve
                if [[ $1 == *=* ]]; then REF=${1#*=}; shift; else REF=$2; shift 2; fi
                ;;
            --retarget|--recover-closed|--finalize-successor|--finalization-status)
                [[ -z $MODE ]] || die "$1 cannot be combined with another mode"
                MODE=${1#--}
                shift
                ;;
            --pr|--base|--repo|--run-state|--issue-comments|--pr-state-digest|--accepted-findings|--review-attempt|--pushed-branch|--predecessor-pr)
                require_value "$1" "${2-}"
                case $1 in
                    --pr) PR=$2 ;;
                    --base) BASE=$2 ;;
                    --repo) REPO=$2 ;;
                    --run-state) RUN_STATE=$2 ;;
                    --issue-comments) ISSUE_COMMENTS=$2 ;;
                    --pr-state-digest) PR_STATE_DIGEST=$2 ;;
                    --accepted-findings) ACCEPTED_FINDINGS=$2 ;;
                    --review-attempt) REVIEW_ATTEMPT=$2 ;;
                    --pushed-branch) PUSHED_BRANCH=$2 ;;
                    --predecessor-pr) PREDECESSOR_PR=$2 ;;
                    *) die "unexpected argument: $1" ;;
                esac
                shift 2
                ;;
            --pr=*) PR=${1#*=}; shift ;;
            --base=*) BASE=${1#*=}; shift ;;
            --repo=*) REPO=${1#*=}; shift ;;
            --run-state=*) RUN_STATE=${1#*=}; shift ;;
            --issue-comments=*) ISSUE_COMMENTS=${1#*=}; shift ;;
            --pr-state-digest=*) PR_STATE_DIGEST=${1#*=}; shift ;;
            --accepted-findings=*) ACCEPTED_FINDINGS=${1#*=}; shift ;;
            --review-attempt=*) REVIEW_ATTEMPT=${1#*=}; shift ;;
            --pushed-branch=*) PUSHED_BRANCH=${1#*=}; shift ;;
            --predecessor-pr=*) PREDECESSOR_PR=${1#*=}; shift ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die "unexpected argument: $1"
                ;;
            *) die "unexpected argument: $1" ;;
        esac
    done
}

validate_args() {
    [[ $MODE == resolve || $MODE == retarget || $MODE == recover-closed ||
        $MODE == finalize-successor || $MODE == finalization-status ]] ||
        die 'choose exactly one mode: --resolve-base REF, --finalization-status, --finalize-successor, --retarget, or --recover-closed'
    if [[ $MODE == resolve ]]; then
        [[ -n $REF && $REF != -* && $REF != *$'\n'* && $REF != *$'\r'* ]] ||
            die '--resolve-base requires a safe single-line ref'
        [[ -z $PR && -z $BASE && -z $REPO && -z $RUN_STATE && -z $ISSUE_COMMENTS &&
            -z $PR_STATE_DIGEST && -z $ACCEPTED_FINDINGS && -z $REVIEW_ATTEMPT &&
            -z $PUSHED_BRANCH && -z $PREDECESSOR_PR ]] ||
            die '--resolve-base does not accept finalization or PR options'
        return 0
    fi
    if [[ $MODE == finalization-status ]]; then
        [[ $PR =~ $UINT_RE ]] || die '--pr must be a positive integer'
        [[ -n $RUN_STATE ]] || die '--finalization-status requires --run-state'
        [[ -z $PREDECESSOR_PR || ($PREDECESSOR_PR =~ $UINT_RE && $PREDECESSOR_PR != "$PR") ]] ||
            die '--predecessor-pr must be a different positive integer'
        [[ -z $REF && -z $BASE && -z $REPO && -z $ISSUE_COMMENTS && -z $PR_STATE_DIGEST &&
            -z $ACCEPTED_FINDINGS && -z $REVIEW_ATTEMPT && -z $PUSHED_BRANCH ]] ||
            die '--finalization-status accepts only pr, run-state, and predecessor-pr'
        command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
        return 0
    fi
    if [[ $MODE == finalize-successor ]]; then
        [[ $PR =~ $UINT_RE ]] || die '--pr must be a positive integer'
        [[ $REPO =~ $SLUG_RE ]] || die '--repo must look like OWNER/REPO'
        [[ -z $BASE ]] || die '--finalize-successor does not accept --base'
        [[ -n $RUN_STATE && -n $ISSUE_COMMENTS && -n $PR_STATE_DIGEST &&
            -n $ACCEPTED_FINDINGS && -n $PUSHED_BRANCH ]] ||
            die '--finalize-successor requires run-state, issue-comments, pr-state-digest, accepted-findings, and pushed-branch evidence'
        [[ -z $PREDECESSOR_PR || ($PREDECESSOR_PR =~ $UINT_RE && $PREDECESSOR_PR != "$PR") ]] ||
            die '--predecessor-pr must be a different positive integer'
        [[ $PUSHED_BRANCH =~ ^[A-Za-z0-9._/-]+$ && $PUSHED_BRANCH != -* &&
            $PUSHED_BRANCH != /* && $PUSHED_BRANCH != */ && $PUSHED_BRANCH != *..* &&
            $PUSHED_BRANCH != *//* && $PUSHED_BRANCH != *'@{'* ]] ||
            die '--pushed-branch must be a safe branch ref'
        command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
        command -v sha256sum >/dev/null 2>&1 || die 'sha256sum not found on PATH; evidence unavailable'
        return 0
    fi
    [[ $PR =~ $UINT_RE ]] || die '--pr must be a positive integer'
    [[ $BASE =~ ^[A-Za-z0-9._/-]+$ && $BASE != -* && $BASE != /* &&
        $BASE != */ && $BASE != *..* && $BASE != *//* && $BASE != *'@{'* ]] ||
        die '--base must be a safe branch ref'
    [[ -z $REPO || $REPO =~ $SLUG_RE ]] ||
        die '--repo must look like OWNER/REPO'
    [[ -z $RUN_STATE && -z $ISSUE_COMMENTS && -z $PR_STATE_DIGEST && -z $ACCEPTED_FINDINGS &&
        -z $REVIEW_ATTEMPT && -z $PUSHED_BRANCH && -z $PREDECESSOR_PR ]] ||
        die "--$MODE does not accept finalization options"
    command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'
    command -v "$GH_BIN" >/dev/null 2>&1 || die "required tool not found: $GH_BIN"
}

require_owned_evidence() {
    local label=$1 path=$2
    [[ -f $path && ! -L $path && -O $path && -r $path ]] ||
        die "$label is not an owned readable regular file: $path"
}

validate_final_digest() {
    local digest=$1 expected_pr=$2 expected_head=$3 summary summary_count digest_pr digest_head ci_line
    local root acceptance_file command expected matches classification_line
    require_owned_evidence 'PR-state digest' "$digest"
    summary_count=$(grep -cE '^pr=[0-9]+ draft=(true|false) mergeable=[A-Z_]+ head=\S+ sha=[0-9a-f]{40}$' "$digest" || true)
    [[ $summary_count == 1 ]] || die 'PR-state digest requires exactly one canonical PR/head summary'
    summary=$(grep -E '^pr=[0-9]+ draft=(true|false) mergeable=[A-Z_]+ head=\S+ sha=[0-9a-f]{40}$' "$digest")
    digest_pr=$(sed -nE 's/^pr=([0-9]+) .*$/\1/p' <<<"$summary")
    digest_head=$(sed -nE 's/^.* sha=([0-9a-f]{40})$/\1/p' <<<"$summary")
    [[ $digest_pr == "$expected_pr" && $digest_head == "$expected_head" ]] ||
        die "PR-state digest identity differs: expected pr=$expected_pr head=$expected_head, got pr=$digest_pr head=$digest_head"
    [[ $(grep -cE '^base: ref=\S+ behind=[0-9]+ stale=no$' "$digest" || true) == 1 ]] ||
        die 'PR-state digest does not prove a current integrated base'
    [[ $(grep -cE '^ci=' "$digest" || true) == 1 ]] || die 'PR-state digest requires exactly one CI status line'
    ci_line=$(grep -E '^ci=' "$digest")
    [[ $ci_line =~ ^ci=[0-9]+/[0-9]+\ green\ pending=0\ failing=0$ ]] ||
        die "PR-state digest final-head CI is not green: $ci_line"
    [[ $(grep -cE '^finding-classification:' "$digest" || true) == 1 ]] ||
        die 'PR-state digest requires exactly one finding classification line'
    classification_line=$(grep -E '^finding-classification:' "$digest")
    [[ $classification_line == 'finding-classification: cq=known icf=known' ]] ||
        die "PR-state digest finding classification is unavailable: $classification_line"
    ! grep -qE '^ready-eligible=no( |$)' "$digest" || die 'PR-state digest reports ready-eligible=no'
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'could not resolve the repository root'
    acceptance_file=$root/.agent/acceptance.txt
    if [[ -e $acceptance_file || -L $acceptance_file ]]; then
        [[ -f $acceptance_file && ! -L $acceptance_file && -r $acceptance_file ]] ||
            die 'declared acceptance commands are unavailable'
        while IFS= read -r command || [[ -n $command ]]; do
            [[ -n $command ]] || continue
            expected="repo-verify=green acceptance=$command:pass"
            matches=$(awk -v expected="$expected" '$0 == expected { count++ } END { print count + 0 }' "$digest")
            [[ $matches == 1 ]] || die "PR-state digest lacks one passing record for required acceptance command: $command"
        done <"$acceptance_file"
    fi
    while IFS= read -r command; do
        [[ $command == repo-verify=green\ acceptance=*':pass' ]] ||
            die "PR-state digest has an unmet acceptance result: $command"
    done < <(grep -E '^repo-verify=' "$digest" || true)
    printf '%s\n' "$ci_line"
}

check_exact_push() {
    local branch=$1 expected=$2 rows count sha ref
    EXACT_PUSH_OBSERVED=''
    EXACT_PUSH_ERROR=''
    if ! rows=$(git ls-remote --refs origin "refs/heads/$branch" 2>/dev/null); then
        EXACT_PUSH_ERROR="could not read exact pushed branch: origin/$branch"
        return 1
    fi
    count=$(grep -c . <<<"$rows" || true)
    if [[ $count == 0 ]]; then
        EXACT_PUSH_OBSERVED=missing
        return 10
    fi
    if [[ $count != 1 ]]; then
        EXACT_PUSH_ERROR="exact pushed branch proof requires one ref: origin/$branch"
        return 1
    fi
    IFS=$'\t' read -r sha ref <<<"$rows"
    if [[ $ref != "refs/heads/$branch" || ! $sha =~ $SHA_RE ]]; then
        EXACT_PUSH_ERROR="exact pushed branch proof is malformed: origin/$branch"
        return 1
    fi
    EXACT_PUSH_OBSERVED=$sha
    [[ $sha == "$expected" ]] || return 10
}

prove_exact_push() {
    local branch=$1 expected=$2 rc
    if check_exact_push "$branch" "$expected"; then
        return 0
    else
        rc=$?
    fi
    ((rc != 10)) || die "exact pushed branch differs: origin/$branch=$EXACT_PUSH_OBSERVED final=$expected"
    die "$EXACT_PUSH_ERROR"
}

validate_finalization_record() {
    jq -e '
      type == "object" and keys == ["acceptedFindingsSha256","ci","finalHead","issueCommentsSha256",
        "pr","prStateDigestSha256","predecessorFinalHead","predecessorPr","pushedBranch","pushedHead",
        "receipt","reviewAttemptSha256","reviewCoverage","reviewPayload","reviewedHead","version"] and
      .version == 1 and (.pr | type) == "number" and .pr > 0 and
      (.finalHead | test("^[0-9a-f]{40}$")) and .pushedHead == .finalHead and
      (.reviewedHead | test("^[0-9a-f]{40}$")) and (.reviewPayload | type) == "string" and
      (.reviewPayload | length) > 0 and (.pushedBranch | type) == "string" and
      (.receipt == "adversarial" or .receipt == "verified-skip") and
      (if .receipt == "adversarial" then
         (.reviewCoverage | startswith("covered-")) and
         (.reviewAttemptSha256 | test("^[0-9a-f]{64}$"))
       else
         .reviewCoverage == "verified-skip" and .reviewAttemptSha256 == null
       end) and
      (.ci | test("^ci=[0-9]+/[0-9]+ green pending=0 failing=0$")) and
      all(.acceptedFindingsSha256,.issueCommentsSha256,.prStateDigestSha256;
        test("^[0-9a-f]{64}$")) and
      ((.predecessorPr == null and .predecessorFinalHead == null) or
       ((.predecessorPr | type) == "number" and .predecessorPr > 0 and
        (.predecessorFinalHead | test("^[0-9a-f]{40}$"))))
    ' >/dev/null 2>&1
}

finalization_status() {
    local root current_head run_state_script record parent_record parent_head branch push_rc
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'finalization status must run inside a Git worktree'
    current_head=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null) || die 'could not resolve current HEAD'
    run_state_script="$SCRIPT_DIR/../../.shared/scripts/run-state.sh"
    [[ -x $run_state_script ]] || die 'required finalization helper is unavailable'
    if ! record=$($run_state_script get --file "$RUN_STATE" --path "chainFinalizations.$PR" 2>/dev/null) ||
        ! validate_finalization_record <<<"$record"; then
        printf 'finalization=needed pr=%s reason=unsealed\n' "$PR"
        return 10
    fi
    if [[ $(jq -r .pr <<<"$record") != "$PR" || $(jq -r .finalHead <<<"$record") != "$current_head" ]]; then
        printf 'finalization=needed pr=%s reason=head-changed\n' "$PR"
        return 10
    fi
    branch=$(jq -r .pushedBranch <<<"$record")
    push_rc=0
    check_exact_push "$branch" "$current_head" || push_rc=$?
    if ((push_rc != 0)); then
        if ((push_rc == 10)); then
            printf 'finalization=needed pr=%s reason=head-changed\n' "$PR"
            return 10
        fi
        die "$EXACT_PUSH_ERROR"
    fi
    if [[ -z $PREDECESSOR_PR ]]; then
        if [[ $(jq -r '.predecessorPr // ""' <<<"$record") != '' ]]; then
            printf 'finalization=needed pr=%s reason=predecessor-changed\n' "$PR"
            return 10
        fi
    else
        if ! parent_record=$($run_state_script get --file "$RUN_STATE" \
            --path "chainFinalizations.$PREDECESSOR_PR" 2>/dev/null) ||
            ! validate_finalization_record <<<"$parent_record"; then
            printf 'finalization=needed pr=%s reason=predecessor-unsealed\n' "$PR"
            return 10
        fi
        parent_head=$(jq -r .finalHead <<<"$parent_record")
        branch=$(jq -r .pushedBranch <<<"$parent_record")
        push_rc=0
        check_exact_push "$branch" "$parent_head" || push_rc=$?
        if ((push_rc != 0)); then
            if ((push_rc == 10)); then
                printf 'finalization=needed pr=%s reason=predecessor-changed action=finalize-predecessor-first\n' "$PR"
                return 10
            fi
            die "$EXACT_PUSH_ERROR"
        fi
        if [[ $(jq -r '.predecessorPr // ""' <<<"$record") != "$PREDECESSOR_PR" ||
            $(jq -r '.predecessorFinalHead // ""' <<<"$record") != "$parent_head" ]]; then
            printf 'finalization=needed pr=%s reason=predecessor-changed\n' "$PR"
            return 10
        fi
    fi
    printf 'finalization=sealed pr=%s head=%s\n' "$PR" "$current_head"
}

finalize_successor() {
    local root current_head attempt attempt_id reviewed_head review_payload receipt_status receipt_kind receipt_body
    local ledger_out ledger_json entry coverage_status ci_line accepted_status parent_json='' parent_head=''
    local record old_record='' run_state_script review_ledger post_receipt finding_ledger attempt_hash_json=null
    root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'finalization must run inside a Git worktree'
    current_head=$(git -C "$root" rev-parse --verify HEAD 2>/dev/null) || die 'could not resolve current HEAD'
    require_owned_evidence 'issue comments' "$ISSUE_COMMENTS"
    require_owned_evidence 'accepted findings' "$ACCEPTED_FINDINGS"
    ci_line=$(validate_final_digest "$PR_STATE_DIGEST" "$PR" "$current_head")
    prove_exact_push "$PUSHED_BRANCH" "$current_head"

    run_state_script="$SCRIPT_DIR/../../.shared/scripts/run-state.sh"
    review_ledger="$SCRIPT_DIR/../../review-remote-pr/scripts/review-ledger.sh"
    post_receipt="$SCRIPT_DIR/../../review-remote-pr/scripts/post-receipt.sh"
    finding_ledger="$SCRIPT_DIR/../../review-remote-pr/scripts/finding-ledger.sh"
    [[ -x $run_state_script && -x $review_ledger && -x $post_receipt && -x $finding_ledger ]] ||
        die 'required finalization helper is unavailable'

    receipt_status=$($post_receipt status --issue-comments "$ISSUE_COMMENTS") ||
        die 'terminal adversarial-review receipt is unresolved or unavailable'
    receipt_kind=${receipt_status#receipt=}
    receipt_body=$(jq -er --arg marker '<!-- adversarial-review:spent -->' \
        '[.[] | (.body // "") | select(contains($marker))] | select(length == 1) | .[0]' \
        "$ISSUE_COMMENTS" 2>/dev/null) || die 'terminal receipt body is unavailable'
    [[ $(grep -cE "^- Final verified head: $current_head$" <<<"$receipt_body" || true) == 1 ]] ||
        die 'terminal receipt does not bind the final verified head'

    if [[ $receipt_kind == adversarial ]]; then
        [[ -n $REVIEW_ATTEMPT ]] || die 'adversarial finalization requires --review-attempt'
        require_owned_evidence 'review attempt' "$REVIEW_ATTEMPT"
        attempt=$(jq -ce --arg repo "$REPO" --argjson pr "$PR" '
            select(.repo == $repo and .pr == $pr and .state == "completed" and .canonical == true) |
            select(.id | type == "string" and length > 0) |
            select(.head | type == "string" and test("^[0-9a-f]{40}$")) |
            select(.payload | type == "string" and length > 0)' "$REVIEW_ATTEMPT" 2>/dev/null) ||
            die 'review attempt is not a completed immutable snapshot for this PR'
        reviewed_head=$(jq -r .head <<<"$attempt")
        review_payload=$(jq -r .payload <<<"$attempt")
        attempt_id=$(jq -r .id <<<"$attempt")
        [[ $(grep -cE "^- Reviewed head: $reviewed_head$" <<<"$receipt_body" || true) == 1 ]] ||
            die 'terminal receipt does not bind the reviewed head'
        ledger_out=$($review_ledger read --repo "$REPO" --pr "$PR" --comments "$ISSUE_COMMENTS" --repo-root "$root") ||
            die 'review ledger is unavailable'
        ledger_json=$(sed -n '2,$p' <<<"$ledger_out")
        entry=$(jq -ce --arg reviewed "$reviewed_head" --arg payload "$review_payload" '
            [.reviews[] | select(.kind == "adversarial" and .head_sha == $reviewed and
              (.diff_payload // "") == $payload)] | select(length == 1) | .[0]' <<<"$ledger_json") ||
            die 'review ledger does not preserve the immutable reviewed head and payload'
        [[ $(jq -r '.attemptId // ""' <<<"$entry") == "$attempt_id" ]] ||
            die 'review ledger does not preserve the canonical attempt identity'
        [[ $(jq -r '.executionState // "completed"' <<<"$entry") == completed ]] ||
            die 'remote review execution is not completed'
        coverage_status=$($review_ledger status --repo "$REPO" --pr "$PR" --comments "$ISSUE_COMMENTS" \
            --head "$current_head" --kind adversarial --repo-root "$root") ||
            die 'final integrated head is not covered by the original review ledger'
        attempt_hash_json=$(jq -Rn --arg hash "$(sha256sum "$REVIEW_ATTEMPT" | cut -d' ' -f1)" '$hash')
    else
        [[ $receipt_kind == verified-skip ]] || die "unsupported terminal receipt: $receipt_kind"
        [[ $(grep -cE '^- Reviewed head: [0-9a-f]{40}$' <<<"$receipt_body" || true) == 1 ]] ||
            die 'verified-skip receipt requires exactly one reviewed head'
        [[ $(grep -cE '^- Diff payload: .+$' <<<"$receipt_body" || true) == 1 ]] ||
            die 'verified-skip receipt requires exactly one diff payload'
        reviewed_head=$(sed -nE 's/^- Reviewed head: ([0-9a-f]{40})$/\1/p' <<<"$receipt_body")
        review_payload=$(sed -nE 's/^- Diff payload: (.+)$/\1/p' <<<"$receipt_body")
        coverage_status=verified-skip
    fi

    accepted_status=$($finding_ledger status --file "$ACCEPTED_FINDINGS" --repo-root "$root" --head "$current_head") ||
        die 'accepted findings evidence is invalid or its terminal proof is stale'
    [[ $(jq -r '.remediation // ""' <<<"$accepted_status") == complete ]] ||
        die 'accepted findings evidence has incomplete or unknown dispositions'

    if [[ -n $PREDECESSOR_PR ]]; then
        parent_json=$($run_state_script get --file "$RUN_STATE" --path "chainFinalizations.$PREDECESSOR_PR" 2>/dev/null) ||
            die "predecessor finalization is unresolved for PR #$PREDECESSOR_PR"
        validate_finalization_record <<<"$parent_json" || die "predecessor finalization is malformed for PR #$PREDECESSOR_PR"
        [[ $(jq -r .pr <<<"$parent_json") == "$PREDECESSOR_PR" ]] ||
            die 'predecessor finalization PR identity differs'
        parent_head=$(jq -r .finalHead <<<"$parent_json")
        prove_exact_push "$(jq -r .pushedBranch <<<"$parent_json")" "$parent_head"
        git -C "$root" merge-base --is-ancestor "$parent_head" "$current_head" 2>/dev/null ||
            die "final head $current_head does not contain predecessor final head $parent_head; integrate and verify once"
        if [[ $receipt_kind == adversarial ]] &&
            ! git -C "$root" merge-base --is-ancestor "$parent_head" "$reviewed_head" 2>/dev/null; then
            jq -e --arg head "$current_head" --arg reason "merge-down:$parent_head" \
                'any((.coverage // [])[]; .sha == $head and .reason == $reason)' <<<"$entry" >/dev/null ||
                die "review coverage lacks merge-down:$parent_head for final head $current_head"
        fi
    fi

    record=$(jq -cn --argjson pr "$PR" --arg reviewed "$reviewed_head" --arg payload "$review_payload" \
        --arg final "$current_head" --arg branch "$PUSHED_BRANCH" --arg receipt "$receipt_kind" \
        --arg coverage "$coverage_status" --arg ci "$ci_line" \
        --argjson predecessor "${PREDECESSOR_PR:-null}" --arg predecessor_head "$parent_head" \
        --arg accepted_hash "$(sha256sum "$ACCEPTED_FINDINGS" | cut -d' ' -f1)" \
        --arg comments_hash "$(sha256sum "$ISSUE_COMMENTS" | cut -d' ' -f1)" \
        --arg digest_hash "$(sha256sum "$PR_STATE_DIGEST" | cut -d' ' -f1)" \
        --argjson attempt_hash "$attempt_hash_json" '
        {version:1,pr:$pr,predecessorPr:$predecessor,
         predecessorFinalHead:(if $predecessor == null then null else $predecessor_head end),
         reviewedHead:$reviewed,reviewPayload:$payload,finalHead:$final,pushedHead:$final,
         pushedBranch:$branch,receipt:$receipt,reviewCoverage:$coverage,ci:$ci,
         acceptedFindingsSha256:$accepted_hash,issueCommentsSha256:$comments_hash,
         prStateDigestSha256:$digest_hash,reviewAttemptSha256:$attempt_hash}')
    validate_finalization_record <<<"$record" || die 'internal finalization record validation failed'
    old_record=$($run_state_script get --file "$RUN_STATE" --path "chainFinalizations.$PR" 2>/dev/null) || true
    if [[ -n $old_record && $(jq -Sc . <<<"$old_record") == "$(jq -Sc . <<<"$record")" ]]; then
        printf 'finalized pr #%s reviewed=%s final=%s predecessor=%s no-op\n' \
            "$PR" "$reviewed_head" "$current_head" "${parent_head:-none}"
        return 0
    fi
    $run_state_script set --file "$RUN_STATE" --path "chainFinalizations.$PR" --json "$record"
    printf 'finalized pr #%s reviewed=%s final=%s predecessor=%s receipt=%s coverage=%s\n' \
        "$PR" "$reviewed_head" "$current_head" "${parent_head:-none}" "$receipt_kind" "$coverage_status"
}

resolve_base() {
    local resolved
    if ! resolved=$(git rev-parse --verify --end-of-options "${REF}^{commit}" 2>&1); then
        die "could not resolve base ref: $REF${resolved:+: $resolved}"
    fi
    [[ $resolved =~ $SHA_RE ]] || die "Git returned no single full SHA for base ref: $REF"
    printf '%s\n' "$resolved"
}

resolve_repo() {
    [[ -n $REPO ]] && return 0
    REPO=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) ||
        die 'could not derive OWNER/REPO; pass --repo OWNER/REPO'
    [[ $REPO =~ $SLUG_RE ]] || die 'gh repo view returned no usable OWNER/REPO'
}

fetch_pr() {
    "$GH_BIN" pr view "$PR" --repo "$REPO" \
        --json number,baseRefName,headRefName,headRefOid,statusCheckRollup,reviewDecision,reviews,closingIssuesReferences
}

# --recover-closed needs the REST shape, not the porcelain --json projection:
# `gh pr view --json` has no field for the base ref's own recorded SHA
# (only `headRefOid`), and that recorded `base.sha` is exactly the evidence
# a recover-closed run needs to recreate a deleted base branch.
fetch_pr_rest() {
    "$GH_BIN" api "repos/$REPO/pulls/$PR"
}

iso_to_epoch() {
    local value=$1 epoch
    [[ -n $value && $value != null ]] || return 1
    epoch=$(date -u -d "$value" +%s 2> /dev/null) || return 1
    [[ $epoch =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$epoch"
}

# GitHub's timeline is the source of truth for a base edit. A local/provider
# clock read after the edit is not a boundary: it can make the proof impossible
# when CI started during the edit, and it changes on every retry.
timeline_boundary() {
    local timeline event_time epoch
    # `--paginate --slurp` emits an array of page arrays. Flatten it with
    # external jq because gh rejects combining --slurp with its --jq flag.
    timeline=$("$GH_BIN" api "repos/$REPO/issues/$PR/timeline" --paginate --slurp 2>/dev/null | jq 'add') || return 1
    event_time=$(jq -r --arg base "$BASE" '
        def first_nonempty: first(.[] | select(type == "string" and length > 0)) // "";
        [ .[]?
          | select((.event // "") == "base_ref_changed" or (.event // "") == "automatic_base_change_succeeded")
          | ([.base_ref, .baseRefName, .base_ref_name] | first_nonempty) as $event_base
          | select($event_base == "" or $event_base == $base)
          | [(([.created_at, .createdAt] | first_nonempty)), .event] | select(.[0] | length > 0)
        ] | last // empty | @tsv
    ' <<<"$timeline") || return 1
    [[ -n $event_time ]] || return 1
    # Runs inside $(...) in boundary_for, so print the pair; the caller splits.
    local event_kind
    IFS=$'\t' read -r event_time event_kind <<<"$event_time"
    epoch=$(iso_to_epoch "$event_time") || return 1
    printf '%s\t%s\n' "$epoch" "$event_kind"
}

path_has_no_symlink() {
    local path=$1 current='' component
    local -a components
    [[ $path = /* ]] || return 1
    IFS=/ read -r -a components <<<"${path#/}"
    for component in "${components[@]}"; do
        [[ -n $component && $component != . && $component != .. ]] || return 1
        current+="/$component"
        [[ ! -L $current ]] || return 1
    done
}

boundary_file() {
    local git_dir safe_base
    git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || return 1
    [[ $git_dir = /* && -d $git_dir ]] || return 1
    path_has_no_symlink "$git_dir" || return 1
    safe_base=${BASE//\//-}
    printf '%s/chain-advance-evidence/chain-advance-pr-%s-base-%s.json\n' \
        "$git_dir" "$PR" "$safe_base"
}

persist_boundary() {
    local file dir tmp
    file=$(boundary_file) || return 1
    path_has_no_symlink "$file" || return 1
    dir=${file%/*}
    if [[ -e $dir ]]; then
        [[ -d $dir && ! -L $dir ]] || return 1
    else
        mkdir -p -- "$dir" || return 1
    fi
    path_has_no_symlink "$file" || return 1
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || return 1
    tmp=$(mktemp "$dir/.chain-advance-boundary.XXXXXX") || return 1
    if ! jq -n --argjson pr "$PR" --arg base "$BASE" --arg head "$1" \
        --argjson boundary "$2" --arg event "$BOUNDARY_EVENT" \
        '{pr:$pr,base:$base,headSha:$head,boundaryEpoch:$boundary,boundaryEvent:$event}' >"$tmp"; then
        rm -f -- "$tmp"
        return 1
    fi
    if ! chmod 600 -- "$tmp" || ! mv -f -- "$tmp" "$file"; then
        rm -f -- "$tmp"
        return 1
    fi
}

persisted_boundary() {
    local file value
    file=$(boundary_file) || return 1
    path_has_no_symlink "$file" || return 1
    [[ -f $file && ! -L $file ]] || return 1
    value=$(jq -r --argjson pr "$PR" --arg base "$BASE" --arg head "$1" '
        select(.pr == $pr and .base == $base and .headSha == $head)
        | .boundaryEpoch as $epoch
        | select($epoch | type == "number" and floor == . and . > 0)
        | [$epoch, (.boundaryEvent // "persisted")] | @tsv
    ' "$file" 2>/dev/null) || return 1
    [[ ${value%%$'\t'*} =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$value"
}

# The proof line is consumed by authorize-queue.sh from the root checkout, so
# it lives under the Git COMMON dir where every worktree of this repository
# resolves it; the boundary JSON above is per-invocation retry state and stays
# under the worktree's own git dir (--absolute-git-dir). Two paths on purpose.
#
# issue #607 review: the Git common dir is shared by every checkout on this
# machine regardless of which remote it points at, so a bare pr/base filename
# collides across repositories -- a proof persisted for OTHER/REPO's PR #15
# would silently authorize THIS/REPO's PR #15 at the same base. The repo slug
# is folded into the filename (never trusted alone; see the repo= token
# below) so a cross-repo collision fails the filename match outright.
proof_file() {
    local common
    common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
    [[ $common = /* && -d $common ]] && path_has_no_symlink "$common" || return 1
    [[ $REPO =~ $SLUG_RE ]] || return 1
    printf '%s/chain-advance-evidence/chain-advance-%s-pr-%s-base-%s.proof\n' \
        "$common" "${REPO//\//-}" "$PR" "${BASE//\//-}"
}

persist_proof_line() {
    local file dir
    file=$(proof_file) || return 1
    path_has_no_symlink "$file" || return 1
    dir=${file%/*}
    if [[ -e $dir ]]; then
        [[ -d $dir && ! -L $dir ]] || return 1
    else
        mkdir -p -- "$dir" || return 1
    fi
    path_has_no_symlink "$file" || return 1
    [[ ! -L $file && ( ! -e $file || -f $file ) ]] || return 1
    (umask 077; printf '%s\n' "$1" >>"$file")
}

boundary_for() {
    local head_sha=$1 boundary
    if boundary=$(timeline_boundary); then
        BOUNDARY_SOURCE=timeline
        IFS=$'\t' read -r BOUNDARY_EPOCH BOUNDARY_EVENT <<<"$boundary"
        # Keep persistence fail-closed: a timeline value can authorize this
        # proof, but silently dropping its retry provenance would make a later
        # run unable to distinguish a fresh boundary from an untrusted cache.
        persist_boundary "$head_sha" "$BOUNDARY_EPOCH" ||
            die 'could not persist the retarget boundary evidence'
    elif boundary=$(persisted_boundary "$head_sha"); then
        BOUNDARY_SOURCE=persisted
        IFS=$'\t' read -r BOUNDARY_EPOCH BOUNDARY_EVENT <<<"$boundary"
    else
        die 'could not read a base_ref_changed or automatic_base_change_succeeded timeline event or persisted retarget boundary; evidence provenance is unavailable'
    fi
}

# Repository slug this checkout belongs to (issue #577 F2): AGENT_REPO_SLUG when declared, else a live `gh repo view`, else the `origin` remote URL, resolved once per process.
# An unresolvable slug leaves LOCAL_REPO_SLUG empty and resolve_exemptions_scope fails OPEN (courtesy fallback only -- a properly onboarded repository always has AGENT_REPO_SLUG, which is what actually closes the cross-repo hole below).
resolve_local_repo_slug() {
    [[ -z $LOCAL_REPO_SLUG_RESOLVED ]] || return 0
    LOCAL_REPO_SLUG_RESOLVED=1
    local repo_root resolver slug='' origin_url
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ -n $repo_root ]] || return 0
    resolver="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    if [[ -x $resolver ]]; then
        slug=$("$resolver" --repo-root "$repo_root" --get AGENT_REPO_SLUG 2>/dev/null) || slug=''
    fi
    if [[ -z $slug ]]; then
        slug=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || slug=''
    fi
    if [[ -z $slug ]]; then
        origin_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || origin_url=''
        slug=$(parse_origin_slug "$origin_url") || slug=''
    fi
    [[ $slug =~ $SLUG_RE ]] || return 0
    LOCAL_REPO_SLUG=${slug,,}
}

# Extracts OWNER/REPO from a `git@host:owner/repo(.git)`, `ssh://host/owner/repo`,
# or `https://host/owner/repo(.git)` remote URL. Prints nothing and fails on
# any other shape rather than guessing.
parse_origin_slug() {
    local url=${1:-}
    [[ -n $url ]] || return 1
    if [[ $url =~ ^git@[^/:]+:([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(\.git)?/?$ ]] ||
        [[ $url =~ ^ssh://[^/]+/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(\.git)?/?$ ]] ||
        [[ $url =~ ^https?://[^/]+/([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)(\.git)?/?$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# Gates both #577 exemptions (generated-path behind_by tolerance and
# provider-check residue) to the repository this checkout actually declares
# them for (fix batch, F2). AGENT_GENERATED_PATHS/AGENT_REVIEW_PROVIDERS are
# read from THIS checkout's .agent/config.env regardless of which repository
# --repo names; without this gate, running chain-advance.sh --repo
# OTHER/REPO from a checkout of THIS repo would excuse OTHER/REPO's behind_by
# gap and stale checks using rules it never declared. Only a resolvable,
# mismatching local slug disables the exemptions -- an unresolvable one fails
# open, consistent with resolve_review_provider_names/resolve_generated_paths.
resolve_exemptions_scope() {
    resolve_local_repo_slug
    if [[ -n $LOCAL_REPO_SLUG && $LOCAL_REPO_SLUG != "${REPO,,}" ]]; then
        EXEMPTIONS_DISABLED=yes
        printf 'exemptions=disabled reason=repo-mismatch\n' >&2
    fi
}

# The declared-provider identity's accepted GitHub App slug(s) -- the same
# catalog review-provider-catalog.sh's review_provider_login() encodes,
# widened to accept both the app's actual slug ("coderabbitai") and the
# repository-declared name itself ("coderabbit") since a check-run's own
# `.app.slug` is authenticated forge data this repository does not control
# the exact spelling of. Kept in this one function so the catalog is never
# duplicated across callers.
provider_app_slugs() {
    case $1 in
        coderabbit) printf '%s\n' 'coderabbitai coderabbit' ;;
        github-code-quality) printf '%s\n' 'github-code-quality' ;;
        *) return 1 ;;
    esac
}

# Resolves the repository-declared review-provider names (issue #577), once
# per process. Mirrors gh-pr-state.sh/repo-config.sh's own fail-open contract:
# a missing worktree, resolver, or declaration just leaves the exemption below
# inert -- never a die, since this is an ADVISORY exclusion list, not a proof
# input on its own (check_ci_fresh still refuses every check that isn't
# excused this way). repo-config.sh's own providers_valid already restricts
# declared names to the catalog set, so no further validation is needed here.
resolve_review_provider_names() {
    [[ -z $REVIEW_PROVIDER_NAMES_RESOLVED ]] || return 0
    REVIEW_PROVIDER_NAMES_RESOLVED=1
    local repo_root resolver declared name
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ -n $repo_root ]] || return 0
    resolver="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    [[ -x $resolver ]] || return 0
    declared=$("$resolver" --repo-root "$repo_root" --get AGENT_REVIEW_PROVIDERS 2>/dev/null) || declared=''
    [[ -n $declared ]] || return 0
    local -a names=()
    IFS=, read -ra names <<<"$declared"
    for name in "${names[@]}"; do
        name=$(printf '%s' "$name" | tr -d '[:space:]')
        [[ -n $name && $name != none ]] || continue
        REVIEW_PROVIDER_NAMES_DECLARED+=("$name")
    done
}

# Reads the head commit's own check-runs (fix batch, issue #577 F1) so
# is_provider_residue_check can match a stale rollup entry to its
# authenticated `.app.slug`, never to display-name text alone -- a required
# job merely NAMED like a provider (e.g. "CodeRabbit compatibility tests")
# must never be excused. `--paginate` emits one JSON object per page; `jq -s`
# slurps every page before flattening `.check_runs[]`, exactly like
# code-quality-state.sh's own check-runs read. Resolved once per process;
# CHECK_RUN_FETCH_OK stays "no" on any read or parse failure so callers fail
# CLOSED (no exemption) rather than trust a partial or unreadable response.
resolve_check_run_slugs() {
    local head_sha=$1 check_runs_json tsv name slug lower
    [[ $CHECK_RUN_FETCH_ATTEMPTED == no ]] || return 0
    CHECK_RUN_FETCH_ATTEMPTED=yes
    if ! check_runs_json=$("$GH_BIN" api "repos/$REPO/commits/$head_sha/check-runs?per_page=100" \
        --paginate -H 'X-GitHub-Api-Version: 2026-03-10' 2>/dev/null); then
        return 1
    fi
    tsv=$(jq -r -s '
        [.[]? | select(type == "object") | .check_runs[]? | select(type == "object")]
        | .[] | [(.name // ""), (.app.slug // "")] | @tsv
    ' <<<"$check_runs_json" 2>/dev/null) || return 1
    CHECK_RUN_FETCH_OK=yes
    while IFS=$'\t' read -r name slug; do
        [[ -n $name ]] || continue
        lower=${name,,}
        if [[ -n ${CHECK_RUN_SLUGS_BY_LOWER_NAME[$lower]+yes} ]]; then
            CHECK_RUN_SLUGS_BY_LOWER_NAME[$lower]+=" $slug"
        else
            CHECK_RUN_SLUGS_BY_LOWER_NAME[$lower]=$slug
        fi
    done <<<"$tsv"
    return 0
}

# True when LABEL (a statusCheckRollup name/context) names a check-run whose
# OWN `.app.slug` belongs to a declared review provider's catalog entry (fix
# batch, issue #577 F1). Never matches on label text alone: a check-run must
# exist with that exact name (case-insensitive), and its slug must be in the
# catalog for one of the names AGENT_REVIEW_PROVIDERS declared. Fails closed
# (returns 1, no exemption) whenever the repo-scope guard disabled
# exemptions, no provider is declared, or the check-runs read itself was
# unreadable -- resolve_check_run_slugs is expected to have already been
# attempted by the caller for the current head.
is_provider_residue_check() {
    local label=$1 lower name slugs slug check_slug
    [[ $EXEMPTIONS_DISABLED != yes ]] || return 1
    resolve_review_provider_names
    ((${#REVIEW_PROVIDER_NAMES_DECLARED[@]})) || return 1
    [[ $CHECK_RUN_FETCH_OK == yes ]] || return 1
    lower=${label,,}
    [[ -n ${CHECK_RUN_SLUGS_BY_LOWER_NAME[$lower]+yes} ]] || return 1
    for name in "${REVIEW_PROVIDER_NAMES_DECLARED[@]}"; do
        slugs=$(provider_app_slugs "$name") || continue
        for slug in $slugs; do
            for check_slug in ${CHECK_RUN_SLUGS_BY_LOWER_NAME[$lower]}; do
                [[ $slug == "$check_slug" ]] && return 0
            done
        done
    done
    return 1
}

# gh pr edit --base leaves headRefOid untouched and does not re-run CI, so a
# current-head digest alone cannot prove post-retarget CI: the rollup's
# timestamp must postdate the forge timeline boundary. EXCEPTION (issue #577,
# agent-kit#572): a check from an app whose authenticated .app.slug
# (resolve_check_run_slugs -- never a display-name substring, fix batch F1) is a
# declared AGENT_REVIEW_PROVIDERS entry is reported as provider-check residue
# and excused, like approval=residue:stale; a base edit never re-pings a
# provider, so requiring it made the proof unsatisfiable. Both exemptions are
# disabled when this checkout's repository is not --repo
# (resolve_exemptions_scope, F2), and this one fails closed
# (provider-check=unreadable) when the check-runs read fails.
check_ci_fresh() {
    local pr_json=$1 boundary=$2 head_sha=$3 stale_raw label
    local -a stale_labels=() residue_labels=()
    stale_raw=$(jq -r --argjson boundary "$boundary" '
        def first_nonempty: first(.[] | select(type == "string" and length > 0)) // "";
        [ .statusCheckRollup[]?
          | ([.startedAt, .started_at, .createdAt, .created_at] | first_nonempty) as $ts
          | ([.name, .context] | first_nonempty) as $raw_label
          | (if $raw_label == "" then "unnamed check" else $raw_label end
             | gsub("\r\n|\r|\n"; " ")) as $label
          | if ($ts | length) == 0 then $label
            else ($ts | fromdateiso8601) as $epoch
                 | if $epoch <= $boundary then $label else empty end
            end
        ] | join("\n")
    ' <<<"$pr_json") ||
        die 'check rollup timestamps were unreadable; CI provenance is unavailable'
    resolve_review_provider_names
    if [[ -n $stale_raw && $EXEMPTIONS_DISABLED != yes &&
        ${#REVIEW_PROVIDER_NAMES_DECLARED[@]} -gt 0 ]]; then
        resolve_check_run_slugs "$head_sha" || true
    fi
    while IFS= read -r label; do
        [[ -n $label ]] || continue
        if is_provider_residue_check "$label"; then
            local sanitized
            sanitized=$(sanitize_label "$label")
            residue_labels+=("${sanitized// /_}")
        else
            stale_labels+=("$label")
        fi
    done <<<"$stale_raw"
    if ((${#stale_labels[@]})); then
        local joined='' unreadable_note=''
        for label in "${stale_labels[@]}"; do
            joined+="${joined:+, }$label"
        done
        if [[ $CHECK_RUN_FETCH_ATTEMPTED == yes && $CHECK_RUN_FETCH_OK != yes ]]; then
            unreadable_note=' provider-check=unreadable'
        fi
        die "CI evidence predates the retarget (stale: $joined)$unreadable_note; re-run CI against the new base -- a stale digest is a stop signal, not a green result"
    fi
    if ((${#residue_labels[@]})); then
        local residue_joined='' residue_item
        for residue_item in "${residue_labels[@]}"; do
            residue_joined+="${residue_joined:+,}$residue_item"
        done
        PROVIDER_CHECK_RESIDUE=$residue_joined
    else
        PROVIDER_CHECK_RESIDUE=none
    fi
}

# Approval is provider policy, not mechanical base safety (issue #455): a
# trigger/observe provider settles on the current head only after the
# ready/provider transition that follows this proof, and a disabled/none
# provider may never produce one at all. Blocking retarget on approval made
# both cases unsatisfiable, so this reports one of four tokens instead of
# dying: `current:post-retarget` (an APPROVED review both on the current head
# and submitted after the retarget boundary -- both conditions must hold for
# ONE review; splitting them across two existential checks would pass a PR
# carrying a stale approval of the current head plus a fresh approval of some
# older commit, where no single review is both), `residue:stale` (an APPROVED
# review exists but none satisfies both conditions -- pre-retarget residue,
# never counted as current), `none` (no APPROVED review at all), or `unknown`
# (review evidence was unreadable). The caller decides what, if anything, this
# token requires.
describe_approval() {
    local pr_json=$1 head_sha=$2 boundary=$3 result
    result=$(jq -r --arg head "$head_sha" --argjson boundary "$boundary" '
        def review_sha: (if (.commit | type) == "object" then .commit.oid
                          elif (.commit | type) == "string" then .commit
                          else .commitId end // "") | tostring;
        def review_ts: (.submittedAt // .submitted_at // "");
        (.reviews // []) as $reviews
        | (any($reviews[]; .state == "APPROVED")) as $any_approved
        | (any($reviews[]; (.state == "APPROVED") and (review_sha == $head)
                and ((review_ts | length) > 0)
                and ((review_ts | fromdateiso8601) > $boundary))) as $current_fresh
        | if $current_fresh then "current:post-retarget"
          elif $any_approved then "residue:stale"
          else "none" end
    ' <<<"$pr_json") || result=unknown
    [[ $result =~ ^(current:post-retarget|residue:stale|none)$ ]] || result=unknown
    printf '%s\n' "$result"
}

# Resolves the repository-declared generated-path prefixes (issue #577),
# once per process. Same fail-open contract as resolve_review_provider_names
# above: this is only ever an ADVISORY exemption from staleness, never a proof
# input on its own, so a missing worktree/resolver/declaration just leaves it
# inert (the caller's own strict behind==0 check still applies).
resolve_generated_paths() {
    [[ -z $GENERATED_PATHS_RESOLVED ]] || return 0
    GENERATED_PATHS_RESOLVED=1
    local repo_root resolver
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    [[ -n $repo_root ]] || return 0
    resolver="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"
    [[ -x $resolver ]] || return 0
    GENERATED_PATHS=$("$resolver" --repo-root "$repo_root" --get AGENT_GENERATED_PATHS 2>/dev/null) || GENERATED_PATHS=''
}

# Prefix match against declared GENERATED_PATHS, mirroring gh-pr-state.sh's
# matches_automation_path: a trailing slash is a directory prefix, a leading
# './' is normalized away, and an empty/'.' spec matches nothing (never treat
# "no declaration" as "everything is generated").
matches_generated_path() {
    local path=$1 spec
    local -a specs=()
    IFS=, read -ra specs <<<"$GENERATED_PATHS"
    for spec in "${specs[@]}"; do
        [[ -n $spec ]] || continue
        while [[ $spec == ./* ]]; do spec=${spec#./}; done
        while [[ $spec == */ ]]; do spec=${spec%/}; done
        [[ -n $spec && $spec != . ]] || continue
        [[ $path == "$spec" || $path == "$spec/"* ]] && return 0
    done
    return 1
}

# True only when EVERY file BASE gained since it diverged from head_sha (the
# reverse compare's file list -- diff(merge-base(head,BASE), BASE), the same
# direction gh-pr-state.sh's base_advance_is_automation_only reads) matches a
# declared GENERATED_PATHS prefix. Fails closed on anything unreadable,
# unparsable, empty, or possibly truncated at EVIDENCE_LIST_PAGE_CAP -- a
# file count at or above the cap proves only a lower bound, never the full
# list. A renamed file's `previous_filename` must also match, so a rename
# that moves application code INTO a declared path still fails closed.
base_advance_is_generated_only() {
    local head_sha=$1 compare_json file_count
    [[ $EXEMPTIONS_DISABLED != yes ]] || return 1
    resolve_generated_paths
    [[ -n $GENERATED_PATHS ]] || return 1
    compare_json=$("$GH_BIN" api "repos/$REPO/compare/$head_sha...$BASE" 2>/dev/null) || return 1
    jq -e 'type == "object" and has("files") and (.files | type == "array")' \
        <<<"$compare_json" >/dev/null 2>&1 || return 1
    file_count=$(jq -r '.files | length' <<<"$compare_json" 2>/dev/null) || return 1
    [[ $file_count =~ ^[0-9]+$ ]] || return 1
    ((file_count > 0)) || return 1
    ((file_count < EVIDENCE_LIST_PAGE_CAP)) || return 1
    local -a rows=()
    mapfile -t rows < <(jq -r '.files[]? | [(.filename // ""), (.previous_filename // "")] | @tsv' \
        <<<"$compare_json")
    ((${#rows[@]} == file_count)) || return 1
    local row filename previous
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r filename previous <<<"$row"
        [[ -n $filename ]] || return 1
        matches_generated_path "$filename" || return 1
        [[ -z $previous ]] || matches_generated_path "$previous" || return 1
    done
    return 0
}

# EXCEPTION (issue #577): a `behind_by` gap confined entirely to declared
# AGENT_GENERATED_PATHS -- the same declaration gh-pr-state.sh already treats
# as `stale=no` -- is not a real divergence a retarget needs to chase. This
# repository's own post-merge `chore(bench): record tier0 ...` commit put
# every stacked successor at behind_by=1 the moment its predecessor landed,
# costing an extra merge-down + push + CI round per queued merge
# (agent-kit#572). ANCESTRY_BEHIND/ANCESTRY_GENERATED_ONLY report what was
# measured either way, so the retarget proof line always names the gap
# instead of silently absorbing it.
check_ancestry() {
    local head_sha=$1 compare_json behind status generated_only=no
    compare_json=$("$GH_BIN" api "repos/$REPO/compare/$BASE...$head_sha") ||
        die "base...head comparison failed for $BASE...$head_sha"
    behind=$(jq -r '.behind_by // empty' <<<"$compare_json") ||
        die "base...head comparison was not valid JSON for $BASE...$head_sha"
    [[ $behind =~ ^[0-9]+$ ]] ||
        die "base...head comparison omitted behind_by for $BASE...$head_sha"
    if ((behind > 0)); then
        if base_advance_is_generated_only "$head_sha"; then
            generated_only=yes
        else
            die "base...head is stale: $BASE...$head_sha behind_by=$behind"
        fi
    fi
    status=$(jq -r '.status // empty' <<<"$compare_json") ||
        die "base...head comparison could not report status for $BASE...$head_sha"
    if [[ $generated_only == yes ]]; then
        [[ -z $status || $status == ahead || $status == identical ||
            $status == behind || $status == diverged ]] ||
            die "base...head is not an ancestor-safe comparison: status=$status"
    else
        [[ -z $status || $status == ahead || $status == identical ]] ||
            die "base...head is not an ancestor-safe comparison: status=$status"
    fi
    ANCESTRY_BEHIND=$behind
    ANCESTRY_GENERATED_ONLY=$generated_only
}

check_ci() {
    local pr_json=$1 total pass pending failing
    IFS=$'\t' read -r total pass pending failing < <(
        jq -r '
            def bucket:
              if (has("status") or has("conclusion")) then
                if ((.status // "") | ascii_upcase) != "COMPLETED" then "pending"
                elif ((.conclusion // "") | ascii_upcase
                      | . == "SUCCESS" or . == "NEUTRAL" or . == "SKIPPED") then "pass"
                else "fail" end
              else
                if ((.state // "") | ascii_upcase) == "SUCCESS" then "pass"
                elif ((.state // "") | ascii_upcase
                      | . == "PENDING" or . == "EXPECTED" or . == "") then "pending"
                else "fail" end
              end;
            [ .statusCheckRollup[]? | bucket ] as $checks
            | [($checks | length),
               ([$checks[] | select(. == "pass")] | length),
               ([$checks[] | select(. == "pending")] | length),
               ([$checks[] | select(. == "fail")] | length)]
            | @tsv
        ' <<<"$pr_json"
    ) || die 'could not parse statusCheckRollup; CI evidence unavailable'
    [[ $total =~ ^[0-9]+$ && $pass =~ ^[0-9]+$ && $pending =~ ^[0-9]+$ &&
        $failing =~ ^[0-9]+$ ]] || die 'statusCheckRollup counts were malformed; CI evidence unavailable'
    ((total > 0)) || die 'statusCheckRollup is empty; CI evidence unavailable'
    ((pending == 0 && failing == 0)) ||
        die "CI is stale or not green: total=$total pass=$pass pending=$pending failing=$failing"
    printf '%s\t%s\n' "$total" "$pass"
}

# A retry may observe a PR whose base was retargeted by an earlier invocation.
# Do not use the process-local RETARGET_APPLIED flag as the only refresh signal:
# stale or missing code-scanning evidence is the durable proof that a scan still
# needs a post-boundary trigger.
code_scanning_refresh_needed() {
    local pr_json=$1 boundary=$2 needed
    needed=$(jq -r --argjson boundary "$boundary" '
        def is_scan:
          (((.name // .context // "") | ascii_downcase)
           | test("codeql|code[ -]?scanning"));
        def first_nonempty:
          first(.[] | select(type == "string" and length > 0)) // "";
        [ .statusCheckRollup[]?
          | select(is_scan)
          | ([.startedAt, .started_at, .createdAt, .created_at] | first_nonempty)
        ] as $timestamps
        | if ($timestamps | length) == 0 then "yes"
          elif any($timestamps[];
                   . == "" or (try (fromdateiso8601 <= $boundary) catch true))
          then "yes"
          else "no" end
    ' <<<"$pr_json") ||
        die 'code-scanning evidence was unreadable; refresh decision unavailable'
    [[ $needed == yes ]]
}

# Workflow/check names are forge-controlled text. Keep them readable in
# diagnostics while preventing newlines, tabs, and control bytes from becoming
# extra proof lines or terminal escapes. The proof record itself never includes
# these names; it remains one machine-readable line on stdout.
sanitize_label() {
    local value=${1:-}
    value=$(printf '%s' "$value" | LC_ALL=C tr '\r\n' '  ' | LC_ALL=C sed 's/[^[:print:]]/?/g') ||
        value='code-scanning'
    [[ -n $value ]] || value='code-scanning'
    printf '%s' "${value:0:120}"
}

# A base edit does not reliably emit a pull_request workflow event. Refresh
# a code-scanning workflow: rerun a known head-associated run, or dispatch its
# workflow when the API accepts that capability. Missing rollup evidence is
# harmless only when default setup is explicitly not configured.
refresh_code_scanning() {
    local pr_json=$1 head_sha=$2 head_ref=$3 names runs run_id run_name workflows workflow_id
    local default_setup_state safe_run_name safe_name
    names=$(jq -r '
        [.statusCheckRollup[]?
         | select(((.name // .context // "") | ascii_downcase)
                  | test("codeql|code[ -]?scanning"))
         | (.name // .context)] | unique | join("\n")
    ' <<<"$pr_json") || die 'could not identify code-scanning checks; refresh evidence unavailable'
    if [[ -z $names ]]; then
        default_setup_state=$("$GH_BIN" api "repos/$REPO/code-scanning/default-setup" 2>/dev/null) ||
            default_setup_state=''
        default_setup_state=$(jq -er \
            'select(type == "object") | .state | select(type == "string" and length > 0)' \
            <<<"$default_setup_state" 2>/dev/null) || default_setup_state=''
        case $default_setup_state in
            not-configured) return 0 ;;
            configured)
                printf 'cannot-trigger: CodeQL default setup has no dispatch; human action: push a new commit or run CodeQL for %s\n' \
                    "$(sanitize_label "$head_ref")" >&2
                ;;
            *)
                printf 'cannot-trigger: code-scanning default setup state is unreadable; human action: inspect CodeQL default setup for %s\n' \
                    "$(sanitize_label "$head_ref")" >&2
                ;;
        esac
        return 1
    fi
    runs=$("$GH_BIN" api "repos/$REPO/actions/runs?head_sha=$head_sha&per_page=100" 2>/dev/null) ||
        runs='{"workflow_runs":[]}'
    run_id=''
    run_name=''
    while IFS=$'\t' read -r candidate_id candidate_name; do
        [[ -n $candidate_id ]] || continue
        run_id=$candidate_id
        run_name=$candidate_name
        break
    done < <(jq -r --arg names "$names" '
        .workflow_runs[]?
        | select(((.name // .path // "") | ascii_downcase)
                 | test("codeql|code[ -]?scanning"))
        | [(.id // ""), (.name // .path // "code-scanning")] | @tsv
    ' <<<"$runs" 2>/dev/null || true)

    if [[ -n $run_id ]]; then
        if "$GH_BIN" api --method POST "repos/$REPO/actions/runs/$run_id/rerun" \
            >/dev/null 2>&1; then
            printf 'analysis-refresh=rerun workflow=%s run=%s\n' \
                "$(sanitize_label "$run_name")" "$run_id" >&2
            return 0
        fi
        safe_run_name=$(sanitize_label "$run_name")
        printf 'cannot-trigger: %s rerun unavailable; human action: open Actions, rerun the %s workflow for head %s\n' \
            "$safe_run_name" "$safe_run_name" "$head_sha" >&2
        return 1
    fi

    workflows=$(
        "$GH_BIN" api "repos/$REPO/actions/workflows?per_page=100" 2>/dev/null
    ) || workflows='{"workflows":[]}'
    workflow_id=$(jq -r '
        [.workflows[]?
         | select(((.name // .path // "") | ascii_downcase)
                  | test("codeql|code[ -]?scanning"))
         | .id] | first // empty
    ' <<<"$workflows" 2>/dev/null) || workflow_id=''
    if [[ $workflow_id =~ ^[1-9][0-9]*$ ]]; then
        if "$GH_BIN" api --method POST "repos/$REPO/actions/workflows/$workflow_id/dispatches" \
            -f "ref=$head_ref" >/dev/null 2>&1; then
            printf 'analysis-refresh=dispatch workflow=%s ref=%s\n' \
                "$(sanitize_label "${names%%$'\n'*}")" "$(sanitize_label "$head_ref")" >&2
            return 0
        fi
    fi
    safe_name=$(sanitize_label "${names%%$'\n'*}")
    printf 'cannot-trigger: %s has no dispatch; human action: open the CodeQL workflow and run it manually for %s, or update its path filter to include this PR\n' \
        "$safe_name" "$(sanitize_label "$head_ref")" >&2
    return 1
}

closing_issue_count() {
    jq -r '
        (.closingIssuesReferences // []) as $references
        | (if ($references | type) == "array" then $references
           else ($references.nodes // []) end)
        | length
    ' <<<"$1"
}

# Best-effort review-ledger lineage hook (issue #567 spec item 2): a retarget
# is exactly the kind of post-receipt transition covered_heads exists to
# record, so a later merge-gate.sh read of this PR's ledger can see this head
# as an explicit, ancestry-proven transition instead of a stale gap. Kept
# deliberately minimal and additive here -- it does its own comments fetch
# and never touches the retarget proof above, which is already durable
# evidence on its own. #564 owns the fuller call-site wiring (e.g. threading
# a caller-supplied comments artifact instead of re-fetching one here).
# Never fatal: a missing ledger, a missing sibling script, or a failed post
# only means a later run may still see this PR as stale -- never a reason to
# fail an already-proven retarget.
cover_retarget_lineage() {
    local pr=$1 repo=$2 head_sha=$3 old_base=$4
    local here script repo_root comments_file
    here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd 2>/dev/null) || return 0
    script="$here/../../review-remote-pr/scripts/review-ledger.sh"
    [[ -x $script ]] || return 0
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
    comments_file=$(mktemp "${TMPDIR:-/tmp}/chain-advance-cover.XXXXXXXXXX") || return 0
    chmod 600 -- "$comments_file" 2>/dev/null || true
    # --paginate --slurp emits an array of page arrays, but review-ledger.sh
    # needs one array. External jq flattens it without incompatible gh flags.
    if "$GH_BIN" api "repos/$repo/issues/$pr/comments" --paginate --slurp \
        -H 'Accept: application/vnd.github+json' 2>/dev/null | jq 'add' >"$comments_file" 2>/dev/null; then
        # --kind adversarial (fix batch #2 F3): an unfiltered call extends
        # whichever review entry is LAST in the ledger, which may be a bot
        # entry (e.g. a CodeRabbit record appended after the adversarial
        # receipt) -- leaving the adversarial receipt itself stale for
        # merge-gate.sh. A retarget's lineage belongs on the adversarial
        # entry specifically.
        "$script" cover --repo "$repo" --pr "$pr" --comments "$comments_file" \
            --head "$head_sha" --reason "retarget:$old_base" --kind adversarial \
            --repo-root "$repo_root" \
            >&2 || printf '%s: review-ledger cover not recorded for pr #%s (best-effort, non-fatal)\n' \
                "$PROGNAME" "$pr" >&2
    fi
    rm -f -- "$comments_file"
    return 0
}

retarget() {
    local pr_json actual_base old_base head_ref head_sha ci_counts total pass closing_count refreshed_head_sha proof_line
    resolve_repo
    resolve_exemptions_scope
    pr_json=$(fetch_pr) || die "could not read PR #$PR before retarget"
    actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
        die 'baseRefName was unreadable before retarget'
    old_base=$actual_base
    head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
        die 'headRefOid was unreadable before retarget'
    [[ $head_sha =~ $SHA_RE ]] || die 'head SHA evidence was missing before retarget'
    if [[ $actual_base != "$BASE" ]]; then
        check_ancestry "$head_sha"
        if ! "$GH_BIN" pr edit "$PR" --repo "$REPO" --base "$BASE" >/dev/null; then
            pr_json=$(fetch_pr) ||
                die "could not retarget PR #$PR to base $BASE or re-read the live base"
            actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
                die 'baseRefName was unreadable after the retarget command failed'
            if [[ $actual_base == "$BASE" ]]; then
                RETARGET_APPLIED=true
                die 'retarget command failed after the requested base was applied'
            fi
            die "could not retarget PR #$PR to base $BASE; live base=${actual_base:-missing}"
        fi
        RETARGET_APPLIED=true
        pr_json=$(fetch_pr) || die "could not re-read PR #$PR after retarget"
    fi
    actual_base=$(jq -r '.baseRefName // empty' <<<"$pr_json") ||
        die 'baseRefName was unreadable after retarget'
    [[ $actual_base == "$BASE" ]] ||
        die "baseRefName proof failed: requested=$BASE actual=${actual_base:-missing}"
    head_ref=$(jq -r '.headRefName // empty' <<<"$pr_json") ||
        die 'headRefName was unreadable after retarget'
    head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
        die 'headRefOid was unreadable after retarget'
    [[ -n $head_ref && $head_sha =~ $SHA_RE ]] ||
        die 'head ref/SHA evidence was missing after retarget'
    boundary_for "$head_sha"
    check_ancestry "$head_sha"
    ci_counts=$(check_ci "$pr_json")
    IFS=$'\t' read -r total pass <<<"$ci_counts"
    if [[ $RETARGET_APPLIED == true ]] ||
        code_scanning_refresh_needed "$pr_json" "$BOUNDARY_EPOCH"; then
        if ! refresh_code_scanning "$pr_json" "$head_sha" "$head_ref"; then
            die 'required code-scanning analysis could not be triggered'
        fi
        pr_json=$(fetch_pr) || die "could not re-read PR #$PR after analysis refresh"
        refreshed_head_sha=$(jq -r '.headRefOid // empty' <<<"$pr_json") ||
            die 'headRefOid was unreadable after analysis refresh'
        [[ $refreshed_head_sha == "$head_sha" ]] ||
            die 'pull request head changed after analysis refresh; evidence is stale'
        ci_counts=$(check_ci "$pr_json")
        IFS=$'\t' read -r total pass <<<"$ci_counts"
    fi
    check_ci_fresh "$pr_json" "$BOUNDARY_EPOCH" "$head_sha"
    approval_token=$(describe_approval "$pr_json" "$head_sha" "$BOUNDARY_EPOCH")
    closing_count=$(closing_issue_count "$pr_json") ||
        die 'closingIssuesReferences was unreadable after retarget'
    [[ $closing_count =~ ^[1-9][0-9]*$ ]] ||
        die 'closingIssuesReferences is empty after retarget; linkage evidence is missing'
    proof_line=$(printf 'retargeted pr #%s base=%s head=%s sha=%s repo=%s ci=%s/%s green:post-retarget behind=%s generated-only=%s approval=%s ancestry=verified boundarySource=%s boundaryEvent=%s boundaryEpoch=%s provider-check=%s closing-issues=%s' \
        "$PR" "$BASE" "$head_ref" "$head_sha" "$REPO" "$pass" "$total" "$ANCESTRY_BEHIND" "$ANCESTRY_GENERATED_ONLY" \
        "$approval_token" "$BOUNDARY_SOURCE" "$BOUNDARY_EVENT" "$BOUNDARY_EPOCH" "$PROVIDER_CHECK_RESIDUE" "$closing_count")
    printf '%s\n' "$proof_line"
    persist_proof_line "$proof_line" ||
        printf '%s: could not persist the retarget proof under Git metadata; pass the printed line to authorize-queue.sh --retarget-proof %s:FILE\n' \
            "$PROGNAME" "$PR" >&2
    [[ $RETARGET_APPLIED == true && $old_base != "$BASE" ]] &&
        cover_retarget_lineage "$PR" "$REPO" "$head_sha" "$old_base"
    return 0
}

# Repairs a PR GitHub closed instead of retargeting when its base branch was
# deleted (issue #564 -- `base_ref_deleted` followed by `closed` in the same
# second, observed for #484 and #561). GitHub does not expose the deleted
# branch's tip SHA directly, but the closed PR's own `base.sha` is frozen at
# whatever the base last recorded before deletion -- exactly the evidence
# needed to recreate it. Mechanical state repair only: this never re-runs the
# ancestry/CI/approval/closing-issue proof `retarget` performs -- run
# `--retarget` afterward for that.
recover_closed() {
    local pr_json merged head_sha head_ref state live_base base_sha
    local create_out existing_ref_json existing_sha reopen_out retarget_out delete_out
    local temp_created=false ref_json ref_sha verify_ref_json verify_sha
    resolve_repo
    pr_json=$(fetch_pr_rest) || die "could not read PR #$PR before recovery"
    jq -e 'type == "object"' <<<"$pr_json" >/dev/null 2>&1 ||
        die 'pull request metadata was malformed before recovery'
    merged=$(jq -r '.merged // false' <<<"$pr_json")
    [[ $merged != true ]] || die "pr #$PR is already merged; recovery does not apply"
    head_sha=$(jq -r '.head.sha // empty' <<<"$pr_json")
    head_ref=$(jq -r '.head.ref // empty' <<<"$pr_json")
    [[ $head_sha =~ $SHA_RE ]] || die 'head SHA evidence was missing before recovery'
    state=$(jq -r '.state // empty' <<<"$pr_json")
    live_base=$(jq -r '.base.ref // empty' <<<"$pr_json")
    base_sha=$(jq -r '.base.sha // empty' <<<"$pr_json")

    if [[ $state == open ]]; then
        if [[ $live_base == "$BASE" ]]; then
            printf 'recovered pr #%s base=%s head=%s sha=%s already-open\n' \
                "$PR" "$BASE" "$head_ref" "$head_sha"
            return 0
        fi
        # F3 (issue #564): an earlier invocation may have recreated the base ref
        # and reopened the PR but failed before retargeting. That VERIFIED
        # partial-recovery state (the PR's recorded base.sha still matches the
        # live tip of its current base ref) resumes at the shared retarget step;
        # any other open-on-a-different-base PR is still refused.
        if [[ $base_sha =~ $SHA_RE ]]; then
            ref_json=$("$GH_BIN" api "repos/$REPO/git/ref/heads/$live_base" 2>/dev/null) || ref_json=''
            ref_sha=$(jq -r '.object.sha // empty' <<<"$ref_json" 2>/dev/null) || ref_sha=''
        fi
        [[ -n $ref_sha && $ref_sha == "$base_sha" ]] ||
            die "pr #$PR is open but based on ${live_base:-missing}, not $BASE; this is not a recover-closed case"
        # Verified: fall through to the shared retarget step. temp_created
        # stays false -- this run did not create $live_base, so per F2 it
        # never deletes it; whichever run created it owns that cleanup.
    else
        [[ $state == closed ]] ||
            die "pr #$PR is neither open nor closed (state=${state:-missing}); recovery does not apply"

        [[ -n $live_base ]] ||
            die 'the closed pull request recorded no base ref name; recovery evidence is unavailable'
        [[ $base_sha =~ $SHA_RE ]] ||
            die 'the closed pull request recorded no base SHA; recovery evidence is unavailable'
        [[ $live_base != "$BASE" ]] ||
            die 'the recorded base already equals the requested target; nothing to recover'

        if ! create_out=$("$GH_BIN" api --method POST "repos/$REPO/git/refs" \
            -f "ref=refs/heads/$live_base" -f "sha=$base_sha" 2>&1); then
            existing_ref_json=$("$GH_BIN" api "repos/$REPO/git/ref/heads/$live_base" 2>/dev/null) || existing_ref_json=''
            existing_sha=$(jq -r '.object.sha // empty' <<<"$existing_ref_json" 2>/dev/null) || existing_sha=''
            [[ $existing_sha == "$base_sha" ]] ||
                die "could not recreate the deleted base ref $live_base at $base_sha: $create_out"
        else
            temp_created=true
        fi

        if ! reopen_out=$("$GH_BIN" api --method PATCH "repos/$REPO/pulls/$PR" \
            -f state=open 2>&1); then
            die "could not reopen pr #$PR against recreated base $live_base: $reopen_out"
        fi
        pr_json=$(fetch_pr_rest) || die "could not re-read pr #$PR after reopening"
        [[ $(jq -r '.state // empty' <<<"$pr_json") == open ]] ||
            die "pr #$PR did not report open after the reopen call"
        [[ $(jq -r '.head.sha // empty' <<<"$pr_json") == "$head_sha" ]] ||
            die "pr #$PR head changed during recovery; evidence is stale"
    fi

    if ! retarget_out=$("$GH_BIN" api --method PATCH "repos/$REPO/pulls/$PR" \
        -f "base=$BASE" 2>&1); then
        die "could not retarget pr #$PR to $BASE after reopening: $retarget_out"
    fi
    pr_json=$(fetch_pr_rest) || die "could not re-read pr #$PR after retarget"
    [[ $(jq -r '.base.ref // empty' <<<"$pr_json") == "$BASE" ]] ||
        die "pr #$PR base did not report $BASE after the retarget call"
    [[ $(jq -r '.head.sha // empty' <<<"$pr_json") == "$head_sha" ]] ||
        die "pr #$PR head changed during the retarget call; evidence is stale"

    if [[ $temp_created == true ]]; then
        # F2 (issue #564 fix batch): re-read the exact ref and delete only if
        # it still points at the SHA this run recreated it at -- and only
        # ever a ref this run itself created. A reused pre-existing ref (the
        # "already exists" branch above) is never this run's to delete; it is
        # left for whoever created it, exactly like the resumed-partial-
        # recovery path above.
        verify_ref_json=$("$GH_BIN" api "repos/$REPO/git/ref/heads/$live_base" 2>/dev/null) || verify_ref_json=''
        verify_sha=$(jq -r '.object.sha // empty' <<<"$verify_ref_json" 2>/dev/null) || verify_sha=''
        if [[ $verify_sha == "$base_sha" ]]; then
            if ! delete_out=$("$GH_BIN" api --method DELETE \
                "repos/$REPO/git/refs/heads/$live_base" 2>&1); then
                printf '%s: could not delete the temporary recovery ref %s (non-fatal): %s\n' \
                    "$PROGNAME" "$live_base" "$delete_out" >&2
            fi
        else
            printf '%s: temporary recovery ref %s no longer points at %s (now %s); leaving it in place (non-fatal)\n' \
                "$PROGNAME" "$live_base" "$base_sha" "${verify_sha:-missing}" >&2
        fi
    fi

    printf 'recovered pr #%s base=%s head=%s sha=%s\n' "$PR" "$BASE" "$head_ref" "$head_sha"
}

main() {
    parse_args "$@"
    validate_args
    case $MODE in
        resolve) resolve_base ;;
        finalization-status) finalization_status ;;
        finalize-successor) finalize_successor ;;
        retarget) retarget ;;
        recover-closed) recover_closed ;;
    esac
}

main "$@"
