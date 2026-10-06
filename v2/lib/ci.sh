# shellcheck shell=bash
# ak ci: wait for the check runs on the pushed head; on red, print each failing job's error lines.

CI_MAX_LINES=20

# The local head, refused unless origin's branch already points at it.
ci_head() {
    local head branch remote
    head=$(git rev-parse HEAD)
    branch=$(git branch --show-current)
    # From the main checkout it read main's head and sent the root to ak ship (field run 2026-10-05).
    [[ $branch != "$(base_branch)" ]] ||
        die "ak ci runs in the PR's worktree" "cd $(main_root)/$(cfg AGENT_WORKTREE_ROOT .worktrees)/<branch> && ak ci"
    remote=$(git ls-remote origin "refs/heads/$branch" 2>/dev/null | cut -f1)
    [[ $remote == "$head" ]] ||
        die "HEAD ${head:0:12} is not pushed to origin/$branch" "ak ship --message '<conventional commit>'"
    printf '%s\n' "$head"
}

# ci_runs SHA: one compact JSON array of {name, done, bad, url}. A conclusion means done, whatever status says.
ci_runs() {
    local json
    json=$(gh api "repos/$(slug)/commits/$1/check-runs?per_page=100") ||
        die "could not read check runs for ${1:0:12}" "gh auth status"
    # A check name is text from the repository's workflows that ak prints for an agent to read: keep plain name
    # characters only, 60 at most.
    jq -c '[.check_runs[] | {name: (.name | gsub("[^A-Za-z0-9 _.()/-]"; "") | .[0:60]),
        done: (.conclusion != null or .status == "completed"),
        bad: ((.conclusion // "success") | IN("success", "neutral", "skipped") | not),
        url: (.details_url // .html_url // "")}]' <<<"$json"
}

# ci_missing DONE: the AGENT_REQUIRED_CHECKS names (comma/space list) without a completed run in DONE (one name per
# line), comma-joined. A stacked PR that conflicted with its base got no pull_request workflow, and its head read as
# green on CodeQL and a push lint alone (field run 2026-10-05).
ci_missing() {
    local names name out=''
    IFS=', ' read -ra names <<<"$(cfg AGENT_REQUIRED_CHECKS)"
    for name in "${names[@]}"; do
        [[ -z $name ]] || grep -qxF -- "$name" <<<"$1" || out+="${out:+,}$name"
    done
    printf '%s\n' "$out"
}

# ci_summary RUNS: "ci=STATE checks=N failing=a,b [missing=c]". No runs yet, or a required check without a completed
# run, counts as pending.
ci_summary() {
    local missing
    missing=$(ci_missing "$(jq -r '.[] | select(.done) | .name' <<<"$1")")
    jq -r --arg m "$missing" '(length) as $n | (map(select(.done and .bad) | .name) | join(",")) as $f
        | (if $n == 0 or $m != "" or any(.[]; .done | not) then "pending" elif $f != "" then "red" else "green" end) as $s
        | "ci=\($s) checks=\($n) failing=\($f)" + (if $m == "" then "" else " missing=\($m)" end)' <<<"$1"
}

# ci_blocked: refuse while the branch's open PR conflicts with its base. GitHub runs no pull_request workflow on such a
# PR, so the head's checks are not the PR's (field run 2026-10-05: a parent's squash-merge left its child dirty, the
# child read as green and the next issue was spawned on it). No open PR is today's path; so is an API failure, named on
# stderr so the gap is visible rather than read as "no PR".
ci_blocked() {
    local slug list n json base
    slug=$(slug)
    list=$(gh api "repos/$slug/pulls?head=${slug%%/*}:$(git branch --show-current)&state=open" 2>/dev/null) ||
        { printf "note=could not list the branch's PR; judging the head's checks alone\n" >&2; return 0; }
    n=$(jq -r '.[0].number // empty' <<<"$list" 2>/dev/null) || n=''
    [[ $n =~ ^[0-9]+$ ]] || return 0
    json=$(gh api "repos/$slug/pulls/$n" 2>/dev/null) ||
        { printf "note=could not read PR #%s state; judging the head's checks alone\n" "$n" >&2; return 0; }
    [[ $(jq -r '.mergeable_state // ""' <<<"$json") == dirty ]] || return 0
    # The base name is PR text on its way into a command the agent runs: an odd one is described, not echoed.
    base=$(jq -r '.base.ref // ""' <<<"$json")
    [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
        die "ci=blocked note=PR #$n conflicts with its base branch, so GitHub runs no PR checks" "git fetch origin && git merge origin/<its base branch>"
    die "ci=blocked note=PR #$n conflicts with $base, so GitHub runs no PR checks" "git fetch origin && git merge origin/$base"
}

# ci_wait SHA TIMEOUT ONCE: prints the final RUNS array after polling.
ci_wait() {
    local sha=$1 deadline=$((SECONDS + $2)) once=$3 grace=$((SECONDS + ${AK_CI_GRACE:-180})) runs hinted=0
    while :; do
        runs=$(ci_runs "$sha") || exit 1
        [[ $(ci_summary "$runs") == ci=pending* && $once == 0 ]] || break
        ((hinted)) || { printf 'ci pending on %s: wait on this with the longest wait your shell allows\n' "${sha:0:12}" >&2; hinted=1; }
        ((SECONDS < deadline)) || break
        # A repo with no CI never registers a run; stop waiting after the grace period.
        [[ $runs != '[]' ]] || ((SECONDS < grace)) || break
        sleep "${AK_CI_INTERVAL:-30}"
    done
    printf '%s\n' "$runs"
}

# ci_job_errors NAME URL BUDGET: save the job log stripped of ANSI, print a header and its error lines.
ci_job_errors() {
    local name=$1 url=$2 budget=$3 id dir log esc=$'\033' cr=$'\r'
    ((budget > 1)) || return 0
    if [[ ! $url =~ /job/([0-9]+) ]]; then
        printf -- '--- %s: no Actions job log (%s)\n' "$name" "${url:-no url}"
        return 0
    fi
    id=${BASH_REMATCH[1]}
    dir="$(ak_dir)/ci"
    log="$dir/$id.log"
    mkdir -p -- "$dir"
    rm -f -- "$log"
    if ! gh api --allow-escape-sequences "repos/$(slug)/actions/jobs/$id/logs" 2>/dev/null |
        sed -E "s/${esc}\\[[0-9;?]*[A-Za-z]//g; s/${cr}\$//; s/^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z //" >"$log"; then
        printf -- '--- %s: log unavailable for job %s\n' "$name" "$id"
        return 0
    fi
    printf -- '--- %s (.ak/ci/%s.log)\n' "$name" "$id"
    grep -E '[Ee]rror|ERROR|FAIL|Exception' -- "$log" | cut -c1-200 | head -n "$((budget - 1 < 8 ? budget - 1 : 8))" || true
}

# ci_inherited RUNS: on a stacked branch, the failing checks that also fail on the base branch's own head. A field
# worker spent its turns grepping its tree for a failure that came from the PR below it.
ci_inherited() {
    local base sha names
    base=$(work_base)
    [[ $base != "$(base_branch)" ]] || return 0
    sha=$(git ls-remote origin "refs/heads/$base" 2>/dev/null | cut -f1)
    [[ -n $sha ]] || return 0
    names=$(LC_ALL=C comm -12 <(jq -r '.[] | select(.done and .bad) | .name' <<<"$1" | LC_ALL=C sort -u) \
        <(ci_runs "$sha" 2>/dev/null | jq -r '.[] | select(.done and .bad) | .name' | LC_ALL=C sort -u) | paste -sd, -)
    [[ -z $names ]] ||
        printf 'inherited=%s from=%s note=the base branch fails these checks too; fix any error line its log does not share\n' \
            "$names" "$base"
}

# ci_failed_step URL: "/<step>" for the first failed step of an Actions job, or nothing. A field note said only
# "Server", which did not tell the operator that the step was the type check no local suite runs. The step name is
# workflow text like the job name, so it gets the same plain characters.
ci_failed_step() {
    local step
    [[ $1 =~ /job/([0-9]+) ]] || return 0
    step=$(gh api "repos/$(slug)/actions/jobs/${BASH_REMATCH[1]}" \
        --jq '[.steps[]? | select(.conclusion == "failure") | .name][0] // "" | gsub("[^A-Za-z0-9 _.()-]"; "") | .[0:40]' 2>/dev/null) || return 0
    [[ -z $step ]] || printf '/%s' "$step"
}

# ci_only RUNS INHERITED_LINE: record and print the failing checks that are this branch's own. They failed after local
# verify let the push through, so each costs a push and a CI round on every PR until a local suite covers it. A field
# repo paid that round for a type check and a docs lint on PR after PR; the receipt now names them to the operator.
# ci_only_trusted FILE: the record counts only as a regular file ak wrote here, never a link or a file the checkout
# brought along (a tracked .ak/ci-only would put a branch author's text in the result note).
ci_only_trusted() {
    local tracked
    [[ -f $1 && ! -L $1 ]] || return 1
    # Not being able to ask git is not "untracked".
    tracked=$(git ls-files -- "$1" 2>/dev/null) || return 1
    [[ -z $tracked ]]
}

ci_only() {
    local file names name url
    file="$(ak_dir)/ci-only"
    names=$(jq -r '.[] | select(.done and .bad) | [.name, .url] | @tsv' <<<"$1" |
        awk -F'\t' -v list="$(sed -nE 's/^inherited=(.*) from=.*/\1/p' <<<"$2")" \
            'BEGIN { n = split(list, a, ","); for (i = 1; i <= n; i++) skip[a[i]] } !($1 in skip)' |
        while IFS=$'\t' read -r name url; do
            [[ -n $name ]] || continue
            printf '%s%s\n' "$name" "$(ci_failed_step "$url")"
        done)
    [[ -n $names ]] || return 0
    ci_only_trusted "$file" || rm -f -- "$file"
    rm -f -- "$file.tmp"
    { cat -- "$file" 2>/dev/null; printf '%s\n' "$names"; } | LC_ALL=C sort -u | head -n 20 >"$file.tmp" && mv -f -- "$file.tmp" "$file"
    printf 'ci-only=%s note=failed in CI after local verify; an AGENT_CMD_<NAME> suite in .agent/config.env would catch it before the push\n' \
        "$(paste -sd, - <<<"$names")"
}

ci_print_failures() {
    local runs=$1 name url used=1 out
    while IFS=$'\t' read -r name url; do
        out=$(ci_job_errors "$name" "$url" $((CI_MAX_LINES - used)))
        [[ -n $out ]] || continue
        printf '%s\n' "$out"
        used=$((used + $(wc -l <<<"$out")))
    done < <(jq -r '.[] | select(.done and .bad) | [.name, .url] | @tsv' <<<"$runs")
}

cmd_main() {
    local timeout=1800 once=0 sha runs line inherited
    while (($#)); do
        case $1 in
            --timeout) timeout=${2:-}; shift 2 || usage_die "--timeout needs seconds" ;;
            --once) once=1; shift ;;
            *) usage_die "unknown argument: $1" ;;
        esac
    done
    [[ $timeout =~ ^[0-9]+$ ]] || usage_die "--timeout must be whole seconds"
    cd -- "$(worktree_root)" || exit 1
    sha=$(ci_head)
    ci_blocked
    runs=$(ci_wait "$sha" "$timeout" "$once")
    line=$(ci_summary "$runs")
    if [[ $runs == '[]' && $once == 0 ]]; then
        printf 'ci=none checks=0 note=no check runs registered; local verify is the oracle\n'
        return 0
    fi
    printf '%s\n' "$line"
    case $line in
        ci=green*) return 0 ;;
        ci=red*)
            inherited=$(ci_inherited "$runs")
            [[ -z $inherited ]] || printf '%s\n' "$inherited"
            ci_only "$runs" "$inherited"
            ci_print_failures "$runs"
            return 1
            ;;
        *) return 3 ;;
    esac
}
