#!/usr/bin/env bash
# Compose a worker prompt from repository-controlled facts and persisted issue artifacts.
set -euo pipefail

program=${0##*/}
usage() {
    printf 'usage: %s --template issue-lead|fix-batch --worktree PATH --issue N --branch B --worker-model ID --worker-effort E [--write-set GLOB[,GLOB...]] [--yolo] [--chain-base FULL_SHA] [--output PATH]\n' "$program" >&2
}
die() { printf '%s: %s\n' "$program" "$1" >&2; exit 1; }

template_kind=
worktree=
issue=
branch=
worker_model=
worker_effort=
chain_base=
write_set=
output=
yolo=0
while (($#)); do
    case $1 in
        --template|--worktree|--issue|--branch|--worker-model|--worker-effort|--write-set|--chain-base|--output|-o)
            (($# >= 2)) || die "$1 requires a value"
            case $1 in
                --template) template_kind=$2 ;;
                --worktree) worktree=$2 ;;
                --issue) issue=$2 ;;
                --branch) branch=$2 ;;
                --worker-model) worker_model=$2 ;;
                --worker-effort) worker_effort=$2 ;;
                --write-set) write_set=$2 ;;
                --chain-base) chain_base=$2 ;;
                --output|-o) output=$2 ;;
            esac
            shift 2
            ;;
        --yolo) yolo=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
done

[[ $template_kind == issue-lead || $template_kind == fix-batch ]] || die '--template must be issue-lead or fix-batch'
[[ $worktree == /* && -d $worktree ]] || die '--worktree must be an absolute directory'
[[ $issue =~ ^[1-9][0-9]*$ ]] || die '--issue must be a positive integer'
[[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != -* && $branch != *..* && $branch != */ ]] || die '--branch must be a safe branch name'
[[ $worker_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || die '--worker-model must be a safe single-token identifier'
[[ $worker_effort =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || die '--worker-effort must be a safe single-token identifier'
declare -a write_set_globs=()
if [[ -n $write_set ]]; then
    IFS=, read -r -a write_set_globs <<< "$write_set"
    ((${#write_set_globs[@]})) || die '--write-set must name at least one glob'
    for glob in "${write_set_globs[@]}"; do
        # Repository-relative globs only, matching the dispatch-plan validator's
        # own path policy: no absolute paths, no traversal, no control bytes.
        [[ -n $glob && $glob != /* && $glob != *$'\n'* && $glob != *"\\"* ]] ||
            die "--write-set glob is not a repository-relative pattern: $glob"
        case "/$glob/" in
            *'/../'*|*'//'*|*'/./'*) die "--write-set glob contains an unsafe path: $glob" ;;
        esac
    done
fi
if [[ -n $chain_base ]]; then
    ((yolo)) || die '--chain-base requires --yolo'
    [[ $chain_base =~ ^[0-9a-f]{40}$ ]] || die '--chain-base requires a full 40-character lowercase commit SHA'
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
template_file=$script_dir/../references/worker-prompts.md
repo_config=$script_dir/../../.shared/scripts/repo-config.sh
contract_reader=$script_dir/../../.shared/scripts/contract-read.sh
[[ -f $template_file && ! -L $template_file ]] || die "missing template: $template_file"
[[ -x $repo_config ]] || die "missing repo-config.sh: $repo_config"
[[ -x $contract_reader ]] || die "missing contract-read.sh: $contract_reader"

contract=$worktree/.agent/env-contract.txt
spec=$worktree/.agent/fenced-spec.txt
prior_art=$worktree/.agent/fenced-prior-art.txt
[[ -f $spec && ! -L $spec && -r $spec ]] || die "missing persisted spec: $spec"
[[ -f $prior_art && ! -L $prior_art && -r $prior_art ]] || die "missing persisted prior art: $prior_art"
shared_path=$("$contract_reader" --repo-root "$worktree" --get skills.path) ||
    die "could not read trusted skills path from environment contract: $contract"
[[ $shared_path == /* ]] || die 'environment contract has no absolute skills path'
shared_path=$shared_path/.shared/scripts
if grep -Eq '<(PASTE|WHEN)([[:space:]]|[^[:alnum:]_])' "$contract"; then
    die 'environment contract contains an unresolved <PASTE ...> or <WHEN ...> placeholder'
fi

if ! repo_slug=$("$repo_config" --repo-root "$worktree" --get AGENT_REPO_SLUG); then
    die 'could not resolve AGENT_REPO_SLUG from repository config'
fi
if ! base_branch=$("$repo_config" --repo-root "$worktree" --get AGENT_BASE_BRANCH); then
    die 'could not resolve AGENT_BASE_BRANCH from repository config'
fi
[[ -n $repo_slug ]] || die 'AGENT_REPO_SLUG is empty in repository config'
[[ -n $base_branch ]] || die 'AGENT_BASE_BRANCH is empty in repository config'

declare -a command_names=()
focus_declared=0
test_declared=0
is_verification_key() {
    case $1 in
        AGENT_CMD_TEST|AGENT_CMD_*_TEST|AGENT_CMD_LINT|AGENT_CMD_*_LINT|AGENT_CMD_BUILD|AGENT_CMD_*_BUILD|AGENT_CMD_TYPECHECK|AGENT_CMD_*_TYPECHECK|AGENT_CMD_TYPE_CHECK|AGENT_CMD_*_TYPE_CHECK|AGENT_CMD_VERIFY|AGENT_CMD_*_VERIFY|AGENT_CMD_CHECK|AGENT_CMD_*_CHECK|AGENT_CMD_COVERAGE|AGENT_CMD_*_COVERAGE)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
if ! command_list=$("$repo_config" --repo-root "$worktree" --list); then
    die 'could not list repository commands'
fi
while IFS='=' read -r key value; do
    : "$value"
    [[ $key =~ ^AGENT_CMD_[A-Z][A-Z0-9_]*$ ]] || continue
    if [[ $key == AGENT_CMD_TEST_FOCUS ]]; then
        focus_declared=1
        continue
    fi
    if [[ $key == AGENT_CMD_TEST ]]; then
        test_declared=1
    fi
    is_verification_key "$key" || continue
    name=${key#AGENT_CMD_}
    name=${name,,}
    name=${name//_/-}
    command_names+=("$name")
done <<< "$command_list"
((${#command_names[@]})) || die 'repository declares no verification AGENT_CMD_* commands'

query_test_resolution() {
    local resolution='' query_rc=0
    resolution=$("$shared_path/agent-run.sh" --dir "$worktree" --resolve test 2>/dev/null) || query_rc=$?
    case "$query_rc:$resolution" in
        0:declared|4:runner) return 0 ;;
        3:unresolved) return 1 ;;
        *)
            die "agent-run resolution query failed for test (exit $query_rc, output: ${resolution:-none})"
            ;;
    esac
}

# AGENT_CMD_TEST_FOCUS does not imply AGENT_CMD_TEST, because agent-run.sh falls
# back to `runner test`. With neither, the emitted `--cmd test --only` selector
# cannot resolve and would fail in the worker's hands. Refuse at compose time on
# root instead of shipping an instruction that is guaranteed to break.
if ((focus_declared)) && ((test_declared == 0)) && ! query_test_resolution; then
    die 'AGENT_CMD_TEST_FOCUS is declared but no test command resolves: declare AGENT_CMD_TEST or an executable repository runner'
fi

command_flags=
if ((yolo)); then
    command_flags=' --yolo'
    [[ -z $chain_base ]] || command_flags+=" --yolo-base $chain_base"
fi

temporary=$(mktemp "${TMPDIR:-/tmp}/compose-worker-prompt.XXXXXXXXXX") || die 'could not allocate a composition buffer'
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT HUP INT TERM

shell_quote() {
    local value=$1
    value=${value//\'/\'\\\'\'}
    printf "'%s'" "$value"
}

emit_commands() {
    local name helper_path
    helper_path=$(shell_quote "$shared_path/agent-run.sh")
    for name in "${command_names[@]}"; do
        printf '%s --dir %s --cmd %s%s\n' "$helper_path" "\"\$worktree\"" "$name" "$command_flags"
    done
}

emit_focus() {
    if ((focus_declared)); then
        local helper_path
        helper_path=$(shell_quote "$shared_path/agent-run.sh")
        printf 'During red/green iteration, use the repository-declared focused selector:\n'
        printf '%s --dir %s --cmd test --only '\''NAME[,NAME...]'\''%s\n' "$helper_path" "\"\$worktree\"" "$command_flags"
        printf 'It requires AGENT_CMD_TEST_FOCUS and captures evidence only for the named suites; it never claims that skipped suites passed. Run the full declared test command once against the final tree state before handback.\n'
    else
        printf 'No focused selector is declared; use the full declared command for scoped checks and once against the final tree state before handback.\n'
    fi
}

emit_write_set() {
    if ((${#write_set_globs[@]})); then
        local glob
        for glob in "${write_set_globs[@]}"; do
            printf -- '- %s\n' "$glob"
        done
    else
        printf -- '- (no write set pinned for this dispatch; treat the issue'\''s evident scope as the boundary and surface any surprise as a true blocker)\n'
    fi
}

emit_trust_rule() {
    if ((yolo)); then
        if [[ -n $chain_base ]]; then
            printf '# Every generated agent-run.sh command carries --yolo --yolo-base %s.\n' "$chain_base"
        else
            printf '# Every generated agent-run.sh command carries --yolo.\n'
        fi
    else
        printf '# This invocation is attended; generated commands carry no unattended trust flags.\n'
    fi
}

capture=0
section_seen=0
skip_paste=0
skip_when=0
template_placeholder=0
case $template_kind in
    issue-lead) open_fence='````text'; close_fence='````' ;;
    fix-batch) open_fence='```text'; close_fence='```' ;;
esac

while IFS= read -r line || [[ -n $line ]]; do
    if (( ! capture )); then
        if [[ $template_kind == fix-batch ]]; then
            [[ $line == '## Fix-batch worker prompt' ]] && section_seen=1
            [[ $section_seen == 1 && $line == "$open_fence" ]] && capture=1
        else
            [[ $line == "$open_fence" ]] && capture=1
        fi
        continue
    fi
    [[ $line == "$close_fence" ]] && break
    if ((skip_paste)); then
        [[ $line == *'prompt>'* || $line == *'prompt.>'* ]] && skip_paste=0
        continue
    fi
    if ((skip_when)); then
        [[ $line == *'trust record.>'* ]] && skip_when=0
        continue
    fi
    if [[ $line == *'<PASTE, verbatim, the agent-preflight.sh contract'* ]]; then
        cat -- "$contract"
        printf '\n'
        skip_paste=1
        [[ $line == *'prompt>'* || $line == *'prompt.>'* ]] && skip_paste=0
        continue
    fi
    if [[ $line == *'<PASTE the complete output selected by the boundary mode for the approved design-doc contents or full issue body>'* ]]; then
        cat -- "$spec"
        printf '\n'
        continue
    fi
    if [[ $line == *'<PASTE the complete output selected by the boundary mode for the Step 2 prior-art verdicts; say "none" when empty>'* ]]; then
        cat -- "$prior_art"
        printf '\n'
        continue
    fi
    if [[ $line == *'<WHEN this parallel-issues invocation carried --yolo'* ]]; then
        emit_trust_rule
        skip_when=1
        continue
    fi
    # These two are shell ASSIGNMENTS the worker sources, so their values are
    # %q-quoted -- an unquoted path containing spaces parses as an assignment
    # followed by a stray command. The prose spellings of the same paths
    # ("Worktree: ...") are substituted below and deliberately left unquoted.
    if [[ $line == shared='<PASTE the validated shared-scripts path from the contract>' ]]; then
        printf 'shared=%q\n' "$shared_path"
        continue
    fi
    if [[ $line == 'worktree=/ABS/PATH/.worktrees/feat/issue-NNN' ||
        $line == 'worktree=FULL_PATH' ]]; then
        printf 'worktree=%q\n' "$worktree"
        continue
    fi
    if [[ $line == '__DECLARED_COMMANDS__' ]]; then
        emit_commands
        continue
    fi
    if [[ $line == '__DECLARED_FOCUS__' ]]; then
        emit_focus
        continue
    fi
    if [[ $line == '__DECLARED_WRITE_SET__' ]]; then
        emit_write_set
        continue
    fi
    line=${line//OWNER\/REPO/$repo_slug}
    line=${line//\/ABS\/PATH\/.worktrees\/feat\/issue-NNN/$worktree}
    line=${line//FULL_PATH/$worktree}
    line=${line//feat\/issue-NNN/$branch}
    line=${line//NNN/$issue}
    line=${line//__BASE_BRANCH__/$base_branch}
    line=${line//__WORKER_EFFORT__/$worker_effort}
    line=${line//<worker model id selected by the root dispatch>/$worker_model}
    # The worker receives helper paths already resolved from the trusted
    # contract. Keep the assignment for callers composing extra commands, but
    # do not make a dispatched command re-derive the installed tree.
    # shellcheck disable=SC2016  # these patterns intentionally match literal $shared
    line=${line//'$shared'/"$shared_path"}
    [[ $line != 'Spec source: design-doc | issue-body' ]] || line='Spec source: issue-body'
    if [[ $line == *'<PASTE'* || $line == *'<WHEN'* || $line == *'OWNER/REPO'* ||
        $line == *'FULL_PATH'* || $line == *'/ABS/PATH'* ||
        $line == *'__BASE_BRANCH__'* || $line == *'__WORKER_EFFORT__'* ||
        $line == *'__DECLARED_'* || $line == *'<worker model id selected by the root dispatch>'* ]]; then
        template_placeholder=1
    fi
    printf '%s\n' "$line"
done < "$template_file" > "$temporary"

if ((template_placeholder)); then
    die 'unresolved <PASTE ...> or <WHEN ...> placeholder remains'
fi

if [[ -z $output || $output == - ]]; then
    cat -- "$temporary"
else
    [[ ! -L $output ]] || die "refusing symlink output: $output"
    output_dir=$(dirname -- "$output")
    [[ -d $output_dir ]] || die "output directory does not exist: $output_dir"
    output_tmp=$(mktemp "$output_dir/.compose-worker-prompt.XXXXXXXXXX") || die "could not allocate output buffer in $output_dir"
    trap 'rm -f -- "$temporary" "$output_tmp"' EXIT HUP INT TERM
    cat -- "$temporary" > "$output_tmp"
    mv -f -- "$output_tmp" "$output"
    output_tmp=
fi
