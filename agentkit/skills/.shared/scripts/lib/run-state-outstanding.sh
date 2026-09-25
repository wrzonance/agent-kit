#!/usr/bin/env bash
# Durable outstanding-obligation source validation and snapshot merge for
# run-state.sh. The caller provides die(), SCRIPT_DIR, STATE, and source paths.

derive_outstanding() {
    local source label mode workers plan run_id source_id
    for source in "$WORKER_LEDGER_SOURCE" "$DISPATCH_PLAN"; do
        [[ $source == "$WORKER_LEDGER_SOURCE" ]] && label='worker ledger' || label='dispatch plan'
        [[ ! -L $source && -f $source && -r $source && -O $source ]] || die "$label must be an owned readable regular file: $source"
        mode=$(stat -c %a -- "$source") || die "could not inspect $label: $source"
        (( (8#$mode & 8#077) == 0 )) || die "$label must be owner-private: $source"
    done
    workers=$(jq -sc '.' "$WORKER_LEDGER_SOURCE" 2>/dev/null) || die 'unparseable worker ledger'
    plan=$(jq -ec 'select(type == "object" and (.entries | type) == "array")' "$DISPATCH_PLAN" 2>/dev/null) ||
        die 'dispatch plan must be one JSON object with entries'
    run_id=$(jq -er '.binding.run_id | select(type == "string" and length > 0)' <<<"$STATE" 2>/dev/null) ||
        die 'outstanding derivation requires a bound run state'
    source_id=$(jq -ncS --argjson state "$(jq -c 'del(.orchestration)' <<<"$STATE")" \
        --argjson workers "$workers" --argjson plan "$plan" \
        '[$state,$workers,$plan]' | sha256sum | cut -d ' ' -f 1) || die 'could not fingerprint outstanding sources'

    jq -ec --arg run "$run_id" --arg source_id "durable@$source_id" \
        --argjson workers "$workers" --argjson plan "$plan" \
        -f "$SCRIPT_DIR/lib/run-state-outstanding.jq" <<<"$STATE" ||
        die 'could not derive outstanding obligations from durable sources'
}

merge_outstanding() {
    local snapshot=$1 derived
    [[ -n $WORKER_LEDGER_SOURCE ]] || { printf '%s\n' "$snapshot"; return; }
    derived=$(derive_outstanding)
    jq -ec --argjson derived "$derived" '
        .evidence.id = $derived.evidence_id |
        .actionable_work = (.actionable_work + $derived.actionable_work | unique) |
        .operations = ($derived.operations + .operations | unique_by(.id)) |
        .remaining_work = (.remaining_work + $derived.remaining_work | unique) |
        .completed_work -= $derived.remaining_work
    ' <<<"$snapshot" 2>/dev/null || die 'could not merge durable outstanding obligations'
}

next_action_ownership_overlaps() {
    jq -r '
        ([.operations[].affected[]] | unique) as $owned |
        any(.actionable_work[]; . as $id | $owned | index($id) != null)
    ' <<<"$1"
}

select_next_action() {
    jq -ec '
        . as $snapshot |
        ($snapshot.operations | map(select(.status == "active")) | length) as $active |
        ($snapshot.operations | map(select(.status == "unknown")) | length) as $unknown |
        ([$snapshot.operator_dependencies[].affected[]] | unique) as $operator_affected |
        (if ($snapshot.actionable_work | length) > 0 and $snapshot.evidence.operations_complete then "dispatch"
         elif $unknown > 0 then "reconcile"
         elif $active > 0 then "collect"
         elif (($snapshot.evidence.actionable_complete and $snapshot.evidence.operations_complete) | not)
            then "reconcile"
         elif ($snapshot.remaining_work | length) == 0 then "complete"
         elif ($snapshot.operator_dependencies | length) > 0 and
              (($snapshot.remaining_work - $operator_affected) | length) == 0 then "end-turn"
         else "reconcile" end) as $action |
        {snapshot:$snapshot,
         decision:{next_action:$action,
                   actionable_count:($snapshot.actionable_work | length),
                   active_operations:$active,unknown_operations:$unknown,
                   operator_dependencies:($snapshot.operator_dependencies | length),
                   remaining_count:($snapshot.remaining_work | length),
                   outstanding:($snapshot.remaining_work | length),
                   evidence_id:$snapshot.evidence.id,observed_at:$snapshot.evidence.observed_at,
                   wait_allowed:($action == "collect"),task_complete:($action == "complete"),
                   resume_required:($action != "end-turn" and $action != "complete"),
                   ownership_released:false}}
    ' <<<"$1" 2>/dev/null
}

record_next_action() {
    local snapshot=$1 overlap record next
    snapshot=$(validate_next_action_snapshot "$snapshot") ||
        die 'invalid next-action snapshot; every evidence and work field is required'
    snapshot=$(merge_outstanding "$snapshot")
    overlap=$(next_action_ownership_overlaps "$snapshot") || die 'could not compare next-action ownership'
    [[ $overlap == false ]] || die 'actionable work overlaps an outstanding operation'
    record=$(select_next_action "$snapshot") || die 'could not select next action'
    next=$(jq -c --argjson record "$record" '.orchestration=$record' <<<"$STATE") ||
        die 'could not record next action'
    write_state "$next"
    jq -c '.decision' <<<"$record"
}
