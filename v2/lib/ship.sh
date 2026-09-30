# shellcheck shell=bash
# ak ship: commit with the harness trailer, push, and open the draft PR when none exists.

BANNER='This was written agentically; verify its assertions:'

# The attribution line that closes every body this kit posts.
attribution() {
    local name
    name=$(trailer)
    printf '🤖 Co-authored by the %s agent.\n' "${name%% <*}"
}

# ship_pr_find: prints "NUMBER URL" for the open PR from the current branch, or nothing.
ship_pr_find() {
    local repo branch json
    repo=$(slug)
    branch=$(git branch --show-current)
    json=$(gh api "repos/$repo/pulls?head=${repo%%/*}:$branch&state=open") ||
        die "could not list pull requests for $branch" "gh auth status"
    jq -r 'if length > 0 then "\(.[0].number) \(.[0].html_url)" else empty end' <<<"$json"
}

ship_title() {
    local file line
    file="$(ak_dir)/issue.md"
    if [[ -f $file ]]; then
        line=$(grep -m1 -E '^title: ' "$file" || grep -m1 -E '^# ' "$file" || true)
        line=${line#title: }
        line=${line#\# }
        [[ -z $line ]] || { printf '%s\n' "$line"; return 0; }
    fi
    git log -1 --format=%s
}

# ship_body MESSAGE BODY_FILE: writes the PR body to .ak/pr-body.md and prints its path.
ship_body() {
    local message=$1 source=$2 out
    out="$(ak_dir)/pr-body.md"
    {
        printf '%s\n\n' "$BANNER"
        if [[ -n $source ]]; then cat -- "$source"; else printf '%s\n' "$message"; fi
        printf '\nCloses #%s\n\n' "$(issue_number)"
        attribution
    } >"$out"
    printf '%s\n' "$out"
}

ship_commit() {
    local message=$1
    git add -A
    git diff --cached --quiet && return 0
    git commit -q -m "$message" -m "Co-Authored-By: $(trailer)"
}

ship_push() {
    local branch=$1 log
    log="$(ak_dir)/logs/push.log"
    mkdir -p -- "$(dirname -- "$log")"
    git push -u origin HEAD >"$log" 2>&1 ||
        die "push of $branch was rejected: $(tail -n 1 -- "$log")" \
            "git pull --rebase origin $branch && ak ship --message '<message>'"
}

ship_create_pr() {
    local branch=$1 base=$2 body=$3 json
    json=$(gh api -X POST "repos/$(slug)/pulls" -f "title=$(ship_title)" -f "head=$branch" \
        -f "base=$base" -F draft=true -F "body=@$body") ||
        die "could not create the draft PR for $branch" "gh auth status"
    jq -r '"\(.number) \(.html_url)"' <<<"$json"
}

cmd_main() {
    local message="" body_file="" branch base pr body board=""
    while (($#)); do
        case $1 in
            --message) message=${2:-}; shift 2 || usage_die "--message needs a value" ;;
            --body-file) body_file=${2:-}; shift 2 || usage_die "--body-file needs a value" ;;
            *) usage_die "unknown argument: $1" ;;
        esac
    done
    [[ -n $message ]] || usage_die "usage: ak ship --message M [--body-file F]"
    [[ -z $body_file || -f $body_file ]] || die "body file not found: $body_file" "ak ship --message '$message'"
    [[ -z $body_file ]] || body_file="$(cd -- "$(dirname -- "$body_file")" && pwd)/$(basename -- "$body_file")"
    cd -- "$(worktree_root)" || exit 1
    branch=$(git branch --show-current)
    base=$(work_base)
    [[ -n $branch && $branch != "$base" ]] ||
        die "refusing to ship from the base branch ${branch:-(detached)}" "git checkout -b feat/issue-N"
    ship_commit "$message"
    [[ -n $(git rev-list "origin/$base..HEAD" 2>/dev/null) ]] ||
        die "nothing to ship: HEAD has no commits ahead of origin/$base" "commit your change, then ak ship --message '$message'"
    ship_push "$branch"
    pr=$(ship_pr_find)
    if [[ -z $pr ]]; then
        body=$(ship_body "$message" "$body_file") || exit 1
        pr=$(ship_create_pr "$branch" "$base" "$body")
        board=$("$AK_HOME/bin/ak" board --issue "$(issue_number)" --status "In review" 2>/dev/null | head -n 1) || true
    fi
    printf 'pr=%s head=%s\n' "${pr#* }" "$(git rev-parse HEAD)"
    [[ -z ${board:-} ]] || printf '%s\n' "$board"
}
