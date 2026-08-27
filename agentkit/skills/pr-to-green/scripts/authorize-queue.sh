#!/usr/bin/env bash
# Derive the confirmed pr-to-green authorization artifact from live queue data.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
QUEUE_HELPER=${AUTHORIZE_QUEUE_HELPER:-$SCRIPT_DIR/pr-queue.sh}
PROVIDER_CONFIG=${AUTHORIZE_QUEUE_PROVIDER_CONFIG:-$SCRIPT_DIR/../../.shared/scripts/review-provider-config.sh}
GH_BIN=${AUTHORIZE_QUEUE_GH:-gh}

repo=''
repo_root=''
merge_plan=''
confirmed_queue_file=''
ready_transition=0
auto_merge_choice=''
merge_method=''
branch_choice=''
no_providers=0
allow_mechanical_advance=0
declare -a providers=()
declare -a prs=()
requested_prs_json='[]'
declare -A retarget_proof_file=()

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

# Ownership alone does not protect proof evidence from another user in the
# same group -- reject a file group- or world-writable, matching merge-pr.sh's
# authorization/gate-result file policy.
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
usage: $PROGRAM --repo OWNER/REPO --repo-root DIR --ready-transition
       (--auto-merge --merge-method squash|merge|rebase
          (--delete-branch|--keep-branch) | --no-auto-merge)
       (--provider NAME:ACTION:SOURCE ... | --no-providers)
       --confirmed-queue-file FILE [--merge-plan FILE] [--pr N ...]
       [--allow-mechanical-advance [--retarget-proof PR:FILE ...]]

Derives .agent/pr-to-green-auth.json from fresh pr-queue.sh JSON. ACTION is
trigger, observe, or disabled. FILE is the owner-only snapshot written by the
displayed pr-queue.sh --write-confirmed-queue run, including its provider
decisions. No head SHA or base ref is accepted as input.

--allow-mechanical-advance lets a live queue that no longer matches FILE
exactly still authorize, but only per confirmed PR and only for a
deterministic advance proven from live forge state: a same-base head change
(a merge-down) with an identical diff-shape fingerprint and a verified
ancestor relationship to the previously authorized head, a base change (a
retarget) with a matching --retarget-proof PR:FILE naming a
chain-advance.sh --retarget proof for that exact PR/base/head, or a
confirmed PR's disappearance from the live queue independently verified as
merged. Repository, provider decisions, and any PR the live queue adds are
never covered by this and always require redisplay and reconfirmation.
EOF
    exit "${1:-2}"
}

while (($#)); do
    case $1 in
        --repo) (($# >= 2)) || usage; repo=$2; shift 2 ;;
        --repo-root) (($# >= 2)) || usage; repo_root=$2; shift 2 ;;
        --merge-plan|--dispatch-plan)
            (($# >= 2)) || usage
            [[ -z $merge_plan ]] || die 'only one merge/dispatch plan may be supplied'
            merge_plan=$2
            shift 2
            ;;
        --pr)
            (($# >= 2)) || usage
            prs+=("$2")
            requested_prs_json=$(jq -cn --argjson current "$requested_prs_json" --arg number "$2" '$current + [($number | tonumber)]')
            shift 2
            ;;
        --confirmed-queue-file)
            (($# >= 2)) || usage
            [[ -z $confirmed_queue_file ]] || die 'only one confirmed queue file may be supplied'
            confirmed_queue_file=$2
            shift 2
            ;;
        --ready-transition) ready_transition=1; shift ;;
        --auto-merge)
            [[ -z $auto_merge_choice ]] || die 'choose exactly one auto-merge mode'
            auto_merge_choice=yes
            shift
            ;;
        --no-auto-merge)
            [[ -z $auto_merge_choice ]] || die 'choose exactly one auto-merge mode'
            auto_merge_choice=no
            shift
            ;;
        --merge-method) (($# >= 2)) || usage; merge_method=$2; shift 2 ;;
        --delete-branch)
            [[ -z $branch_choice ]] || die 'choose exactly one branch-deletion mode'
            branch_choice=delete
            shift
            ;;
        --keep-branch)
            [[ -z $branch_choice ]] || die 'choose exactly one branch-deletion mode'
            branch_choice=keep
            shift
            ;;
        --provider) (($# >= 2)) || usage; providers+=("$2"); shift 2 ;;
        --no-providers)
            ((no_providers == 0)) || die '--no-providers may be passed only once'
            no_providers=1
            shift
            ;;
        --allow-mechanical-advance) allow_mechanical_advance=1; shift ;;
        --retarget-proof)
            (($# >= 2)) || usage
            retarget_pr=${2%%:*}
            retarget_file=${2#*:}
            [[ $retarget_pr =~ ^[1-9][0-9]*$ && -n $retarget_file && $retarget_file != "$2" ]] ||
                die "--retarget-proof must have the form PR:FILE: $2"
            [[ -z ${retarget_proof_file[$retarget_pr]+set} ]] ||
                die "duplicate --retarget-proof for pr $retarget_pr"
            retarget_proof_file[$retarget_pr]=$retarget_file
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ $repo =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
    die '--repo must have the form OWNER/REPO'
[[ -n $repo_root ]] || die '--repo-root is required'
[[ -d $repo_root && ! -L $repo_root && -O $repo_root ]] ||
    die '--repo-root must be an owned directory, not a symlink'
repo_root=$(cd -- "$repo_root" && pwd -P) || die 'could not resolve --repo-root'
[[ -d $repo_root/.agent && ! -L $repo_root/.agent && -O $repo_root/.agent ]] ||
    die '.agent must be an owned directory, not a symlink'
expected_confirmed_queue=$repo_root/.agent/pr-to-green-confirmed-queue.json
[[ -n $confirmed_queue_file ]] || die '--confirmed-queue-file is required'
[[ -f $confirmed_queue_file && ! -L $confirmed_queue_file && -O $confirmed_queue_file ]] ||
    die 'confirmed queue file must be an owned regular file, not a symlink'
confirmed_queue_file=$(realpath -- "$confirmed_queue_file") ||
    die 'could not resolve --confirmed-queue-file'
[[ $confirmed_queue_file == "$expected_confirmed_queue" ]] ||
    die '--confirmed-queue-file must name .agent/pr-to-green-confirmed-queue.json under --repo-root'
[[ $(stat -c '%a' "$confirmed_queue_file") == 600 ]] ||
    die 'confirmed queue file must be owner-only (mode 0600)'
((ready_transition)) || die '--ready-transition must be passed explicitly'
[[ -n $auto_merge_choice ]] || { usage; }

if [[ $auto_merge_choice == yes ]]; then
    case $merge_method in squash|merge|rebase) ;;
        *) die '--auto-merge requires --merge-method squash, merge, or rebase' ;;
    esac
    [[ -n $branch_choice ]] ||
        die '--auto-merge requires an explicit --delete-branch or --keep-branch choice'
else
    [[ -z $merge_method && -z $branch_choice ]] ||
        die '--no-auto-merge cannot be combined with merge or branch-deletion options'
fi

if ((no_providers)); then
    ((${#providers[@]} == 0)) || die '--no-providers cannot be combined with --provider'
else
    ((${#providers[@]} > 0)) ||
        die 'pass each --provider NAME:ACTION:SOURCE or pass --no-providers explicitly'
fi
for pr in "${prs[@]}"; do
    [[ $pr =~ ^[1-9][0-9]*$ ]] || die "--pr expects a positive integer: $pr"
done
if ((${#retarget_proof_file[@]})); then
    ((allow_mechanical_advance)) ||
        die '--retarget-proof requires --allow-mechanical-advance'
    for pr in "${!retarget_proof_file[@]}"; do
        file=${retarget_proof_file[$pr]}
        [[ -f $file && ! -L $file && -O $file ]] ||
            die "--retarget-proof file must be an owned regular file, not a symlink: $file"
        reject_writable_by_others "$file" '--retarget-proof file'
    done
fi
command -v jq >/dev/null 2>&1 || die 'jq is required; authorization evidence unavailable'
[[ -x $QUEUE_HELPER ]] || die "queue helper is not executable: $QUEUE_HELPER"
[[ -x $PROVIDER_CONFIG ]] || die "provider resolver is not executable: $PROVIDER_CONFIG"
if ((allow_mechanical_advance)); then
    command -v "$GH_BIN" >/dev/null 2>&1 ||
        die "required tool not found: $GH_BIN"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/authorize-queue.XXXXXX") ||
    die 'could not create work directory'
output_tmp=''
cleanup() {
    rm -rf -- "$work_dir"
    [[ -z $output_tmp || ! -e $output_tmp ]] || rm -f -- "$output_tmp"
}
trap cleanup EXIT HUP INT TERM

: >"$work_dir/providers.jsonl"
if ((no_providers == 0)); then
    declare -A seen_providers=()
    for provider in "${providers[@]}"; do
        IFS=: read -r name action source extra <<<"$provider"
        [[ -n $name && -n $action && -n $source && -z ${extra:-} ]] ||
            die '--provider must have the form NAME:ACTION:SOURCE'
        [[ $name =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid provider name: $name"
        case $action in trigger|observe|disabled) ;;
            *) die "invalid provider action for $name: $action" ;;
        esac
        [[ -z ${seen_providers[$name]+set} ]] || die "duplicate provider: $name"
        seen_providers[$name]=1
        jq -cn --arg name "$name" --arg action "$action" --arg source "$source" \
            '{name:$name,action:$action,source:$source}' >>"$work_dir/providers.jsonl"
    done
fi
jq -s '.' "$work_dir/providers.jsonl" >"$work_dir/providers.json"

# Resolve the same declared capability plan used by the transition helper before
# reading the live queue. Every declared provider must have a compatible
# per-run action, while the synthetic disabled `none` plan is represented by
# the explicit --no-providers choice.
declare -a plan_providers=()
declare -A plan_modes=()
plan_output=$("$PROVIDER_CONFIG" --repo-root "$repo_root") ||
    die 'provider capability resolution failed'
[[ -n $plan_output ]] || die 'provider capability resolver returned an empty plan'
while IFS= read -r line; do
    if [[ $line =~ ^provider=([a-z0-9-]+)[[:space:]]mode=([a-z-]+)[[:space:]]source=([a-z]+)$ ]]; then
        plan_provider=${BASH_REMATCH[1]}
        plan_mode=${BASH_REMATCH[2]}
    else
        die 'provider capability resolver returned a malformed record'
    fi
    [[ -z ${plan_modes[$plan_provider]+set} ]] ||
        die "provider capability plan duplicates $plan_provider"
    case $plan_mode in triggerable|observe-only|none|disabled) ;;
        *) die "provider capability plan contains unsupported capability: $plan_provider:$plan_mode" ;;
    esac
    plan_providers+=("$plan_provider")
    plan_modes[$plan_provider]=$plan_mode
done <<< "$plan_output"

declare -A requested_actions=()
if ((no_providers == 0)); then
    while IFS=$'\t' read -r requested_name requested_action; do
        requested_actions[$requested_name]=$requested_action
    done < <(jq -r '.[] | [.name, .action] | @tsv' "$work_dir/providers.json")
fi
authorized_display=$(jq -r '.[] | [.name, .action] | join(":")' "$work_dir/providers.json" |
    sort | paste -sd, -)
triggerable_display=''
for plan_provider in "${plan_providers[@]}"; do
    [[ ${plan_modes[$plan_provider]} == triggerable ]] || continue
    triggerable_display+="${triggerable_display:+,}$plan_provider"
done
authorization_mismatch=0
for plan_provider in "${plan_providers[@]}"; do
    plan_mode=${plan_modes[$plan_provider]}
    requested_action=${requested_actions[$plan_provider]-}
    # `none:disabled` is the resolver's effective plan for --no-providers;
    # there is no provider decision to record for that synthetic entry.
    [[ $plan_provider == none && $plan_mode == disabled && -z $requested_action ]] && continue
    if [[ -z $requested_action ]]; then
        # Observe-only providers never mutate the forge, so omitting their
        # optional authorization keeps the mixed-plan observation path intact.
        [[ $plan_mode == observe-only ]] && continue
        authorization_mismatch=1
        continue
    fi
    case $plan_mode in
        triggerable)
            [[ $requested_action == trigger || $requested_action == observe ||
               $requested_action == disabled ]] || authorization_mismatch=1
            ;;
        observe-only|none|disabled)
            [[ $requested_action == observe || $requested_action == disabled ]] ||
                authorization_mismatch=1
            ;;
    esac
done
for requested_name in "${!requested_actions[@]}"; do
    [[ -n ${plan_modes[$requested_name]+set} ]] || authorization_mismatch=1
done
if ((authorization_mismatch)); then
    die "authorization provider set does not match capability plan: authorized={${authorized_display:-}} trigger-capable={${triggerable_display:-}}"
fi

requested_argv=$(jq -cn --arg plan "$merge_plan" --argjson prs "$requested_prs_json" '
  {plan:(if $plan == "" then null else {flag:"merge-plan",path:$plan} end),prs:$prs}
')
argv_diff=$(jq -r --argjson requested "$requested_argv" '
  if (.argv | type) != "object" then "argv"
  elif .argv.plan != $requested.plan then "plan"
  elif .argv.prs != $requested.prs then "prs"
  else "" end
' "$confirmed_queue_file")
[[ -z $argv_diff ]] ||
    die "argv differs: $argv_diff; redisplay and reconfirm before authorization"

queue_args=(--repo "$repo" --repo-root "$repo_root" --format json)
[[ -z $merge_plan ]] || queue_args+=(--merge-plan "$merge_plan")
for pr in "${prs[@]}"; do queue_args+=(--pr "$pr"); done
"$QUEUE_HELPER" "${queue_args[@]}" >"$work_dir/queue.json" ||
    die 'live queue derivation failed'
jq -e '
  def diff_fingerprint_ok:
    . == null or (type == "string" and test("^[0-9a-f]{64}$"));
  type == "array" and length > 0 and
  all(.[];
    (.pr | type) == "number" and .pr > 0 and (.pr | floor) == .pr and
    (.state == "RUNNABLE" or .state == "WAITING_FOR_MERGE" or
      .state == "RETARGET_REQUIRED" or .state == "BLOCKED" or
      .state == "MERGEABLE_UNKNOWN" or .state == "SETTLING") and
    (.sha | type) == "string" and (.sha | test("^[0-9a-f]{40}$")) and
    (.base | type) == "string" and (.base | length) > 0 and
    (.diffFingerprint | diff_fingerprint_ok)) and
  ((map(.pr) | unique | length) == length)
' "$work_dir/queue.json" >/dev/null 2>&1 || die 'queue helper returned malformed JSON'

# def base_ok is everything the displayed snapshot must always satisfy:
# well-formed shape, this exact repository, and providers exactly as
# displayed. --allow-mechanical-advance never relaxes any of it -- only a
# pure `.queue` content mismatch against the fresh live read is eligible for
# reconciliation below.
# shellcheck disable=SC2016 # jq program: $repo/$requested are jq --arg binds, not bash expansion
base_ok_jq='
  def provider:
    type == "object" and (keys | sort) == ["action","name","source"] and
    (.name | type) == "string" and (.name | test("^[a-z0-9][a-z0-9-]*$")) and
    (.action == "trigger" or .action == "observe" or .action == "disabled") and
    (.source | type) == "string" and (.source | length) > 0;
  def diff_fingerprint_ok:
    . == null or (type == "string" and test("^[0-9a-f]{64}$"));
  def canonical: sort_by([.name,.action,.source]);
  type == "object" and (keys | sort) == ["argv","budget","providers","queue","repository"] and
  (.argv |
    type == "object" and (keys | sort) == ["plan","prs"] and
    (.plan == null or
      (.plan | type == "object" and (keys | sort) == ["flag","path"] and
        .flag == "merge-plan" and (.path | type) == "string" and (.path | length) > 0)) and
    (.prs | type) == "array" and all(.prs[]; type == "number" and . > 0 and floor == .)) and
  .repository == $repo and
  (.providers | type) == "array" and all(.providers[]; provider) and
  ((.providers | map(.name) | unique | length) == (.providers | length)) and
  ((.providers | canonical) == ($requested[0] | canonical)) and
  (.queue | type) == "array" and (.queue | length) > 0 and
  all(.queue[];
    (keys | sort) == ["base","diffFingerprint","headSha","pr","state"] and
    (.pr | type) == "number" and .pr > 0 and (.pr | floor) == .pr and
    (.state == "RUNNABLE" or .state == "WAITING_FOR_MERGE" or
      .state == "RETARGET_REQUIRED" or .state == "BLOCKED" or
      .state == "MERGEABLE_UNKNOWN" or .state == "SETTLING") and
    (.headSha | type) == "string" and (.headSha | test("^[0-9a-f]{40}$")) and
    (.base | type) == "string" and (.base | length) > 0 and
    (.diffFingerprint | diff_fingerprint_ok)) and
  ((.queue | map(.pr) | unique | length) == (.queue | length))
'

# Report a stable, actionable explanation for the first mismatch. `budget` is
# deliberately excluded from the leaf comparison: it is an informational
# preflight snapshot, not authorization consent. The top-level key comparison
# still requires the four-key schema emitted by pr-queue.sh.
snapshot_mismatch() {
    jq -r --arg repo "$repo" --argjson argv "$requested_argv" --slurpfile live "$work_dir/queue.json" \
      --slurpfile requested "$work_dir/providers.json" '
      ($live[0] | map({pr,state,headSha:.sha,base,diffFingerprint})) as $liveQueue |
      {repository:$repo, argv:$argv, providers:$requested[0], budget:null, queue:$liveQueue} as $expected |
      . as $snapshot |
      def present($object; $path): [$object | paths] | any(. == $path);
      def value_at($object; $path):
        if present($object; $path) then ($object | getpath($path))
        else {__missing__:true} end;
      def display:
        if . == {__missing__:true} then "<missing>"
        elif type == "string" then .
        else tojson end;
      def path_text:
        reduce .[] as $part ("";
          . + (if ($part | type) == "number" then "[\($part)]" else ".\($part)" end));
      if ($snapshot | type) != "object" then
        "snapshot.type snapshot=\($snapshot | type) live=object"
      elif (($snapshot | keys | sort) != ($expected | keys | sort)) then
        "snapshot.keys snapshot=\($snapshot | keys | sort | tojson) live=\($expected | keys | sort | tojson)"
      else
        ($snapshot | [paths(scalars)]) as $snapshotPaths |
        ($expected | [paths(scalars)]) as $expectedPaths |
        (($snapshotPaths + $expectedPaths) | unique |
          map(select(length == 0 or .[0] != "budget"))) as $paths |
        first($paths[] as $path |
          (value_at($snapshot; $path)) as $snapshotValue |
          (value_at($expected; $path)) as $liveValue |
          select($snapshotValue != $liveValue) |
          "\($path | path_text) snapshot=\($snapshotValue | display) live=\($liveValue | display)") // empty
      end
    ' "$confirmed_queue_file"
}

full_match_ok=1
jq -e --arg repo "$repo" --slurpfile live "$work_dir/queue.json" \
  --slurpfile requested "$work_dir/providers.json" \
  "$base_ok_jq"' and .queue == ($live[0] | map({pr,state,headSha:.sha,base,diffFingerprint}))' \
  "$confirmed_queue_file" >/dev/null 2>&1 || full_match_ok=0

if ((full_match_ok == 0)); then
    ((allow_mechanical_advance)) ||
        {
            mismatch_detail=$(snapshot_mismatch 2>/dev/null || true)
            if [[ -n $mismatch_detail ]]; then
                die "live queue or provider decisions differ from the displayed confirmation: $mismatch_detail; redisplay and reconfirm before authorization"
            fi
            die 'live queue or provider decisions differ from the displayed confirmation; redisplay and reconfirm before authorization'
        }
    base_ok=1
    jq -e --arg repo "$repo" --slurpfile requested "$work_dir/providers.json" \
      "$base_ok_jq" "$confirmed_queue_file" >/dev/null 2>&1 || base_ok=0
    if ((base_ok == 0)); then
        mismatch_detail=$(snapshot_mismatch 2>/dev/null || true)
        if [[ -n $mismatch_detail ]]; then
            die "live queue or provider decisions differ from the displayed confirmation: $mismatch_detail; redisplay and reconfirm before authorization"
        fi
        die 'live queue or provider decisions differ from the displayed confirmation; redisplay and reconfirm before authorization'
    fi

    # Every confirmed PR must resolve to unchanged, a verified mechanical
    # advance, or a verified merge -- never silently dropped. A confirmed PR
    # absent from this classification (e.g. a bare `select()` match on zero
    # live rows) would fail open, so the live-side lookup is wrapped in
    # first(...) // null to force an explicit "vanished" verdict instead.
    # F1 (issue #450 review finding): a mechanical verdict requires BOTH the
    # confirmed PR's own prior state (never inferred from the live state
    # alone) and an actual corresponding mutation. A state-only flip with an
    # identical head and base -- e.g. GitHub recomputing BLOCKED/
    # MERGEABLE_UNKNOWN to RUNNABLE with nothing else changed -- matches
    # neither bucket below and falls through to "fail", exactly like any
    # other unproven drift.
    jq -n --slurpfile confirmed "$confirmed_queue_file" --slurpfile live "$work_dir/queue.json" '
      ($confirmed[0].queue) as $confirmed |
      ($live[0] | map({pr,state,headSha:.sha,base,diffFingerprint})) as $live |
      {
        added: (($live | map(.pr)) - ($confirmed | map(.pr))),
        perPr: [ $confirmed[] | . as $c |
          ((first($live[] | select(.pr == $c.pr))) // null) as $l |
          # Every field is always populated with a non-empty placeholder ("-")
          # rather than left absent: consecutive tabs in a TSV row collapse
          # under bash `read` (tab is IFS whitespace, so IFS=$'"'"'\t'"'"' still
          # collapses repeats), which silently shifts every later column left.
          (if $l == null then "-" else $c.headSha end) as $confirmedHeadSha |
          (if $l == null then "-" else ($l.headSha // "-") end) as $liveHeadSha |
          (if $l == null then "-" else ($l.base // "-") end) as $liveBase |
          if $l == null then {pr:$c.pr, verdict:"vanished",
            confirmedHeadSha:$confirmedHeadSha, liveHeadSha:$liveHeadSha, liveBase:$liveBase}
          elif ($l.state == $c.state and $l.headSha == $c.headSha and
                $l.base == $c.base and $l.diffFingerprint == $c.diffFingerprint) then
            {pr:$c.pr, verdict:"unchanged",
             confirmedHeadSha:$confirmedHeadSha, liveHeadSha:$liveHeadSha, liveBase:$liveBase}
          elif ($c.state == "RUNNABLE" and $l.state == "RUNNABLE" and
                $l.base == $c.base and $l.headSha != $c.headSha and
                $c.diffFingerprint != null and $l.diffFingerprint == $c.diffFingerprint) then
            {pr:$c.pr, verdict:"merge-down",
             confirmedHeadSha:$confirmedHeadSha, liveHeadSha:$liveHeadSha, liveBase:$liveBase}
          elif (($c.state == "WAITING_FOR_MERGE" or $c.state == "RETARGET_REQUIRED") and
                $l.state == "RUNNABLE" and $l.base != $c.base and
                $c.diffFingerprint != null and $l.diffFingerprint == $c.diffFingerprint) then
            {pr:$c.pr, verdict:"retarget",
             confirmedHeadSha:$confirmedHeadSha, liveHeadSha:$liveHeadSha, liveBase:$liveBase}
          else {pr:$c.pr, verdict:"fail",
            confirmedHeadSha:$confirmedHeadSha, liveHeadSha:$liveHeadSha, liveBase:$liveBase} end
        ]
      }
    ' >"$work_dir/reconcile.json" || die 'could not evaluate mechanical-advance reconciliation'

    added_list=$(jq -r '.added | map(tostring) | join(",")' "$work_dir/reconcile.json")
    if [[ -n $added_list ]]; then
        mismatch_detail=$(snapshot_mismatch 2>/dev/null || true)
        if [[ -n $mismatch_detail ]]; then
            die "live queue includes pr(s) $added_list that were never in the displayed confirmation: $mismatch_detail; redisplay and reconfirm before authorization"
        fi
        die "live queue includes pr(s) $added_list that were never in the displayed confirmation; redisplay and reconfirm before authorization"
    fi

    # F3 (issue #450 review finding): the retarget path previously trusted the
    # proof file's own text without independently verifying that the live
    # head actually descends from the previously authorized head. The same
    # live ancestry compare merge-down already requires is run here too,
    # before the proof is even inspected.
    verify_ancestry() {
        local pr=$1 confirmed_sha=$2 live_sha=$3 compare_json behind cmp_status
        compare_json=$("$GH_BIN" api "repos/$repo/compare/$confirmed_sha...$live_sha" 2>/dev/null) ||
            die "pr $pr: ancestry could not be read for its mechanical advance; redisplay and reconfirm before authorization"
        behind=$(jq -r '.behind_by // empty' <<<"$compare_json" 2>/dev/null)
        cmp_status=$(jq -r '.status // empty' <<<"$compare_json" 2>/dev/null)
        [[ $behind == 0 && ( $cmp_status == ahead || $cmp_status == identical ) ]] ||
            die "pr $pr: the live head fails the ancestry check against the previously authorized head; redisplay and reconfirm before authorization"
    }

    while IFS=$'\t' read -r recon_pr recon_verdict recon_confirmed_sha recon_live_sha recon_live_base; do
        case $recon_verdict in
            unchanged) : ;;
            vanished)
                merged_json=$("$GH_BIN" api "repos/$repo/pulls/$recon_pr" 2>/dev/null) || merged_json=''
                if [[ $(jq -r '.merged // false' <<<"$merged_json" 2>/dev/null) != true ]]; then
                    mismatch_detail=$(snapshot_mismatch 2>/dev/null || true)
                    if [[ -n $mismatch_detail ]]; then
                        die "pr $recon_pr is missing from the live queue and is not verified merged: $mismatch_detail; redisplay and reconfirm before authorization"
                    fi
                    die "pr $recon_pr is missing from the live queue and is not verified merged; redisplay and reconfirm before authorization"
                fi
                ;;
            merge-down)
                verify_ancestry "$recon_pr" "$recon_confirmed_sha" "$recon_live_sha"
                ;;
            retarget)
                verify_ancestry "$recon_pr" "$recon_confirmed_sha" "$recon_live_sha"
                proof_file=${retarget_proof_file[$recon_pr]-}
                [[ -n $proof_file ]] ||
                    die "pr $recon_pr changed base with no --retarget-proof supplied; redisplay and reconfirm before authorization"
                # Every required token must be present on the SAME candidate
                # line, never satisfied piecemeal across different lines --
                # a proof file that accumulated several PRs' chain-advance.sh
                # lines must not let one PR's line supply the ancestry/green/
                # approval/closing-issues tokens for another PR's base/head
                # match. Select only lines carrying this exact PR-and-base
                # prefix, then require the remaining tokens on that one line.
                # Approval is provider policy, not mechanical base safety
                # (issue #455): a trigger/observe provider settles on the
                # current head only after the ready/provider transition that
                # follows this proof, and a disabled/none provider may never
                # produce one at all. The proof's `approval=` token is
                # therefore checked for a well-formed value, never required
                # to be `current:post-retarget` -- ancestry, post-retarget
                # CI, and closing linkage stay the mandatory mechanical proof.
                proof_ok=0
                while IFS= read -r proof_line; do
                    if [[ $proof_line == *" sha=$recon_live_sha "* &&
                          $proof_line == *'ancestry=verified'* &&
                          $proof_line == *'green:post-retarget'* &&
                          $proof_line =~ approval=(current:post-retarget|residue:stale|none|unknown)( |$) &&
                          $proof_line =~ closing-issues=[1-9][0-9]*$ ]]; then
                        proof_ok=1
                        break
                    fi
                done < <(grep -F "retargeted pr #$recon_pr base=$recon_live_base " "$proof_file" 2>/dev/null)
                ((proof_ok)) ||
                    die "pr $recon_pr: the supplied retarget proof does not match the live base and head; redisplay and reconfirm before authorization"
                ;;
            *)
                mismatch_detail=$(snapshot_mismatch 2>/dev/null || true)
                if [[ -n $mismatch_detail ]]; then
                    die "pr $recon_pr changed in a way that is not a verified mechanical advance (diff expanded, not runnable, or evidence unavailable): $mismatch_detail; redisplay and reconfirm before authorization"
                fi
                die "pr $recon_pr changed in a way that is not a verified mechanical advance (diff expanded, not runnable, or evidence unavailable); redisplay and reconfirm before authorization"
                ;;
        esac
    done < <(jq -r '.perPr[] | [.pr,.verdict,.confirmedHeadSha,.liveHeadSha,.liveBase] | @tsv' "$work_dir/reconcile.json")
fi

delete_branch=false
[[ $branch_choice != delete ]] || delete_branch=true
jq -n --arg repo "$repo" --slurpfile providers "$work_dir/providers.json" \
    --slurpfile queue "$work_dir/queue.json" --arg auto "$auto_merge_choice" \
    --arg method "$merge_method" --argjson deleteBranch "$delete_branch" '
  {
    repository:$repo,
    readyTransition:true,
    providers:$providers[0],
    queue:($queue[0] | map({pr,state,headSha:.sha,base}))
  } |
  if $auto == "yes" then
    . + {autoMerge:true,mergeMethod:$method,deleteBranch:$deleteBranch}
  else . end
' >"$work_dir/authorization.json" || die 'could not compose authorization record'

output=$repo_root/.agent/pr-to-green-auth.json
if [[ -e $output && ( ! -f $output || -L $output || ! -O $output ) ]]; then
    die 'authorization output must be an owned regular file, not a symlink'
fi
output_tmp=$(mktemp "$repo_root/.agent/.pr-to-green-auth.XXXXXX") ||
    die 'could not create authorization output'
chmod 600 "$output_tmp"
cp -- "$work_dir/authorization.json" "$output_tmp"
mv -f -- "$output_tmp" "$output"
output_tmp=''
printf 'authorization=%s queue=%s\n' "$output" "$(jq -r 'length' "$work_dir/queue.json")"
