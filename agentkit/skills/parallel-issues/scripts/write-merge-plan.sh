#!/usr/bin/env bash
# Validate and atomically persist the ready-flip merge plan in a dispatch plan.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
dispatch_plan=''
merge_plan=''

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    printf 'usage: %s --dispatch-plan FILE --merge-plan FILE\n' "$PROGRAM" >&2
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
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ -n $dispatch_plan && -n $merge_plan ]] || usage
command -v jq >/dev/null 2>&1 || die 'jq is required; merge-plan evidence unavailable'
for file in "$dispatch_plan" "$merge_plan"; do
    [[ -f $file && ! -L $file && -O $file ]] ||
        die "input must be an owned regular file, not a symlink: $file"
done

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
' "$merge_plan" >/dev/null 2>&1 || die 'merge plan is malformed, ambiguous, or does not match dispatch entries'

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
