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

# ship_merged_pr BRANCH: the URL of an already merged PR from BRANCH, or nothing.
ship_merged_pr() {
    local repo
    repo=$(slug)
    gh api "repos/$repo/pulls?head=${repo%%/*}:$1&state=closed&per_page=10" |
        jq -r '[.[] | select(.merged_at != null)][0].html_url // empty'
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

# ship_body_check FILE: refuse a PR description a person cannot follow. Field PR bodies packed every change into one
# sentence of abstractions under "Why/What", and the operator rewrote each by hand. The sections give the reader the
# problem first; the length cap turns a sentence that lists five changes into bullets.
ship_body_check() {
    local file=$1 heading missing=() long found max=${AK_BODY_SENTENCE_WORDS:-45}
    for heading in 'The problem' 'What changed' 'Tests'; do
        awk '/^[[:space:]]*```/ { fence = !fence } !fence' "$file" |
            grep -qixE "##[[:space:]]+${heading}[[:space:]]*" || missing+=("## $heading")
    done
    ((${#missing[@]} == 0)) || die "the PR description lacks: $(printf '%s, ' "${missing[@]}" | sed 's/, $//')" \
        "add the sections to $file as step 3 of your playbook describes, then run ak ship again"
    # Two things field descriptions still carried: the Tests section ended in a pasted 330-character command and
    # `ak verify` status words, and a change was explained as "required for Packet 7", a label from the issue's plan.
    found=$(awk '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^[[:space:]]*##[[:space:]]/ {
            section = tolower($0)
            gsub(/^[[:space:]]*##[[:space:]]+|[[:space:]]+$/, "", section)
        }
        section == "tests" {
            span = 0
            for (rest = $0; match(rest, /`[^`]*`/); rest = substr(rest, RSTART + RLENGTH)) if (RLENGTH > 100) span = 1
            if (span || /(oracle|verify)=[a-z]+/) { print "log\t" substr($0, 1, 60); exit }
        }
        section != "still to do" {
            gsub(/`[^`]*`/, "")
            # A whole label only: "SubTask 3" and "Task 3D" are other words.
            line = " " $0 " "
            if (match(line, /[^A-Za-z0-9](Packet|Task|Phase|Wave|Slice|Milestone|Workstream|Sprint) [0-9]+[^A-Za-z0-9]/)) {
                print "label\t" substr(line, RSTART + 1, RLENGTH - 2)
                exit
            }
        }' "$file")
    case $found in
        log*) die "the ## Tests section carries run output, starting: ${found#*$'\t'}" \
            "say there what each test file proves and drop commands and status lines from $file, then run ak ship again" ;;
        label*) die "the PR description names \"${found#*$'\t'}\", a label from the issue or its plan that the reader has not seen" \
            "say what that part is in plain words in $file (a real product name goes in backticks), then run ak ship again" ;;
    esac
    # Longest sentence, outside fenced blocks; a list item or heading ends a sentence, and code spans count as one word.
    long=$(awk -v max="$max" '
        /^[[:space:]]*```/ { fence = !fence; next }
        fence { next }
        /^#/ { flush(); next }
        /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]|^[[:space:]]*$/ { flush() }
        { gsub(/`[^`]*`/, "CODE"); buf = buf " " $0 }
        END { flush(); if (worst != "") print worst }
        function flush(   n, i, parts, words, w) {
            n = split(buf, parts, /[.!?:;]([[:space:]]|$)/)
            for (i = 1; i <= n; i++) {
                sub(/^[[:space:]]+/, "", parts[i])
                w = split(parts[i], words, /[[:space:]]+/)
                if (w > max && worst == "") worst = words[1] " " words[2] " " words[3] " " words[4] " " words[5]
            }
            buf = ""
        }' "$file")
    [[ -z $long ]] || die "the PR description has a sentence over $max words, starting: $long" \
        "split it into shorter sentences or one bullet per change in $file, then run ak ship again"
}

# closing_words and closing_ref N: the pieces of GitHub's closing-keyword syntax for issue N of this repository
# ("Closes #7", "fixed: #7", "resolves owner/repo#7", "close https://github.com/owner/repo/issues/7"). ship and
# receipt must read a body the way GitHub does, or a line they miss still closes the issue. N is digits only.
closing_words() {
    printf '%s' 'close[sd]?|fix(e[sd])?|resolve[sd]?'
}

closing_ref() {
    local repo
    [[ $1 =~ ^[0-9]+$ ]] || die "not an issue number: $1" "echo <number> > .ak/issue"
    # Only this repository's issue: owner/repo#N or a URL for another repository is someone else's issue N.
    repo=$(slug | sed 's/[^A-Za-z0-9_/-]/\\&/g')
    printf ':?[[:space:]]+(#%s|GH-%s|%s#%s|https?://(www\\.)?github\\.com/%s/issues/%s)' "$1" "$1" "$repo" "$1" "$repo" "$1"
}

# ship_body MESSAGE BODY_FILE: writes the PR body to .ak/pr-body.md and prints its path.
ship_body() {
    local message=$1 source=$2 out n ref
    n=$(issue_number)
    # Resolved before the body is written: a pattern that failed to build must stop ship, not read as "already closes".
    ref=$(closing_ref "$n") || exit 1
    out="$(ak_dir)/pr-body.md"
    {
        printf '%s\n\n' "$BANNER"
        if [[ -n $source ]]; then cat -- "$source"; else printf '%s\n' "$message"; fi
        # A worker that wrote its own closing line gets no second one (a field PR said "Closes #N" twice).
        [[ -n $source ]] && grep -qiE "(^|[^[:alnum:]])($(closing_words)|part of)$ref([^0-9]|\$)" -- "$source" ||
            printf '\nCloses #%s\n' "$n"
        printf '\n'
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

# ship_resolved: after a merge-down, HEAD must contain the base it conflicted with. A field resolver committed the base's
# changes by hand instead of merging, so the next update conflicted again and a second resolver was spawned.
ship_resolved() {
    local ref
    [[ -f .ak/resolve ]] || return 0
    ref=$(<.ak/resolve)
    git fetch -q origin "${ref#origin/}" ||
        die "cannot fetch ${ref#origin/} to check the merge-down" "git fetch origin ${ref#origin/}"
    git merge-base --is-ancestor "$ref" HEAD ||
        die "HEAD does not contain $ref yet: a merge-down must merge it, not copy its changes" "git merge $ref"
    rm -f -- .ak/resolve
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
    [[ -z $body_file ]] || ship_body_check "$body_file"
    cd -- "$(worktree_root)" || exit 1
    branch=$(git branch --show-current)
    base=$(work_base)
    [[ -n $branch && $branch != "$base" ]] ||
        die "refusing to ship from the base branch ${branch:-(detached)}" "git checkout -b feat/issue-N"
    ship_commit "$message"
    ship_resolved
    [[ -n $(git rev-list "origin/$base..HEAD" 2>/dev/null) ]] ||
        die "nothing to ship: HEAD has no commits ahead of origin/$base" "commit your change, then ak ship --message '$message'"
    ship_push "$branch"
    pr=$(ship_pr_find)
    if [[ -z $pr ]] && merged=$(ship_merged_pr "$branch") && [[ -n $merged ]]; then
        # This branch's PR already landed; a new PR for it would duplicate the merged work (bench 2026-10-01: #138).
        printf 'pr=%s merged already; nothing new to ship\n' "$merged"
        return 0
    fi
    if [[ -z $pr ]]; then
        body=$(ship_body "$message" "$body_file") || exit 1
        pr=$(ship_create_pr "$branch" "$base" "$body")
        board=$("$AK_HOME/bin/ak" board --issue "$(issue_number)" --status "In review" 2>/dev/null | head -n 1) || true
    fi
    printf 'pr=%s head=%s\n' "${pr#* }" "$(git rev-parse HEAD)"
    [[ -z ${board:-} ]] || printf '%s\n' "$board"
}
