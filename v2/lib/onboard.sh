# shellcheck shell=bash
# ak onboard [--project N [--owner O]]: write the .agent/config.env keys ak reads from what the repository already
# says: slug and base from git, the linked project board and its Status options from one GraphQL read, and the
# setup/test commands from marker files. Keys already in the file are kept; a re-run changes nothing.

CANON_STATUS='Ready|In progress|In review|Done'
# shellcheck disable=SC2016  # GraphQL variables, bound by gh's -F flags.
LINKED_QUERY='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { projectsV2(first: 20) { nodes
  { number title closed owner { ... on Organization { login } ... on User { login } }
    field(name: "Status") { ... on ProjectV2SingleSelectField { options { name } } } } } } }'
# shellcheck disable=SC2016
NAMED_QUERY='query($owner: String!, $number: Int!) { repositoryOwner(login: $owner) { ... on ProjectV2Owner { projectV2(number: $number)
  { number title closed owner { ... on Organization { login } ... on User { login } }
    field(name: "Status") { ... on ProjectV2SingleSelectField { options { name } } } } } } }'
# Open boards as `number<TAB>owner<TAB>title<TAB>status,options`. Title and owner reach lines the root pastes into a
# shell, so the title keeps plain characters only and an owner that is not a GitHub login shape drops the row.
BOARD_ROWS='[.. | objects | select(has("number") and has("title"))] | map(select(.closed != true)) | .[] |
  select(.owner.login | test("^[A-Za-z0-9-]+$")) |
  [.number, .owner.login, (.title | gsub("[^A-Za-z0-9 ._-]"; "_") | .[0:60]), ([.field.options[]?.name] | join(","))] | @tsv'

onboard_has() { grep -qE "^$1=" "$FILE" 2>/dev/null; }

# onboard_set KEY VALUE: queue KEY=VALUE unless the file already has KEY or VALUE is empty.
onboard_set() {
    [[ -n $2 ]] || return 0
    if onboard_has "$1"; then KEPT=$((KEPT + 1)); else LINES+=("$1=$2"); fi
}

# append_line FILE LINE: add LINE on its own line, even after a last line that has no newline.
append_line() {
    [[ ! -s $1 || $(tail -c 1 -- "$1" | od -An -c) == *'\n'* ]] || printf '\n' >>"$1"
    printf '%s\n' "$2" >>"$1"
}

# onboard_install DIR: the install command for the toolchain whose marker files sit in DIR, or nothing.
onboard_install() {
    local d=$1
    if [[ -f $d/package.json ]]; then
        if [[ -f $d/pnpm-lock.yaml ]]; then echo 'pnpm install --frozen-lockfile'
        elif [[ -f $d/yarn.lock ]]; then echo 'yarn install --frozen-lockfile'
        elif [[ -f $d/bun.lockb || -f $d/bun.lock ]]; then echo 'bun install'
        elif [[ -f $d/package-lock.json ]]; then echo 'npm ci'
        elif [[ $d == . ]]; then echo 'npm install'; fi   # no lockfile below the root: the root installs
    elif [[ -f $d/uv.lock ]]; then echo 'uv sync'
    elif [[ -f $d/poetry.lock ]]; then echo 'poetry install'
    elif [[ -f $d/Gemfile ]]; then echo 'bundle install'
    fi
}

# onboard_test DIR: the test command for DIR; a Makefile test target wins over the ecosystem's default.
onboard_test() {
    local d=$1 pm=npm
    if [[ -f $d/Makefile ]] && grep -qE '^test:' "$d/Makefile"; then echo 'make test'
    elif [[ -f $d/package.json ]]; then
        [[ ! -f $d/pnpm-lock.yaml ]] || pm=pnpm
        [[ ! -f $d/yarn.lock ]] || pm=yarn
        [[ ! -f $d/bun.lockb && ! -f $d/bun.lock ]] || pm=bun
        ! jq -e '.scripts.test' "$d/package.json" >/dev/null 2>&1 || echo "$pm test"
    elif [[ -f $d/pyproject.toml || -f $d/setup.cfg || -f $d/setup.py || -f $d/requirements.txt ]]; then
        if [[ -f $d/uv.lock ]]; then echo 'uv run pytest'
        elif [[ -f $d/poetry.lock ]]; then echo 'poetry run pytest'
        else echo 'python -m pytest'; fi
    elif [[ -f $d/Cargo.toml ]]; then echo 'cargo test'
    elif [[ -f $d/go.mod ]]; then echo 'go test ./...'
    elif [[ -f $d/Gemfile ]]; then [[ -d $d/spec ]] && echo 'bundle exec rspec' || echo 'bundle exec rake test'
    elif compgen -G "$d/*.sln" >/dev/null || compgen -G "$d/*.csproj" >/dev/null; then echo 'dotnet test'
    elif [[ -x $d/tests/run-tests.sh ]]; then echo 'tests/run-tests.sh'
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
    local dir name command install setup test installs=() found=0 taken=''
    setup=$(onboard_install .)
    test=$(onboard_test .)
    while IFS= read -r dir; do
        [[ -n $dir ]] || continue
        name=${dir^^}
        name=${name//[^A-Z0-9_]/_}
        case $name in SETUP | VERIFY | TEST | *_FIX) continue ;; esac
        command=$(onboard_test "$dir")
        [[ -n $command ]] || continue
        # api-v1 and api_v1 both normalise to API_V1: the first keeps the name, the second is named for the operator.
        if [[ ,$taken, == *",$name,"* ]]; then NOTES+=("suite-skipped=$dir (AGENT_CMD_$name is taken; add it by hand)"); continue; fi
        taken+=",$name"
        found=1
        # A directory's install matters only when a suite runs there: a tool's own package.json is not a suite.
        install=$(onboard_install "$dir")
        [[ -z $install ]] || installs+=("(cd $dir && $install)")
        # The command and its directory are one declaration: a kept `pytest api/tests` must not gain a directory.
        if onboard_has "AGENT_CMD_$name" || onboard_has "AGENT_RUNDIR_$name"; then KEPT=$((KEPT + 1)); continue; fi
        onboard_set "AGENT_CMD_$name" "$command"
        onboard_set "AGENT_RUNDIR_$name" "$dir"
    done < <(onboard_suite_dirs)
    # The root install first, then each suite's own: ak setup runs the one line before any suite.
    for command in "${installs[@]}"; do setup+="${setup:+ && }$command"; done
    onboard_set AGENT_CMD_SETUP "$setup"
    onboard_set AGENT_CMD_TEST "$test"
    [[ -n $test ]] || ((found)) || NOTES+=('commands=none; append AGENT_CMD_TEST=<the command CI runs> to .agent/config.env')
}

# onboard_board [NUMBER OWNER]: read the linked boards (or the named one), queue the owner and number of the one to use.
# Owner and number are one declaration: a file that already has either is not completed with a discovered half.
onboard_board() {
    local rows owner count fix
    if onboard_has AGENT_PROJECT_OWNER && onboard_has AGENT_PROJECT_NUMBER; then
        KEPT=$((KEPT + 2)); NOTES+=('board=kept (AGENT_PROJECT_OWNER and AGENT_PROJECT_NUMBER are already set)'); return 0
    elif onboard_has AGENT_PROJECT_OWNER || onboard_has AGENT_PROJECT_NUMBER; then
        KEPT=$((KEPT + 1)); NOTES+=("board=incomplete; $FILE has one of AGENT_PROJECT_OWNER/AGENT_PROJECT_NUMBER: set both or remove it"); return 0
    fi
    owner=$(slug); owner=${owner%%/*}
    if [[ -n ${1:-} ]]; then
        rows=$(gh api graphql -f "query=$NAMED_QUERY" -F "owner=${2:-$owner}" -F "number=$1" 2>&1)
    else
        rows=$(gh api graphql -f "query=$LINKED_QUERY" -F "owner=$owner" -F "name=$(slug | cut -d/ -f2)" 2>&1)
    fi || { NOTES+=("board=unavailable ($rows); fix: gh auth status"); return 0; }
    rows=$(jq -r "$BOARD_ROWS" <<<"$rows" 2>/dev/null) || { NOTES+=("board=unavailable (unreadable reply); fix: gh auth status"); return 0; }
    count=$(grep -c . <<<"$rows" || true)
    if ((count == 0)); then
        [[ -n ${1:-} ]] && fix="board=none; ${2:-$owner} has no open project $1" ||
            fix='board=none; ak plan reads AGENT_READY_LABEL=<label> instead, or name one: ak onboard --project N --owner O'
        NOTES+=("$fix")
    elif ((count > 1)); then
        # The title sits behind a #: a pasted line keeps only the flags, so a title that looks like flags changes nothing.
        NOTES+=('board=choose' "$(head -n 5 <<<"$rows" | awk -F'\t' '{ print "  --project " $1 " --owner " $2 "  # " $3 }')" \
            'fix: ak onboard <one line above>')
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
    grep -qxF '/.agent/' "$exclude" 2>/dev/null || append_line "$exclude" '/.agent/'
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
    [[ -z $project$owner || $project =~ ^[0-9]+$ ]] || usage_die 'usage: ak onboard [--project N [--owner O]]'
    cd -- "$(main_root)" || exit 1
    FILE=.agent/config.env KEPT=0 LINES=() NOTES=()
    [[ ! -L .agent && ! -L $FILE ]] || die "$FILE is behind a symlink, which onboard will not write through" "rm $FILE"
    onboard_set AGENT_REPO_SLUG "$(slug)"
    base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    [[ -n $base ]] || base=$(gh api "repos/$(slug)" --jq .default_branch 2>/dev/null || true)
    # A failed lookup writes nothing: a guessed `main` would survive every later run on a `master` repository.
    [[ -n $base ]] || NOTES+=('base=unknown; fix: git remote set-head origin -a')
    onboard_set AGENT_BASE_BRANCH "${base#origin/}"
    onboard_board "$project" "$owner"
    onboard_toolchain
    mkdir -p -- .agent
    [[ -f $FILE ]] || printf '# ak reads these KEY=value lines; edit freely. ak onboard adds missing keys and keeps every line here.\n' >"$FILE"
    for line in "${LINES[@]}"; do append_line "$FILE" "$line"; done
    onboard_exclude
    printf 'wrote=%s keys=%d kept=%d\n' "$FILE" "${#LINES[@]}" "$KEPT"
    shown=${#LINES[@]}; ((shown <= 14)) || shown=12
    for line in "${LINES[@]:0:$shown}"; do printf '%s\n' "$line"; done
    ((shown == ${#LINES[@]})) || printf '(+%d more in %s)\n' $((${#LINES[@]} - shown)) "$FILE"
    ((${#NOTES[@]} == 0)) || printf '%s\n' "${NOTES[@]}"
    if grep -qE '^AGENT_CMD_SETUP=.' "$FILE"; then printf 'next=ak setup && ak verify --full\n'; else printf 'next=ak verify --full\n'; fi
}
