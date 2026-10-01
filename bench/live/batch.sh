#!/usr/bin/env bash
# bench/live/batch.sh V1_REF V2_REF [ISSUES] [TIMEOUT] [issues|prs]: an ABBA-ordered batch of live trials, one at a time.
# The sandbox is shared, so trials never overlap. Each row lands in bench/results/live.jsonl as it finishes.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
v1=$1 v2=$2 issues=${3:-01 03 04} timeout_s=${4:-10800} scenario=${5:-issues}
for kit in v1 v2 v2 v1 v1 v2; do
    case $kit in v1) ref=$v1 ;; v2) ref=$v2 ;; esac
    # A trial that dies before its run (throttling, install) must not cascade into the next one.
    "$here/trial.sh" --kit "$kit" --ref "$ref" --issues "$issues" --timeout "$timeout_s" --scenario "$scenario" || sleep 600
done
python3 "$here/compare.py"
