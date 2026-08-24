#!/usr/bin/env bash
# Derive the confirmed pr-to-green authorization artifact from live queue data.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
QUEUE_HELPER=${AUTHORIZE_QUEUE_HELPER:-$SCRIPT_DIR/pr-queue.sh}

repo=''
repo_root=''
merge_plan=''
ready_transition=0
auto_merge_choice=''
merge_method=''
branch_choice=''
declare -a providers=()
declare -a prs=()

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<EOF
usage: $PROGRAM --repo OWNER/REPO --repo-root DIR --ready-transition
       (--auto-merge --merge-method squash|merge|rebase
          (--delete-branch|--keep-branch) | --no-auto-merge)
       (--provider NAME:ACTION:SOURCE ... | --no-providers)
       [--merge-plan FILE] [--pr N ...]

Derives .agent/pr-to-green-auth.json from fresh pr-queue.sh JSON. ACTION is
trigger, observe, or disabled. No head SHA or base ref is accepted as input.
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
        --pr) (($# >= 2)) || usage; prs+=("$2"); shift 2 ;;
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
            providers+=(__NONE__)
            shift
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

((${#providers[@]} > 0)) ||
    die 'pass each --provider NAME:ACTION:SOURCE or pass --no-providers explicitly'
if ((${#providers[@]} > 1)); then
    for provider in "${providers[@]}"; do
        [[ $provider != __NONE__ ]] || die '--no-providers cannot be combined with --provider'
    done
fi
for pr in "${prs[@]}"; do
    [[ $pr =~ ^[1-9][0-9]*$ ]] || die "--pr expects a positive integer: $pr"
done
command -v jq >/dev/null 2>&1 || die 'jq is required; authorization evidence unavailable'
[[ -x $QUEUE_HELPER ]] || die "queue helper is not executable: $QUEUE_HELPER"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/authorize-queue.XXXXXX") ||
    die 'could not create work directory'
output_tmp=''
cleanup() {
    rm -rf -- "$work_dir"
    [[ -z $output_tmp || ! -e $output_tmp ]] || rm -f -- "$output_tmp"
}
trap cleanup EXIT HUP INT TERM

: >"$work_dir/providers.jsonl"
if [[ ${providers[0]} != __NONE__ ]]; then
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

queue_args=(--repo "$repo" --repo-root "$repo_root" --format json)
[[ -z $merge_plan ]] || queue_args+=(--merge-plan "$merge_plan")
for pr in "${prs[@]}"; do queue_args+=(--pr "$pr"); done
"$QUEUE_HELPER" "${queue_args[@]}" >"$work_dir/queue.json" ||
    die 'live queue derivation failed'
jq -e '
  type == "array" and length > 0 and
  all(.[];
    (.pr | type) == "number" and .pr > 0 and (.pr | floor) == .pr and
    (.state == "RUNNABLE" or .state == "WAITING_FOR_MERGE" or
      .state == "RETARGET_REQUIRED" or .state == "BLOCKED" or
      .state == "MERGEABLE_UNKNOWN") and
    (.sha | type) == "string" and (.sha | test("^[0-9a-f]{40}$")) and
    (.base | type) == "string" and (.base | length) > 0) and
  ((map(.pr) | unique | length) == length)
' "$work_dir/queue.json" >/dev/null 2>&1 || die 'queue helper returned malformed JSON'

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
