#!/usr/bin/env bash
# bench/live/batch.sh [--harness codex|claude] REF_A REF_B [ISSUES] [TIMEOUT] [issues|prs]: an ABBA-ordered batch
# of live trials, one at a time. The sandbox is shared, so trials never overlap. Each row lands in
# bench/results/live.jsonl as it finishes.
#
# Without --harness: headless trials of kit v1 (REF_A) against kit v2 (REF_B), as before.
# With --harness: interactive tmux trials (trial-tui.sh) of the ak kit at REF_A against the ak kit at REF_B on
# that harness; ISSUES defaults to the two-wave fixture "11 12 13 14" and the scenario argument is not used.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
harness=''
if [[ ${1:-} == --harness ]]; then
    harness=${2:?batch: --harness needs codex or claude}
    [[ $harness == codex || $harness == claude ]] || { printf 'batch: --harness codex|claude\n' >&2; exit 2; }
    shift 2
fi
ref_a=${1:?batch: REF_A and REF_B are required} ref_b=${2:?batch: REF_A and REF_B are required}
default_issues='01 03 04'
[[ -z $harness ]] || default_issues='11 12 13 14'
issues=${3:-$default_issues} timeout_s=${4:-10800} scenario=${5:-issues}
for arm in a b b a a b; do
    case $arm in a) ref=$ref_a ;; b) ref=$ref_b ;; esac
    # A trial that dies before its run (throttling, install) must not cascade into the next one.
    if [[ -n $harness ]]; then
        "$here/trial-tui.sh" --harness "$harness" --ref "$ref" --issues "$issues" --timeout "$timeout_s" || sleep 600
    else
        case $arm in a) kit=v1 ;; b) kit=v2 ;; esac
        "$here/trial.sh" --kit "$kit" --ref "$ref" --issues "$issues" --timeout "$timeout_s" --scenario "$scenario" || sleep 600
    fi
done
python3 "$here/compare.py"
