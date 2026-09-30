# shellcheck shell=bash
# REPO, V2_TESTS and WORK come from lib.sh.
# shellcheck disable=SC2153
# Shared by the plan and collect suites: an ak copy with a worker template, a board, and issues.

# ak_with_template: copy v2 to $WORK/v2 so a template exists even before the real one lands.
ak_with_template() {
    cp -R "$REPO/v2" "$WORK/v2"
    mkdir -p "$WORK/v2/templates"
    [[ -f $WORK/v2/templates/issue-worker.md ]] || cp "$V2_TESTS/fixtures/issue-worker.md" "$WORK/v2/templates/"
    export AK="$WORK/v2/bin/ak"
}

# board_repo: the fixture repository with more files and a board config. Echoes the path.
board_repo() {
    local repo
    repo=$(fixture_repo)
    (
        cd "$repo" || exit 1
        mkdir -p lib .github/workflows
        printf 'x\n' >src/b.txt
        printf 'x\n' >lib/core.sh
        printf 'x\n' >.github/workflows/ci.yml
        printf 'x\n' >AGENTS.md
        git add . && git commit -q -m more && git push -q origin main
        printf 'AGENT_PROJECT_OWNER=acme\nAGENT_PROJECT_NUMBER=5\nAGENT_PROTECTED_PATHS=.github/**\n' >>.agent/config.env
    )
    printf '%s\n' "$repo"
}

# board_item N STATUS [LABELS_JSON]
board_item() {
    printf '{"id":"I_%s","content":{"type":"Issue","number":%s,"repository":"acme/widget","title":"t%s"},"status":"%s","labels":%s}' \
        "$1" "$1" "$1" "$2" "${3:-[]}"
}

# issue_route N BODY: the REST issue read.
issue_route() {
    route "api repos/acme/widget/issues/$1" "$(jq -nc --argjson n "$1" --arg b "$2" \
        '{number:$n,title:"Title \($n)",state:"open",body:$b,labels:[]}')"
}

# default_routes: everything the board and REST fallbacks need; call after specific routes.
default_routes() {
    route 'api repos/acme/widget/issues/*/comments*' '[{"user":{"login":"bob"},"body":"please hurry"}]'
    route 'api repos/acme/widget/issues/*/dependencies/blocked_by*' '[]'
    route 'api repos/acme/widget/pulls*' '[]'
    route 'project field-list*' '{"fields":[{"id":"F_S","name":"Status","options":[{"id":"O_P","name":"In progress"}]}]}'
    route 'project view*' '{"id":"PVT_5"}'
    route 'project item-edit*' ''
}

# standard_board: the board most cases use.
standard_board() {
    route 'project item-list 5 --owner acme*' "{\"items\":[$(board_item 671 Ready),$(board_item 69 Ready '["tier:human-only"]'),$(board_item 700 Backlog),$(board_item 680 Ready),$(board_item 690 Ready),$(board_item 691 Ready),$(board_item 692 Ready),$(board_item 693 Ready),$(board_item 694 Done)]}"
    # shellcheck disable=SC2016
    issue_route 671 'Fix `src/a.txt` and see https://example.com/x/y.md and AGENTS.md {{BRANCH}}'
    issue_route 680 'Also touches src/a.txt.'
    issue_route 690 'Touches src/b.txt'
    issue_route 691 'Edit .github/workflows/ci.yml'
    issue_route 692 'Anything'
    issue_route 693 'Add lib/new.sh next to core.sh'
    issue_route 700 'Backlog work in src/b.txt'
    route 'api repos/acme/widget/issues/690/dependencies/blocked_by*' '[{"number":1,"state":"open"}]'
    route 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-692*' '[{"number":9}]'
    default_routes
}
