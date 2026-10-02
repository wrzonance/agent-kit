# shellcheck shell=bash
# ak ci: wait for the check runs on the pushed head; on red, print each failing job's error lines.

CI_MAX_LINES=20

# The local head, refused unless origin's branch already points at it.
ci_head() {
    local head branch remote
    head=$(git rev-parse HEAD)
    branch=$(git branch --show-current)
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
    jq -c '[.check_runs[] | {name,
        done: (.conclusion != null or .status == "completed"),
        bad: ((.conclusion // "success") | IN("success", "neutral", "skipped") | not),
        url: (.details_url // .html_url // "")}]' <<<"$json"
}

# ci_summary RUNS: "ci=STATE checks=N failing=a,b". No runs yet counts as pending.
ci_summary() {
    jq -r '(length) as $n | (map(select(.done and .bad) | .name) | join(",")) as $f
        | (if $n == 0 or any(.[]; .done | not) then "pending" elif $f != "" then "red" else "green" end) as $s
        | "ci=\($s) checks=\($n) failing=\($f)"' <<<"$1"
}

# ci_wait SHA TIMEOUT ONCE: prints the final RUNS array after polling.
ci_wait() {
    local sha=$1 deadline=$((SECONDS + $2)) once=$3 grace=$((SECONDS + ${AK_CI_GRACE:-180})) runs
    while :; do
        runs=$(ci_runs "$sha") || exit 1
        [[ $(ci_summary "$runs") == ci=pending* && $once == 0 ]] || break
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
        printf 'inherited=%s from=%s note=the base branch fails these too; it gets fixed there, then update this branch\n' \
            "$names" "$base"
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
    local timeout=1800 once=0 sha runs line
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
    runs=$(ci_wait "$sha" "$timeout" "$once")
    line=$(ci_summary "$runs")
    if [[ $runs == '[]' && $once == 0 ]]; then
        printf 'ci=none checks=0 note=no check runs registered; local verify is the oracle\n'
        return 0
    fi
    printf '%s\n' "$line"
    case $line in
        ci=green*) return 0 ;;
        ci=red*) ci_inherited "$runs"; ci_print_failures "$runs"; return 1 ;;
        *) return 3 ;;
    esac
}
