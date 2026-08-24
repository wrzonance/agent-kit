#!/usr/bin/env bash
# Validate and atomically persist the ready-flip merge plan in a dispatch plan.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
dispatch_plan=''
merge_plan=''
validate_only=0

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s --dispatch-plan FILE (--validate-only | --merge-plan FILE)\n' "$PROGRAM" >&2
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --dispatch-plan)
            (($# >= 2)) || usage
            dispatch_plan=$2
            shift 2
            ;;
        --merge-plan)
            (($# >= 2)) || usage
            merge_plan=$2
            shift 2
            ;;
        --validate-only)
            validate_only=1
            shift
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ -n $dispatch_plan ]] || usage
if ((validate_only)); then
    [[ -z $merge_plan ]] || usage
else
    [[ -n $merge_plan ]] || usage
fi
command -v jq >/dev/null 2>&1 || die 'jq is required; merge-plan evidence unavailable'
inputs=("$dispatch_plan")
[[ -z $merge_plan ]] || inputs+=("$merge_plan")
for file in "${inputs[@]}"; do
    [[ -f $file && ! -L $file && -O $file ]] ||
        die "input must be an owned regular file, not a symlink: $file"
done

if ((validate_only)); then
    jq -e '
      def uint: type == "number" and . > 0 and floor == .;
      def path:
        type == "string" and length > 0 and
        (startswith("/") | not) and (contains("\\") | not) and
        (test("[\\r\\n]") | not) and
        all(split("/").[]; . != "" and . != "." and . != "..");
      type == "object" and .schemaVersion == 1 and
      ((.entries | type) == "array" and (.entries | length) > 0) and
      all(.entries[];
        (type == "object") and (.issue | uint) and
        ((.predictedWriteSet | type) == "array" and
          (.predictedWriteSet | length) > 0) and
        all(.predictedWriteSet[]; path)) and
      ((.entries | map(.issue) | unique | length) == (.entries | length)) and
      ((.conflictMap | type) == "object") and
      ((.conflictMap.pairs | type) == "array") and
      ((.conflictMap.revisions | type) == "array")
    ' "$dispatch_plan" >/dev/null 2>&1 ||
        die 'dispatch plan is invalid: expected schemaVersion 1 with entries and conflictMap'
    printf 'dispatch-plan=%s schemaVersion=1 valid\n' "$dispatch_plan"
    exit 0
fi

jq -e '
  type == "object" and
  ((.schemaVersion == 1) or (.schemaVersion == 2)) and
  ((.entries | type) == "array") and
  ((.conflictMap | type) == "object")
' "$dispatch_plan" >/dev/null 2>&1 || die 'dispatch plan has an unsupported schema'

# Keep this validation declarative: merge-plan bytes are untrusted run data and
# must never become shell syntax. Every selected issue appears exactly once,
# roots use null chainBaseSha, and each successor pins its immediate predecessor.
jq -e --slurpfile dispatch "$dispatch_plan" '
  def uint: type == "number" and . > 0 and floor == .;
  def sha: type == "string" and test("^[0-9a-f]{40}$");
  def branch:
    type == "string" and
    test("^[A-Za-z0-9._/-]+$") and
    (startswith("-") | not) and
    (contains("..") | not) and
    (endswith("/") | not) and
    (endswith(".lock") | not);
  def record:
    (keys | sort) == (["branch","chainBaseSha","headSha","issue","pr"] | sort) and
    (.issue | uint) and (.pr | uint) and (.branch | branch) and
    (.headSha | sha) and
    ((.chainBaseSha == null) or (.chainBaseSha | sha));
  type == "object" and
  ((.generatedAt | type) == "string") and
  (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
  ((.independent | type) == "array") and
  ((.chains | type) == "array") and
  all(.independent[]; record and .chainBaseSha == null) and
  all(.chains[]; . as $chain |
    ($chain | type) == "array" and ($chain | length) >= 2 and
    all($chain[]; record) and
    $chain[0].chainBaseSha == null and
    all(range(1; $chain | length); . as $i |
      $chain[$i].chainBaseSha == $chain[$i - 1].headSha)
  ) and
  ([.independent[], .chains[][]] as $records |
    ($records | length) > 0 and
    (($records | map(.pr) | unique | length) == ($records | length)) and
    (($records | map(.issue) | unique | length) == ($records | length)) and
    (($records | map(.branch) | unique | length) == ($records | length)) and
    (($records | map(.issue) | sort) ==
      ($dispatch[0].entries | map(.issue) | sort)))
' "$merge_plan" >/dev/null 2>&1 || {
    # The boolean gate above is the sole accept/reject authority and is left
    # byte-for-byte unchanged; this second pass only names which field made it
    # fail, so a diagnostic bug can never loosen validation -- at worst it
    # falls back to the generic message below.
    reason=$(jq -r --slurpfile dispatch "$dispatch_plan" '
      def uint: type == "number" and . > 0 and floor == .;
      def sha: type == "string" and test("^[0-9a-f]{40}$");
      def branch:
        type == "string" and
        test("^[A-Za-z0-9._/-]+$") and
        (startswith("-") | not) and
        (contains("..") | not) and
        (endswith("/") | not) and
        (endswith(".lock") | not);
      def record_issue($ctx; $require_root):
        if (type != "object") then "\($ctx) must be an object"
        elif (keys | sort) != (["branch","chainBaseSha","headSha","issue","pr"] | sort)
        then "\($ctx) must have exactly these keys: branch, chainBaseSha, headSha, issue, pr"
        elif (.issue | uint | not) then "\($ctx).issue must be a positive integer"
        elif (.pr | uint | not) then "\($ctx).pr must be a positive integer"
        elif (.branch | branch | not) then "\($ctx).branch is not a safe branch name"
        elif (.headSha | sha | not) then "\($ctx).headSha must be a 40-character lowercase hex commit SHA"
        elif ($require_root and .chainBaseSha != null) then "\($ctx).chainBaseSha must be null (no predecessor)"
        elif ((.chainBaseSha != null) and (.chainBaseSha | sha | not))
        then "\($ctx).chainBaseSha must be null or a 40-character lowercase hex commit SHA"
        else null
        end;
      def chain_issue($ctx):
        if (type != "array") then "\($ctx) must be an array"
        elif (length) < 2 then "\($ctx) must contain at least 2 records (a chain root and at least one successor)"
        else
          (. as $chain | first(
            range(0; $chain | length) as $i
            | ($chain[$i] | record_issue("\($ctx)[\($i)]"; $i == 0))
            | select(. != null)
          ))
          // (. as $chain | first(
            range(1; $chain | length) as $i
            | (if $chain[$i].chainBaseSha != $chain[$i - 1].headSha
               then "\($ctx)[\($i)].chainBaseSha must equal \($ctx)[\($i - 1)].headSha"
               else null end)
            | select(. != null)
          ))
        end;
      def reason:
        if type != "object" then "merge plan must be a JSON object"
        elif (.generatedAt | type) != "string" then "merge plan is missing required field: generatedAt"
        elif (.generatedAt | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") | not)
        then "merge plan field generatedAt is not a valid ISO-8601 UTC timestamp (want YYYY-MM-DDTHH:MM:SSZ)"
        elif (.independent | type) != "array" then "merge plan is missing required field: independent (must be an array)"
        elif (.chains | type) != "array" then "merge plan is missing required field: chains (must be an array)"
        else
          (first(
            range(0; .independent | length) as $i
            | (.independent[$i] | record_issue("independent[\($i)]"; true))
            | select(. != null)
          ))
          // (first(
            range(0; .chains | length) as $i
            | (.chains[$i] | chain_issue("chains[\($i)]"))
            | select(. != null)
          ))
          // (
            ([.independent[], .chains[][]]) as $records
            | if ($records | length) == 0
              then "merge plan must contain at least one record across independent and chains"
              elif ($records | map(.pr) | unique | length) != ($records | length)
              then "merge plan pr values must be unique across independent and chains"
              elif ($records | map(.issue) | unique | length) != ($records | length)
              then "merge plan issue values must be unique across independent and chains"
              elif ($records | map(.branch) | unique | length) != ($records | length)
              then "merge plan branch values must be unique across independent and chains"
              elif ($records | map(.issue) | sort) != ($dispatch[0].entries | map(.issue) | sort)
              then "merge plan issue set does not match the dispatch plan entries"
              else null
              end
          )
        end;
      reason // empty
    ' "$merge_plan" 2>/dev/null) || true
    if [[ -n ${reason:-} ]]; then
        die "merge plan is invalid: $reason"
    else
        die 'merge plan is malformed, ambiguous, or does not match dispatch entries'
    fi
}

target_dir=$(dirname -- "$dispatch_plan")
staged=$(mktemp "$target_dir/.dispatch-plan.XXXXXX") || die 'could not stage dispatch plan'
cleanup() { rm -f -- "$staged"; }
trap cleanup EXIT HUP INT TERM

jq --slurpfile merge "$merge_plan" '
  .schemaVersion = 2 |
  .generatedAt = $merge[0].generatedAt |
  .independent = $merge[0].independent |
  .chains = $merge[0].chains
' "$dispatch_plan" >"$staged" || die 'could not compose schemaVersion 2 dispatch plan'
chmod --reference="$dispatch_plan" "$staged" 2>/dev/null || chmod 600 "$staged"
mv -- "$staged" "$dispatch_plan"
trap - EXIT HUP INT TERM
printf 'merge-plan=%s schemaVersion=2 independent=%s chains=%s\n' \
    "$dispatch_plan" \
    "$(jq -r '.independent | length' "$dispatch_plan")" \
    "$(jq -r '.chains | length' "$dispatch_plan")"
