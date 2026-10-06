# shellcheck shell=bash
# ak onboard [--project N --owner O]: write the .agent/config.env keys ak reads from what the repository already
# says: slug and base from git, the linked project board and its Status options from one GraphQL read, and the
# setup/test commands from marker files. Keys already in the file are kept; a re-run changes nothing.

CANON_STATUS='Ready|In progress|In review|Done'
# shellcheck disable=SC2016  # GraphQL variables, bound by gh's -F flags.
LINKED_QUERY='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { projectsV2(first: 20) { nodes
  { number title closed owner { ... on Organization { login } ... on User { login } }
    field(name: "Status") { ... on ProjectV2SingleSelectField { options { name } } } } } } }'
# shellcheck disable=SC2016
NAMED_QUERY='query($owner: String!, $number: Int!) { repositoryOwner(login: $owner) { projectV2(number: $number)
  { number title closed owner { ... on Organization { login } ... on User { login } }
    field(name: "Status") { ... on ProjectV2SingleSelectField { options { name } } } } } }'
# Open boards as `number<TAB>owner<TAB>title<TAB>status,options`.
BOARD_ROWS='[.. | objects | select(has("number") and has("title"))] | map(select(.closed != true)) | .[] |
  [.number, .owner.login, .title, ([.field.options[]?.name] | join(","))] | @tsv'

# onboard_set KEY VALUE: queue KEY=VALUE unless the file already has KEY or VALUE is empty.
onboard_set() {
    [[ -n $2 ]] || return 0
    if grep -qE "^$1=" "$FILE" 2>/dev/null; then KEPT=$((KEPT + 1)); else LINES+=("$1=$2"); fi
}

# onboard_commands DIR: `setup<TAB>command` and `test<TAB>command` for the toolchain whose marker files sit in DIR.
onboard_commands() {
    local d=$1 pm install
    if [[ -f $d/Makefile ]] && grep -qE '^test:' "$d/Makefile"; then
        printf 'test\tmake test\n'
    elif [[ -f $d/package.json ]]; then
        if [[ -f $d/pnpm-lock.yaml ]]; then pm=pnpm install='pnpm install --frozen-lockfile'
        elif [[ -f $d/yarn.lock ]]; then pm=yarn install='yarn install --frozen-lockfile'
        elif [[ -f $d/bun.lockb || -f $d/bun.lock ]]; then pm=bun install='bun install'
        elif [[ -f $d/package-lock.json ]]; then pm=npm install='npm ci'
        else pm=npm install='npm install'; fi
        printf 'setup\t%s\n' "$install"
        ! jq -e '.scripts.test' "$d/package.json" >/dev/null 2>&1 || printf 'test\t%s test\n' "$pm"
    elif [[ -f $d/pyproject.toml || -f $d/setup.cfg || -f $d/setup.py || -f $d/requirements.txt ]]; then
        if [[ -f $d/uv.lock ]]; then printf 'setup\tuv sync\ntest\tuv run pytest\n'
        elif [[ -f $d/poetry.lock ]]; then printf 'setup\tpoetry install\ntest\tpoetry run pytest\n'
        else printf 'test\tpython -m pytest\n'; fi
    elif [[ -f $d/Cargo.toml ]]; then printf 'test\tcargo test\n'
    elif [[ -f $d/go.mod ]]; then printf 'test\tgo test ./...\n'
    elif [[ -f $d/Gemfile ]]; then
        printf 'setup\tbundle install\ntest\t%s\n' "$([[ -d $d/spec ]] && echo 'bundle exec rspec' || echo 'bundle exec rake test')"
    elif compgen -G "$d/*.sln" >/dev/null || compgen -G "$d/*.csproj" >/dev/null; then printf 'test\tdotnet test\n'
    elif [[ -x $d/tests/run-tests.sh ]]; then printf 'test\ttests/run-tests.sh\n'
    fi
}

# onboard_suite_dirs: tracked directories (depth ≤ 2, not the root) holding their own toolchain marker.
onboard_suite_dirs() {
    git ls-files -- '*/package.json' '*/pyproject.toml' '*/setup.cfg' '*/setup.py' '*/Cargo.toml' '*/go.mod' \
        '*/Gemfile' '*/Makefile' '*/*.sln' '*/*.csproj' 2>/dev/null |
        awk -F/ 'NF > 1 && NF <= 3 && $1 !~ /^\./ { NF--; print }' OFS=/ | LC_ALL=C sort -u |
        grep -E '^[A-Za-z0-9._][A-Za-z0-9._/-]*$' || true  # the path lands in a command ak setup runs: plain characters only
}

# onboard_toolchain: queue SETUP, TEST and one suite per toolchain directory; `none` when nothing was found.
onboard_toolchain() {
    local dir name kind command suite setup='' test='' installs=() found=0
    while IFS=$'\t' read -r kind command; do
        [[ $kind == setup ]] && setup=$command
        [[ $kind == test ]] && test=$command
    done < <(onboard_commands .)
    while IFS= read -r dir; do
        [[ -n $dir ]] || continue
        name=$(tr '[:lower:]/-' '[:upper:]__' <<<"$dir" | tr -c 'A-Z0-9_\n' '_')
        case $name in SETUP | VERIFY | TEST | *_FIX) continue ;; esac
        suite=$(onboard_commands "$dir")
        command=$(sed -n 's/^test\t//p' <<<"$suite")
        [[ -n $command ]] || continue
        onboard_set "AGENT_CMD_$name" "$command"
        onboard_set "AGENT_RUNDIR_$name" "$dir"
        found=1
        # A directory's install matters only when a suite runs there: a tool's own package.json is not a suite.
        command=$(sed -n 's/^setup\t//p' <<<"$suite")
        [[ -z $command ]] || installs+=("(cd $dir && $command)")
    done < <(onboard_suite_dirs)
    [[ -n $setup || ${#installs[@]} == 0 ]] || setup=$(IFS='&'; printf '%s' "${installs[*]}" | sed 's/)&(/) \&\& (/g')
    onboard_set AGENT_CMD_SETUP "$setup"
    onboard_set AGENT_CMD_TEST "$test"
    [[ -n $test ]] || ((found)) || NOTES+=('commands=none; append AGENT_CMD_TEST=<the command CI runs> to .agent/config.env')
}

# onboard_board [NUMBER OWNER]: read the linked boards (or the named one), queue the owner and number of the one to use.
onboard_board() {
    local rows owner count fix
    owner=$(slug); owner=${owner%%/*}
    if [[ -n ${1:-} ]]; then
        rows=$(gh api graphql -f "query=$NAMED_QUERY" -F "owner=$2" -F "number=$1" 2>&1)
    else
        rows=$(gh api graphql -f "query=$LINKED_QUERY" -F "owner=$owner" -F "name=$(slug | cut -d/ -f2)" 2>&1)
    fi || { NOTES+=("board=unavailable ($rows); fix: gh auth status"); return 0; }
    rows=$(jq -r "$BOARD_ROWS" <<<"$rows" 2>/dev/null) || { NOTES+=("board=unavailable (unreadable reply); fix: gh auth status"); return 0; }
    count=$(grep -c . <<<"$rows" || true)
    if ((count == 0)); then
        [[ -n ${1:-} ]] && fix="board=none; $2 has no open project $1" ||
            fix='board=none; ak plan reads AGENT_READY_LABEL=<label> instead, or name one: ak onboard --project N --owner O'
        NOTES+=("$fix")
    elif ((count > 1)); then
        NOTES+=('board=choose' "$(head -n 5 <<<"$rows" | awk -F'\t' '{ print "  " $1 " " $3 }')" \
            "fix: ak onboard --project N --owner $(head -n 1 <<<"$rows" | cut -f2)")
    else
        onboard_pick "$rows"
    fi
}

# onboard_pick ROW: queue the board keys and note its Status options and any canonical column it lacks.
onboard_pick() {
    local number owner title status missing=() want
    IFS=$'\t' read -r number owner title status <<<"$1"
    onboard_set AGENT_PROJECT_OWNER "$owner"
    onboard_set AGENT_PROJECT_NUMBER "$number"
    NOTES+=("board=$number \"$title\" status=$status")
    while IFS= read -r want; do
        grep -qiE "(^|,)$want(,|$)" <<<"$status" || missing+=("$want")
    done < <(tr '|' '\n' <<<"$CANON_STATUS")
    ((${#missing[@]} == 0)) || NOTES+=("missing-status=$(IFS=,; printf '%s' "${missing[*]}") (ak board no-ops a move there)")
}

# onboard_exclude: an untracked .agent/ stays out of git through the shared info/exclude, like .ak/.
onboard_exclude() {
    local exclude
    ! git ls-files --error-unmatch -- "$FILE" >/dev/null 2>&1 || return 0
    exclude="$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    mkdir -p -- "$(dirname -- "$exclude")"
    grep -qxF '.agent/' "$exclude" 2>/dev/null || printf '.agent/\n' >>"$exclude"
}

cmd_main() {
    local project='' owner='' base line shown
    while (($#)); do
        case $1 in
            --project) project=${2:-}; shift 2 || usage_die 'ak onboard: --project needs a number' ;;
            --owner) owner=${2:-}; shift 2 || usage_die 'ak onboard: --owner needs a login' ;;
            *) usage_die "ak onboard: unknown argument: $1" ;;
        esac
    done
    [[ -z $project$owner || ($project =~ ^[0-9]+$ && -n $owner) ]] || usage_die 'usage: ak onboard [--project N --owner O]'
    cd -- "$(main_root)" || exit 1
    FILE=.agent/config.env KEPT=0 LINES=() NOTES=()
    [[ ! -L .agent && ! -L $FILE ]] || die "$FILE is behind a symlink, which onboard will not write through" "rm $FILE"
    onboard_set AGENT_REPO_SLUG "$(slug)"
    base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [[ -n $base ]] || base=origin/$(gh api "repos/$(slug)" --jq .default_branch 2>/dev/null || echo main)
    onboard_set AGENT_BASE_BRANCH "${base#origin/}"
    onboard_board "$project" "$owner"
    onboard_toolchain
    mkdir -p -- .agent
    [[ -f $FILE ]] || printf '# ak reads these KEY=value lines; edit freely. ak onboard adds missing keys and keeps every line here.\n' >"$FILE"
    ((${#LINES[@]} == 0)) || printf '%s\n' "${LINES[@]}" >>"$FILE"
    onboard_exclude
    printf 'wrote=%s keys=%d kept=%d\n' "$FILE" "${#LINES[@]}" "$KEPT"
    shown=${#LINES[@]}; ((shown <= 14)) || shown=12
    for line in "${LINES[@]:0:$shown}"; do printf '%s\n' "$line"; done
    ((shown == ${#LINES[@]})) || printf '(+%d more in %s)\n' $((${#LINES[@]} - shown)) "$FILE"
    ((${#NOTES[@]} == 0)) || printf '%s\n' "${NOTES[@]}"
    if grep -qE '^AGENT_CMD_SETUP=.' "$FILE"; then printf 'next=ak setup && ak verify --full\n'; else printf 'next=ak verify --full\n'; fi
}
