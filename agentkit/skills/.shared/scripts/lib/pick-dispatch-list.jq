# Fast-mode dispatch list for pick-issues.sh: one terminal decision per
# candidate, in pickup order, from evidence the picker already holds.
# Inputs: the selection array; $cap (slot cap), $protected ({"N": pattern}),
# $exclude (lower-case operator terms). Output: {dispatched, queued, dropped, lines}.

def clip($n): if length > $n then .[:$n - 3] + "..." else . end;
# The directory a write pattern owns, cut before the first wildcard component:
# "src/foo*.ts" -> "src", "**/x" -> "" (everything).
def owned:
    sub("^\\./"; "") | split("/") | (map(test("[*?\\[]")) | index(true)) as $i
    | (if $i == null then . else .[:$i] end) | join("/") | rtrimstr("/");
def overlaps($a; $b):
    ($a | owned) as $x | ($b | owned) as $y
    | $x == "" or $y == "" or $x == $y
      or ($y | startswith($x + "/")) or ($x | startswith($y + "/"));
def writes:
    .predictedWriteSet as $w
    | ($w[:3] | join(",")) + (if ($w | length) > 3 then ",+\(($w | length) - 3)" else "" end);
def excluded_by:
    ([.title] + .predictedWriteSet | map(ascii_downcase)) as $hay
    | first($exclude[] | select(. as $t | $hay | any(contains($t)))) // null;
def collides_with($taken):
    . as $c
    | first($taken[]
        | select(any(.predictedWriteSet[] as $a | $c.predictedWriteSet[] | overlaps($a; .); .))
        | .number) // null;

def drop_reason($taken):
    excluded_by as $term
    | collides_with($taken) as $hit
    | if .workShape == "no-code" then "no-code hold: \(.holdReason // "" | clip(60))"
      elif (.blockers | length) > 0 then "blocked-by \(.blockers | map("#\(.)") | join(",")) open"
      elif .blockerTotal != .blockerRead then "blocked-by unread: \(.blockerRead) of \(.blockerTotal) blockers read"
      elif $term != null then "excluded by operator filter \"\($term)\""
      elif (.predictedWriteSet | length) == 0 then "needs-adjudication: no file path named in the issue body"
      elif $protected[.number | tostring] then "protected paths \($protected[.number | tostring])"
      elif $hit != null then "write-set collision with #\($hit)"
      else null end;

# Queued and dropped candidates share a line per reason so a large board stays
# a few lines long: "queued #39,#41  slot-cap", "dropped #34,#51  <reason>".
def grouped($verb):
    reduce .[] as $d ([]; (map(.why == $d.why) | index(true)) as $i
        | if $i == null then . + [{why: $d.why, ns: [$d.n]}] else .[$i].ns += [$d.n] end)
    | map("\($verb) \(.ns | map("#\(.)") | join(","))  \(.why)");

reduce .[] as $c ({taken: [], lines: [], queue: [], drops: []};
    .taken as $taken
    | ($c | drop_reason($taken)) as $why
    | if $why != null then .drops += [{n: $c.number, why: $why}]
      elif (.lines | length) < $cap then
        .taken += [$c]
        | .lines += ["dispatch #\($c.number)  \($c.title | clip(60))  writes=\($c | writes)  shape=\($c.workShape)"]
      else .taken += [$c] | .queue += [{n: $c.number, why: "slot-cap"}]
      end)
| {dispatched: (.lines | length), queued: (.queue | length), dropped: (.drops | length),
   lines: (.lines + (.queue | grouped("queued")) + (.drops | grouped("dropped")))}
