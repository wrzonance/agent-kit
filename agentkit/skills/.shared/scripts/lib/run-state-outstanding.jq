def uint: type == "number" and . > 0 and floor == .;
def strings: type == "array" and all(.[]; type == "string" and length > 0);
def v2: type == "object" and .version == 2 and (.runId | type) == "string" and
    (.attempt | type) == "string" and (.attempt | length) > 0 and (.issue | uint) and
    (.worktree | type) == "string" and (.branch | type) == "string" and
    (.state == "active" or .state == "unknown" or .state == "terminal");
if all($workers[]; (type == "object") and (.version == 1 or v2)) | not
then error("invalid worker ledger row") else . end |
(.results // {}) as $results | (.opened_prs // []) as $opened |
(.receipt_prs // []) as $receipts | (.skipped_prs // []) as $skipped |
(.queued // []) as $queued | (.initialPublications // {}) as $publications |
if ($results | type) != "object" or ($publications | type) != "object" or
   any([$opened,$receipts,$skipped,$queued][]; type != "array" or any(.[]; uint | not))
then error("invalid run-state obligation collections") else . end |
(reduce ($workers[] | select(v2)) as $row ({}; .[$row.attempt] = $row)) as $owners |
(reduce ($workers[] | select(v2 and .runId == $run)) as $row ({}; .[$row.worktree] = $row) |
    [.[] | select(.state != "terminal")]) as $live |
(reduce ([($plan.independent // [])[], ($plan.chains // [])[][]][] |
    select((.issue | uint) and (.pr | uint))) as $record ({};
    .[$record.issue | tostring] = $record.pr)) as $prs_by_issue |
def accepted_publication($issue):
    ($publications[$issue | tostring] // null) as $p |
    ($p | type) == "object" and ($p.attempt | type) == "string" and
    ($p.branch | type) == "string" and ($p.headSha | type) == "string" and
    ($p.headSha | test("^[0-9a-f]{40}$")) and
    ($owners[$p.attempt].runId == $run) and ($owners[$p.attempt].issue == $issue) and
    ($owners[$p.attempt].branch == $p.branch) and
    ($results[$p.attempt].status == "accepted") and
    ($results[$p.attempt].claims.push == "valid") and
    (($results[$p.attempt].obligations | strings) and
     (($results[$p.attempt].obligations | index("root-push")) == null));
([$results | to_entries[] | select(.value | type == "object" and has("status")) |
    .key as $attempt | .value as $receipt | ($owners[$attempt] // null) as $owner |
    ($prs_by_issue[$owner.issue | tostring] // null) as $pr |
    if $receipt.runId != $run or ($owner | type) != "object" or $owner.runId != $run then
        {id:("result:"+$attempt+":reconcile-owner-mapping"),kind:"result",issue:null,
         next_action:"reconcile-owner-mapping",actionable:false}
    elif $receipt.status != "accepted" or $receipt.claims.push != "valid" then
        {id:("result:"+$attempt+":reconcile-result"),kind:"result",issue:$owner.issue,
         next_action:"reconcile-result",actionable:false}
    elif (($receipt.obligations | strings) | not) then
        {id:("result:"+$attempt+":reconcile-result"),kind:"result",issue:$owner.issue,
         next_action:"reconcile-result",actionable:false}
    elif ($receipt.obligations | index("root-push")) != null then
        {id:("result:"+$attempt+":publish-result"),kind:"result",issue:$owner.issue,
         next_action:"publish-result",actionable:true}
    elif $pr == null then
        {id:("result:"+$attempt+":reconcile-publication-mapping"),kind:"result",issue:$owner.issue,
         next_action:"reconcile-publication-mapping",actionable:false}
    elif ($opened | index($pr)) == null then
        {id:("result:"+$attempt+":open-draft-pr"),kind:"result",issue:$owner.issue,
         next_action:"open-draft-pr",actionable:true}
    else empty end]) as $result_work |
([$opened[] as $pr | select(($receipts | index($pr)) == null and ($skipped | index($pr)) == null) |
    {id:("pr:"+($pr|tostring)+":publish-receipt"),kind:"pr",issue:null,
     next_action:"publish-receipt",actionable:true}]) as $pr_work |
([$queued[] as $issue | ($plan.entries | map(select(.issue == $issue))) as $entries |
    ($entries[0] // null) as $entry |
    if any($live[]; .issue == $issue) then
        {id:("queued:"+($issue|tostring)+":reconcile-active-owner"),kind:"queue",issue:$issue,
         next_action:"reconcile-active-owner",actionable:false}
    elif ($entries | length) != 1 or ($entry | type) != "object" or
       ($entry.expectedPredecessors | type) != "array" or
       any($entry.expectedPredecessors[]; uint | not) or
       (($entry.expectedPredecessors | length) != ($entry.expectedPredecessors | unique | length)) then
        {id:("queued:"+($issue|tostring)+":reconcile-dispatch-readiness"),kind:"queue",issue:$issue,
         next_action:"reconcile-dispatch-readiness",actionable:false}
    elif all($entry.expectedPredecessors[]; accepted_publication(.)) then
        {id:("queued:"+($issue|tostring)+":dispatch-successor"),kind:"queue",issue:$issue,
         next_action:"dispatch-successor",actionable:true}
    else
        {id:("queued:"+($issue|tostring)+":reconcile-predecessor-publication"),kind:"queue",issue:$issue,
         next_action:"reconcile-predecessor-publication",actionable:false}
    end]) as $queue_work |
([$live[] | {id:("worker:"+.attempt),kind:"worker",issue:.issue,
    next_action:(if .state == "active" then "collect-worker" else "reconcile-worker" end),
    actionable:false,status:.state}]) as $worker_work |
(($result_work + $pr_work + $queue_work + $worker_work) | sort_by(.id)) as $work |
{evidence_id:$source_id,outstanding:($work|length),obligations:$work,
 actionable_work:[$work[] | select(.actionable) | .id],
 operations:[$worker_work[] | {id,kind:"worker",status,affected:[.id]}],
 remaining_work:[$work[].id]}
