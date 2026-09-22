#!/usr/bin/env bash
# finding-ledger.sh — record confirmed adversarial-review dispositions.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
readonly RECEIPT_MARKER='<!-- adversarial-review:spent -->'
readonly DOC_MARKER='<!-- review-remote-pr:agent-doc -->'
readonly SHA_RE='^[[:xdigit:]]{7,64}(,[[:xdigit:]]{7,64})*$'
readonly ORDER_RC=13
readonly FINDING_SLUG_JQ='ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-") | if . == "" then "finding" else . end'
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR

RUN_DIR=${RUN_DIR:-}
TITLE=''
VERDICT=''
SEVERITY=''
SHA=''
RATIONALE=''
DETAIL_KIND=''
EVIDENCE_FILE=''
REPO_ROOT=''
HEAD=''

usage() {
    cat <<EOF
Usage: $PROGNAME add --title TITLE --severity P1|P2 --verdict fixed --sha SHA
       $PROGNAME add --title TITLE --severity P1|P2 --verdict declined --rationale RATIONALE
       $PROGNAME add --title TITLE --severity P1|P2 --verdict open --rationale NEXT_REPAIR
       $PROGNAME status|validate --file FILE [--repo-root DIR --head SHA]
       $PROGNAME ids --file FILE    (prints ID<TAB>TITLE; review-ledger.sh cover --reason fix:ID names one)
       $PROGNAME evidence --title T --path P --log LOG --repo-root DIR --repair-sha SHA [--head SHA]
                 (prints fixed-verdict evidence JSON; LOG must be a green unfocused agent-run.sh --cmd test
                 log; head defaults to DIR's HEAD; SHA is the commit that changed P)

Terminal evidence: --evidence FILE --repo-root DIR --head SHA. Evidence JSON
binds finding (title) to decision rejected|accepted-risk and rationale, or to
repairSha, head, path, command, status=passed, log and logSha256. Legacy adds
remain readable but have unknown remediation semantics. Repeated titles update
one finding, retaining disposition history; open findings require terminal evidence.

Appends one validated JSON record to \$RUN_DIR/findings.ndjson. RUN_DIR must
be the private run directory containing a completed adversarial.result.json.
EOF
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

die_evidence() {
    printf '%s: %s; evidence unavailable\n' "$PROGNAME" "$1" >&2
    exit 1
}

die_order() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit "$ORDER_RC"
}

require_value() {
    [[ -n ${2-} ]] || die_usage "$1 requires a value"
}

parse_add_args() {
    shift
    while (($#)); do
        case $1 in
            --evidence) require_value "$1" "${2-}"; EVIDENCE_FILE=$2; shift 2 ;;
            --repo-root) require_value "$1" "${2-}"; REPO_ROOT=$2; shift 2 ;;
            --head) require_value "$1" "${2-}"; HEAD=$2; shift 2 ;;
            --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
            --title)
                require_value "$1" "${2-}"
                [[ -z $TITLE ]] || die_usage '--title may be given only once'
                TITLE=$2
                shift 2
                ;;
            --title=*)
                [[ -n ${1#*=} ]] || die_usage '--title requires a value'
                [[ -z $TITLE ]] || die_usage '--title may be given only once'
                TITLE=${1#*=}
                shift
                ;;
            --verdict)
                require_value "$1" "${2-}"
                [[ -z $VERDICT ]] || die_usage '--verdict may be given only once'
                VERDICT=$2
                shift 2
                ;;
            --verdict=*)
                [[ -n ${1#*=} ]] || die_usage '--verdict requires a value'
                [[ -z $VERDICT ]] || die_usage '--verdict may be given only once'
                VERDICT=${1#*=}
                shift
                ;;
            --severity)
                [[ ${2-} ]] || die_usage '--severity requires a value'
                SEVERITY=$2; shift 2 ;;
            --severity=*)
                [[ -n ${1#*=} ]] || die_usage '--severity requires a value'
                SEVERITY=${1#*=}; shift ;;
            --sha)
                require_value "$1" "${2-}"
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=sha
                SHA=$2
                shift 2
                ;;
            --sha=*)
                [[ -n ${1#*=} ]] || die_usage '--sha requires a value'
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=sha
                SHA=${1#*=}
                shift
                ;;
            --rationale)
                require_value "$1" "${2-}"
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=rationale
                RATIONALE=$2
                shift 2
                ;;
            --rationale=*)
                [[ -n ${1#*=} ]] || die_usage '--rationale requires a value'
                [[ -z $DETAIL_KIND ]] || die_usage 'exactly one of --sha or --rationale is required'
                DETAIL_KIND=rationale
                RATIONALE=${1#*=}
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
    done
}

reject_unsafe_text() {
    local flag=$1 value=$2
    [[ -n $value ]] || die_usage "$flag requires a non-empty value"
    [[ $value != *$'\n'* && $value != *$'\r'* ]] ||
        die_usage "$flag must not contain a line break"
    [[ $value != *"$RECEIPT_MARKER"* ]] ||
        die_usage "$flag must not contain the receipt marker $RECEIPT_MARKER"
    [[ $value != *"$DOC_MARKER"* ]] ||
        die_usage "$flag must not contain the agent-doc marker $DOC_MARKER"
}

run_dir_mode() {
    local mode
    if mode=$(stat -c %a -- "$RUN_DIR" 2>/dev/null) &&
        [[ $mode =~ ^[0-7]+$ ]]; then
        printf '%s\n' "$mode"
        return 0
    fi
    if mode=$(stat -f %Lp -- "$RUN_DIR" 2>/dev/null) &&
        [[ $mode =~ ^[0-7]+$ ]]; then
        printf '%s\n' "$mode"
        return 0
    fi
    return 1
}

validate_run_dir() {
    [[ -n $RUN_DIR ]] || die_usage 'RUN_DIR must be set'
    [[ -d $RUN_DIR && ! -L $RUN_DIR && -O $RUN_DIR ]] ||
        die_evidence "RUN_DIR is not an owned directory: $RUN_DIR"
    local mode
    mode=$(run_dir_mode) || die_evidence "could not inspect RUN_DIR mode: $RUN_DIR"
    (( (8#$mode & 0777) == 0700 )) ||
        die_evidence "RUN_DIR must have mode 0700: $RUN_DIR"
}

validate_completed_review() {
    local result=$RUN_DIR/adversarial.result.json
    [[ -f $result && ! -L $result && -O $result ]] ||
        die_order "completed adversarial review result is required: $result"
    command -v jq >/dev/null 2>&1 || die_evidence 'jq is not installed'
    # Mirrors valid_completed_result in adversarial-run.sh, the only producer of
    # this document. A looser copy here would accept results the runner can never
    # publish -- notably verdict "findings" with an empty findings array -- while
    # claiming the file is "a completed validated result".
    jq -s -e '
        length == 1 and
        (.[0] |
            type == "object" and .status == "completed" and
            (.exitCode | type) == "number" and .exitCode == 0 and
            (.requestedModel | type) == "string" and (.transcript | type) == "string" and
            (.verdict | type) == "object" and
            ((.verdict | keys) - ["verdict", "findings"] | length) == 0 and
            (.verdict.verdict == "findings" or .verdict.verdict == "no_findings") and
            (.verdict.findings | type) == "array" and
            (if .verdict.verdict == "no_findings" then (.verdict.findings | length) == 0
             else (.verdict.findings | length) > 0 end) and
            all(.verdict.findings[];
              (type == "object") and
              ((keys - ["priority", "location", "failureScenario", "smallestFix"]) | length == 0) and
              (.priority == "P1" or .priority == "P2") and
              (.location | type) == "string" and
              (.failureScenario | type) == "string" and
              (.smallestFix | type) == "string"))
    ' "$result" >/dev/null 2>&1 ||
        die_order "adversarial review result is not a completed validated result: $result"
}

validate_existing_ledger() {
    local ledger=${1:-$RUN_DIR/findings.ndjson}
    [[ ! -L $ledger ]] || die_evidence "findings ledger is a symlink: $ledger"
    [[ ! -e $ledger ]] && return 0
    [[ -f $ledger && -O $ledger && -r $ledger ]] ||
        die_evidence "findings ledger is not an owned regular file: $ledger"
    command -v jq >/dev/null 2>&1 || die_evidence 'jq is not installed'
    jq -s -e --arg receipt "$RECEIPT_MARKER" --arg doc "$DOC_MARKER" \
        --arg sha_re "$SHA_RE" '
        all(.[];
          type == "object" and
          ((keys - ["title", "severity", "verdict", "sha", "rationale", "schemaVersion", "evidence", "history"]) | length == 0) and
          (.severity == "P1" or .severity == "P2") and
          (.title | type == "string" and length > 0) and
          (.title | test("[\\r\\n]") | not) and
          (.title | contains($receipt) | not) and
          (.title | contains($doc) | not) and
          ((.verdict == "fixed" and has("sha") and (has("rationale") | not) and
              (.sha | type == "string" and test($sha_re))) or
           ((.verdict == "declined" or (.verdict == "open" and .schemaVersion == 2)) and has("rationale") and (has("sha") | not) and
              (.rationale | type == "string" and length > 0) and
              (.rationale | test("[\\r\\n]") | not) and
              (.rationale | contains($receipt) | not) and
              (.rationale | contains($doc) | not))) and
          ((has("schemaVersion") | not) or .schemaVersion == 2) and
          ((has("history") | not) or (.history | type == "array")) and
          (if .schemaVersion == 2 and .verdict != "open" then
             . as $f | (.evidence | type == "object") and .evidence.finding == .title and
             (if .verdict == "fixed" then
                .evidence.repairSha == .sha and .evidence.status == "passed" and
                all([.evidence.head,.evidence.path,.evidence.command,.evidence.log,.evidence.logSha256][];
                    type == "string" and length > 0)
              else (.evidence.decision == "rejected" or
                    (.evidence.decision == "accepted-risk" and (.evidence.authorization | type == "string" and length > 0))) and
                   .evidence.rationale == $f.rationale end)
           else true end)
        )
    ' "$ledger" >/dev/null 2>&1 ||
        die_evidence "findings ledger is invalid: $ledger"
}

validate_add_args() {
    validate_run_dir
    validate_completed_review
    [[ -n $TITLE ]] || die_usage '--title is required'
    [[ $VERDICT == fixed || $VERDICT == declined || $VERDICT == open ]] ||
        die_usage '--verdict must be fixed, declined, or open'
    # The receipt reports separate P1 and P2 counts. Without a severity on each
    # record those counts are unverifiable caller assertions: one finding equally
    # supports P1=1,P2=0 or P1=0,P2=1.
    [[ $SEVERITY == P1 || $SEVERITY == P2 ]] ||
        die_usage '--severity must be P1 or P2'
    [[ $DETAIL_KIND == sha || $DETAIL_KIND == rationale ]] ||
        die_usage 'exactly one of --sha or --rationale is required'
    reject_unsafe_text '--title' "$TITLE"
    case $VERDICT:$DETAIL_KIND in
        fixed:sha)
            [[ $SHA =~ $SHA_RE ]] || die_usage '--sha (SHA) must be hexadecimal (or comma-separated hexadecimal)'
            ;;
        declined:rationale|open:rationale)
            reject_unsafe_text '--rationale' "$RATIONALE"
            ;;
        fixed:rationale)
            die_usage 'fixed findings require --sha'
            ;;
        declined:sha)
            die_usage 'declined findings require --rationale'
            ;;
        open:sha) die_usage 'open findings require --rationale naming the next repair' ;;
    esac
}

# Prints TITLE's ID in the staged ledger, refusing a new title whose ID another
# title already holds (the staged file is removed on refusal).
staged_finding_id() {
    local staged=$1 prior=$2 base_id finding_id
    if ! base_id=$(base_finding_id "$TITLE") || ! finding_id=$(ledger_id_rows "$staged" | id_for_title "$TITLE"); then
        rm -f -- "$staged"
        die_evidence 'could not derive finding IDs'
    fi
    if [[ $prior == null && $finding_id != "$base_id" ]]; then
        rm -f -- "$staged"
        die_usage "--title maps to finding ID $base_id, which another title already uses; choose a distinguishable title"
    fi
    printf '%s\n' "$finding_id"
}

append_record() {
    local ledger=$RUN_DIR/findings.ndjson entry
    if [[ $VERDICT == fixed ]]; then
        entry=$(jq -cn --arg title "$TITLE" --arg sha "$SHA" --arg severity "$SEVERITY" \
            '{title:$title,severity:$severity,verdict:"fixed",sha:$sha}')
    else
        entry=$(jq -cn --arg title "$TITLE" --arg rationale "$RATIONALE" --arg severity "$SEVERITY" --arg verdict "$VERDICT" \
            '{title:$title,severity:$severity,verdict:$verdict,rationale:$rationale}')
    fi
    local prior='null' staged
    if [[ -f $ledger ]]; then
        prior=$(jq -cs --arg title "$TITLE" '[.[] | select(.title == $title)] | last // null' "$ledger")
    fi
    if [[ $VERDICT != open && -z $EVIDENCE_FILE ]] &&
        jq -e '.schemaVersion == 2' <<<"$prior" >/dev/null; then
        die_usage 'open findings require explicit terminal adjudication or repair evidence'
    fi
    if [[ $VERDICT == open ]]; then
        entry=$(jq -c '.schemaVersion=2' <<<"$entry")
    elif [[ -n $EVIDENCE_FILE ]]; then
        [[ -f $EVIDENCE_FILE && ! -L $EVIDENCE_FILE && -O $EVIDENCE_FILE ]] || die_evidence 'invalid evidence file'
        entry=$(jq -c --slurpfile evidence "$EVIDENCE_FILE" \
            'if ($evidence|length)!=1 then error("one evidence object required") else .schemaVersion=2 | .evidence=$evidence[0] end' <<<"$entry") || die_evidence 'invalid evidence JSON'
    fi
    staged=$(mktemp "$RUN_DIR/findings.XXXXXXXX")
    printf '%s\n' "$entry" >"$staged"
    validate_existing_ledger "$staged"
    validate_repairs "$staged" "$REPO_ROOT" "$HEAD"
    if [[ -f $ledger ]]; then
        jq -cs --argjson entry "$entry" '
            map(select(.title == $entry.title)) as $old |
            map(select(.title != $entry.title)) +
            [$entry + (if ($old|length)==0 then {} else
             {history:(($old[-1].history // []) + [($old[-1] | del(.history))])} end)] | .[]' "$ledger" >"$staged"
    fi
    local finding_id
    finding_id=$(staged_finding_id "$staged" "$prior") || exit $?
    mv -- "$staged" "$ledger" || die_evidence "could not update findings ledger: $ledger"
    chmod 600 -- "$ledger" || die_evidence "could not secure findings ledger: $ledger"
    printf 'added finding verdict=%s id=%s title=%s\n' "$VERDICT" "$finding_id" "$TITLE"
}

verification_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1"
    else
        return 1
    fi
}

# Verify repair evidence at every trust boundary, including publication and
# readiness. A hexadecimal string alone never proves a repair was committed.
validate_repairs() {
    local file=$1 root=$2 head=$3 row sha tested path log digest actual command
    while IFS= read -r row; do
        [[ -n $root && -n $head ]] || die_evidence 'repair verification requires --repo-root and --head'
        sha=$(jq -r .sha <<<"$row")
        tested=$(jq -r .evidence.head <<<"$row")
        path=$(jq -r .evidence.path <<<"$row")
        log=$(jq -r .evidence.log <<<"$row")
        digest=$(jq -r .evidence.logSha256 <<<"$row")
        command=$(jq -r .evidence.command <<<"$row")
        [[ $head =~ ^[0-9a-f]{40}$ && $sha =~ ^[0-9a-f]{40}$ && $tested =~ ^[0-9a-f]{40}$ && $digest =~ ^[0-9a-f]{64}$ ]] ||
            die_evidence 'repair evidence requires full commit and log hashes'
        if ! git -C "$root" merge-base --is-ancestor "$sha" "$tested" 2>/dev/null ||
            ! git -C "$root" merge-base --is-ancestor "$tested" "$head" 2>/dev/null; then
            die_evidence "repair or verification head is unreachable: $sha"
        fi
        [[ $path != /* && $path != -* && $path != *'..'* ]] || die_evidence 'repair path must be repository relative'
        git -C "$root" diff-tree --root --no-commit-id --name-only -r "$sha" -- "$path" |
            grep -Fxq -- "$path" || die_evidence "repair commit does not change finding path: $path"
        git -C "$root" diff --quiet "$tested" "$head" -- "$path" ||
            die_evidence "repair verification is stale for changed path: $path"
        [[ -f $log && ! -L $log && -O $log ]] || die_evidence 'verification log is unavailable'
        actual=$(verification_digest "$log") || die_evidence 'verification log digest unavailable (requires sha256sum or shasum)'
        actual=${actual%% *}
        [[ $actual == "$digest" ]] || die_evidence 'verification log digest mismatch'
        grep -Fxq -- "=== agent-run $command" "$log" || die_evidence 'verification command does not match its log'
        [[ $(tail -n 1 -- "$log") == '=== agent-run exited rc=0 '* ]] ||
            die_evidence 'verification log has no final successful agent-run result'
    done < <(jq -cs '.[] | select(.schemaVersion == 2 and .verdict == "fixed")' "$file")
}

title_hash8() {
    local digest
    digest=$(printf '%s' "$1" | verification_digest -) || return 1
    printf '%s\n' "${digest:0:8}"
}

# A finding's ID is its ASCII slug. A title with any non-ASCII character also
# carries a title hash, because the slug drops those characters entirely.
base_finding_id() {
    local slug hash
    slug=$(jq -rn --arg title "$1" "\$title | $FINDING_SLUG_JQ") || return 1
    if LC_ALL=C grep -q '[^ -~]' <<<"$1"; then
        hash=$(title_hash8 "$1") || return 1
        slug=$slug-$hash
    fi
    printf '%s\n' "$slug"
}

# Prints ID<TAB>TITLE once per distinct title. add refuses a new title whose ID
# another title holds; titles that already share one (a ledger written before
# IDs existed) each get the title hash appended, so no ID ever names two findings.
ledger_id_rows() {
    local title base hash
    while IFS= read -r title; do
        base=$(base_finding_id "$title") && hash=$(title_hash8 "$title") || return 1
        printf '%s\t%s\t%s\n' "$base" "$hash" "$title"
    done < <(jq -rs 'reduce .[].title as $t ([]; if index([$t]) then . else . + [$t] end) | .[]' "$1") |
        jq -Rrn '[inputs | split("\t") | {id: .[0], hash: .[1], title: (.[2:] | join("\t"))}] as $rows |
            $rows[] | . as $row | ([$rows[] | select(.id == $row.id)] | length) as $n |
            "\(if $n > 1 then "\($row.id)-\($row.hash)" else $row.id end)\t\($row.title)"'
}

id_for_title() {
    local line
    while IFS= read -r line; do
        [[ ${line#*$'\t'} != "$1" ]] || { printf '%s\n' "${line%%$'\t'*}"; return 0; }
    done
    return 1
}

cmd_ids() {
    local file=''
    shift
    while (($#)); do
        case $1 in
            --file) require_value "$1" "${2-}"; file=$2; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $file ]] || die_usage 'ids requires --file FILE'
    [[ -f $file ]] || die_evidence 'findings file is missing'
    validate_existing_ledger "$file"
    ledger_id_rows "$file" || die_evidence 'could not derive finding IDs'
}

resolve_commit() {
    git -C "$1" rev-parse --verify -q "$2^{commit}" 2>/dev/null || die_evidence "not a commit in $1: $2"
}

# Emit fixed-verdict evidence for one finding, refusing anything add would
# later reject: the log must be the green, unfocused declared test run, and the
# named repair commit must change the finding's path.
cmd_evidence() {
    local title='' path='' log='' root='' repair_sha='' head='' declared command digest row
    shift
    while (($#)); do
        case $1 in
            --title) require_value "$1" "${2-}"; title=$2; shift 2 ;;
            --path) require_value "$1" "${2-}"; path=$2; shift 2 ;;
            --log) require_value "$1" "${2-}"; log=$2; shift 2 ;;
            --repo-root) require_value "$1" "${2-}"; root=$2; shift 2 ;;
            --repair-sha) require_value "$1" "${2-}"; repair_sha=$2; shift 2 ;;
            --head) require_value "$1" "${2-}"; head=$2; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -n $title && -n $path && -n $log && -n $root && -n $repair_sha ]] ||
        die_usage 'evidence requires --title, --path, --log, --repo-root and --repair-sha'
    reject_unsafe_text '--title' "$title"
    [[ $path != /* && $path != -* && $path != *'..'* ]] || die_evidence 'repair path must be repository relative'
    [[ -f $log && ! -L $log ]] || die_evidence "verification log is unavailable: $log"
    log=$(cd -- "$(dirname -- "$log")" && pwd -P)/${log##*/}
    head=$(resolve_commit "$root" "${head:-HEAD}") && repair_sha=$(resolve_commit "$root" "$repair_sha") || exit 1
    command=$(sed -n '1s/^=== agent-run //p' "$log")
    declared=$("$SCRIPT_DIR/../../.shared/scripts/repo-config.sh" --repo-root "$root" \
        --get-argv AGENT_CMD_TEST | tr '\0' ' ') || die_evidence 'the repository declares no AGENT_CMD_TEST'
    declared=${declared% }
    [[ -n $declared ]] || die_evidence 'the repository declares no AGENT_CMD_TEST'
    [[ -n $command && $command == "$declared" ]] ||
        die_evidence "log is not the unfocused declared test run (log: ${command:-<none>}; declared: $declared); run agent-run.sh --cmd test without --only"
    digest=$(verification_digest "$log") || die_evidence 'verification log digest unavailable (requires sha256sum or shasum)'
    row=$(jq -cn --arg finding "$title" --arg sha "$repair_sha" --arg head "$head" \
        --arg path "$path" --arg command "$command" --arg log "$log" --arg digest "${digest%% *}" \
        '{schemaVersion:2, verdict:"fixed", sha:$sha, evidence:{finding:$finding, repairSha:$sha,
          head:$head, path:$path, command:$command, status:"passed", log:$log, logSha256:$digest}}')
    ( validate_repairs <(printf '%s\n' "$row") "$root" "$head" ) || exit 1
    jq '.evidence' <<<"$row"
}

cmd_status() {
    local file='' mode=$1 root='' head=''
    shift
    while (($#)); do
        case $1 in
            --file) require_value "$1" "${2-}"; file=$2; shift 2 ;;
            --repo-root) (($# >= 2)) || die_usage '--repo-root requires a value'; root=$2; shift 2 ;;
            --head) (($# >= 2)) || die_usage '--head requires a value'; head=$2; shift 2 ;;
            *) die_usage "unknown argument: $1" ;;
        esac
    done
    [[ -f $file ]] || die_evidence 'findings file is missing'
    validate_existing_ledger "$file"
    validate_repairs "$file" "$root" "$head"
    [[ $mode != validate ]] || return 0
    jq -cs '{execution:"performed", adjudication:(if any(.[];.verdict=="open") then "confirmed-open" else "recorded" end),
        remediation:(if any(.[];.verdict=="open") then "incomplete" elif any(.[];.schemaVersion!=2) then "unknown" else "complete" end),
        unresolved:map(select(.verdict=="open" or .schemaVersion!=2)|{title,nextAction:(if .verdict=="open" then .rationale else "validate legacy repair or adjudication evidence" end)})}' "$file"
}

main() {
    (($#)) || die_usage 'a subcommand is required: add'
    case $1 in
        ids) cmd_ids "$@" ;;
        evidence) cmd_evidence "$@" ;;
        status|validate) cmd_status "$@" ;;
        add)
            parse_add_args "$@"
            validate_add_args
            validate_existing_ledger
            append_record
            ;;
        -h|--help)
            usage
            ;;
        *)
            die_usage "unknown subcommand: $1 (expected add, evidence, ids, status, or validate)"
            ;;
    esac
}

main "$@"
