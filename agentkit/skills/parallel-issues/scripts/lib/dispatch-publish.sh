#!/usr/bin/env bash
# shellcheck disable=SC2154  # Inputs are validated and assigned by compose-worker-prompt.sh.
# Sourced by compose-worker-prompt.sh --publish: installs the composer's staged
# dispatch-plan update and saves the issue's spec-verification report, so the
# root runs one call instead of transcribing an install recipe before spawn.

dispatch_publish_digest() { sha256sum -- "$1" | cut -d ' ' -f 1; }

# Atomically replaces $2 (the root-owned plan) with the verified staged bytes
# in $1, keeping the plan's mode; the scratch copy lives beside the plan so the
# final rename never crosses a filesystem. Every failure removes both files.
dispatch_publish_install_plan() {
    local update=$1 plan=$2 sha=$3 run_dir=$4 tmp rc=0
    [[ $update == "$output_dir"/* && -f $update && ! -L $update && $(dispatch_publish_digest "$update") == "$sha" ]] ||
        die "staged dispatch-plan update failed verification: $update"
    tmp=$("$run_dir" --scratch-label dispatch-plan --scratch-near "$plan") ||
        { rm -f -- "$update"; die "could not allocate dispatch-plan scratch beside $plan"; }
    { cat -- "$update" >"$tmp" && chmod --reference="$plan" "$tmp" &&
        [[ $(dispatch_publish_digest "$tmp") == "$sha" ]] && mv -f -- "$tmp" "$plan"; } || rc=$?
    rm -f -- "$update" "$tmp" || ((rc != 0)) || rc=1
    ((rc == 0)) || die "could not install dispatch-plan update into $plan"
}

# Writes one owner-private report per issue under PLAN.verification-reports,
# replacing only that issue's file. A zero-step composition writes nothing.
dispatch_publish_report() {
    local report_line=$1 plan=$2 run_dir=$3 reports_dir report tmp
    reports_dir="$plan.verification-reports"
    if [[ -z $report_line ]]; then
        # Zero steps now: drop this issue's report from an earlier composition, never a peer's.
        report="$reports_dir/issue-$issue.report"
        [[ ! -d $reports_dir || -L $reports_dir || ! -O $reports_dir ]] ||
            rm -f -- "$report" || die "could not remove stale verification report $report"
        printf 'none'
        return 0
    fi
    mkdir -m 700 -- "$reports_dir" 2>/dev/null ||
        [[ -d $reports_dir && ! -L $reports_dir && -O $reports_dir ]] ||
        die "unsafe verification-reports directory: $reports_dir"
    chmod 700 -- "$reports_dir" || die "could not secure $reports_dir"
    report="$reports_dir/issue-$issue.report"
    tmp=$("$run_dir" --scratch-label "dispatch-report-$issue" --scratch-near "$report") ||
        die "could not allocate report scratch beside $report"
    if ! { chmod 600 -- "$tmp" && printf '%s\n' "$report_line" >"$tmp" && mv -f -- "$tmp" "$report"; }; then
        rm -f -- "$tmp"; die "could not save verification report $report"
    fi
    [[ -f $report && ! -L $report && -O $report ]] || die "verification report is not owner-private: $report"
    printf '%s' "$report"
}

# $1: the spec-verification line (empty for zero steps). Uses the composer's
# output, dispatch_plan, spec_plan_update, spec_plan_sha, issue, and script_dir.
dispatch_publish() {
    local report_line=$1 run_dir plan_state=unchanged report
    run_dir=$script_dir/../../review-remote-pr/scripts/run-dir.sh
    chmod 600 -- "$output" || die "could not secure prompt file: $output"
    if [[ $spec_plan_update != none ]]; then
        dispatch_publish_install_plan "$spec_plan_update" "$dispatch_plan" "$spec_plan_sha" "$run_dir"
        plan_state=installed
    fi
    [[ $(dispatch_publish_digest "$dispatch_plan") == "$spec_plan_sha" ]] ||
        die 'dispatch-plan verification failed before spawn'
    report=$(dispatch_publish_report "$report_line" "$dispatch_plan" "$run_dir") || exit 1
    printf 'published= issue=%s prompt=%s bytes=%s plan=%s report=%s\n' \
        "$issue" "$output" "$(wc -c <"$output")" "$plan_state" "$report"
}
