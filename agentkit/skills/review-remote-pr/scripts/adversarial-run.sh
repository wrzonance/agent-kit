#!/usr/bin/env bash
# adversarial-run.sh — one blocking, consent-gated adversarial review launch.
# The provider helpers own isolation and model-specific stream validation. This
# wrapper owns diff construction, provider selection, consent, one launch, and
# the neutral receipt metadata line.
set -euo pipefail
umask 077

readonly PROGNAME=${0##*/}
SCRIPT_DIR=${BASH_SOURCE[0]%/*}
[[ $SCRIPT_DIR != "${BASH_SOURCE[0]}" ]] || SCRIPT_DIR=.
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/private-dir.sh"
# shellcheck disable=SC1091  # plugin-relative path is resolved at runtime
source "$SCRIPT_DIR/../../.shared/scripts/lib/canonical-diff.sh"

readonly REPO_CONFIG_SH="$SCRIPT_DIR/../../.shared/scripts/repo-config.sh"

PR=''
REPO=''
RUN_DIR=''
PEER_CLI_ABSENT=0
PAYLOAD=''
REAFFIRM_IF_COVERED=0
LEDGER_COMMENTS=''
HARNESS_NAME=''
RUNNING_PROVIDER=''
PEER_CLI_NAME=''
CONTRACT_ROOT=''
BASE_CONFIG_FILE=''
BASE_REF=''
PROVIDER=''
MODEL=''
EFFORT=''
MODE=''
HELPER=''
TRANSCRIPT_NAME=''

usage() {
    cat <<EOF
Usage: $PROGNAME --pr N --repo OWNER/REPO --run-dir DIR [--peer-cli-absent]
                 [--reaffirm-if-covered --comments FILE]

Builds DIR/adversarial.diff, runs exactly one consent-gated blind reviewer, and
publishes DIR/adversarial.result.json. On success stdout is one receipt-shaped
line containing provider, model, effort, mode, P1, and P2.

Reviewer selection comes from the running harness and peer-cli facts in the
untracked environment contract at the repository root. The optional
--peer-cli-absent flag must agree with a peer-cli= ... absent contract fact.

This is the real PR-diff review path. Capability probes use the provider helper
with --mode probe --no-payload, send only a synthetic snippet, and never spend
the one-review-per-PR receipt budget.

The consent record is always DIR/state/cross-provider-consent. There is no
caller-supplied consent flag.

--reaffirm-if-covered --comments FILE (issue #477): before launching a
reviewer, consults the sibling review-ledger.sh's status for this PR's
already-fetched comments artifact. A covered-head or covered-diff verdict
(the exact tree, or a base-merge-only advance of a tree, already reviewed)
appends a "reaffirmed_from" ledger entry and exits 0 WITHOUT spawning a
reviewer -- the DIR/adversarial.result.json this run would otherwise have
produced is never written. Any other verdict (stale, absent, or a blocked/
malformed ledger) runs the review exactly as it does without this flag.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

warn() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
}

die_usage() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    usage >&2
    exit 2
}

require_value() {
    [[ -n ${2:-} ]] || die_usage "$1 requires a value"
}

parse_args() {
    while (($#)); do
        case $1 in
            --pr) require_value "$1" "${2:-}"; PR=$2; shift 2 ;;
            --pr=*) PR=${1#*=}; shift ;;
            --repo) require_value "$1" "${2:-}"; REPO=$2; shift 2 ;;
            --repo=*) REPO=${1#*=}; shift ;;
            --run-dir) require_value "$1" "${2:-}"; RUN_DIR=$2; shift 2 ;;
            --run-dir=*) RUN_DIR=${1#*=}; shift ;;
            --peer-cli-absent) PEER_CLI_ABSENT=1; shift ;;
            --reaffirm-if-covered) REAFFIRM_IF_COVERED=1; shift ;;
            --comments) require_value "$1" "${2:-}"; LEDGER_COMMENTS=$2; shift 2 ;;
            --comments=*) LEDGER_COMMENTS=${1#*=}; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die_usage "unknown option: $1" ;;
        esac
    done
}

provider_for_cli() {
    case $1 in
        codex) printf '%s' openai ;;
        claude) printf '%s' anthropic ;;
        *) return 1 ;;
    esac
}

load_environment_contract() {
    local contract_root contract peer_line tracked_rc=0
    if ! contract_root=$(git rev-parse --show-toplevel 2>/dev/null); then
        die 'could not resolve the repository root for the environment contract'
    fi
    CONTRACT_ROOT=$contract_root
    contract="$contract_root/.agent/env-contract.txt"
    [[ ! -L $contract_root/.agent ]] ||
        die "environment contract directory is a symlink: $contract_root/.agent"
    [[ -r $contract && -f $contract && ! -L $contract && -O $contract ]] ||
        die "environment contract is not a self-owned regular file: $contract"
    git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt \
        >/dev/null 2>&1 || tracked_rc=$?
    case $tracked_rc in
        0) die "environment contract is tracked: $contract" ;;
        1) : ;;
        *) die "could not prove environment contract provenance: $contract" ;;
    esac

    HARNESS_NAME=$(sed -n 's/^harness= name=\([^[:space:]]*\).*/\1/p' "$contract" | head -n 1)
    case $HARNESS_NAME in
        codex|claude) ;;
        '') die "environment contract harness identity is missing: $contract" ;;
        *) die "unsupported harness in environment contract: $HARNESS_NAME" ;;
    esac
    RUNNING_PROVIDER=$(provider_for_cli "$HARNESS_NAME") ||
        die "could not map harness to a provider: $HARNESS_NAME"

    peer_line=$(sed -n 's/^peer-cli= //p' "$contract" | head -n 1)
    PEER_CLI_NAME=${peer_line%% *}
    case $PEER_CLI_NAME in
        codex|claude) ;;
        '') die "environment contract peer-cli identity is missing: $contract" ;;
        *) die "unsupported peer CLI in environment contract: $PEER_CLI_NAME" ;;
    esac
    case $peer_line in
        "$PEER_CLI_NAME absent"|"$PEER_CLI_NAME absent "?*)
            PEER_CLI_ABSENT=1
            ;;
        "$PEER_CLI_NAME present path="?*)
            if ((PEER_CLI_ABSENT)); then
                die '--peer-cli-absent conflicts with a present peer-cli contract fact'
            fi
            PEER_CLI_ABSENT=0
            ;;
        *)
            die "invalid peer-cli fact in environment contract: $peer_line"
            ;;
    esac
}

# Best-effort read of one declared config key from CONFIG_FILE (empty means
# "no trusted source available for this call" -- always resolves to "not
# declared", never the working tree). Absent, unreadable, or resolver-rejected
# values fall through silently -- the caller decides what "not declared"
# means, matching every other repo-config.sh consumer in this codebase (e.g.
# spawn-contract.md's worker_config_value).
#
# repo-config.sh exits 0 with empty output for --get on ANY key when its
# config file does not exist at all (it only exits 1 for a key that is
# genuinely absent from an existing file) -- so success alone does not mean
# "declared". None of these keys validate to an empty string, so requiring
# non-empty output here is exact, not a heuristic.
resolve_config_value() {
    local key=$1 config_file=$2 value
    [[ -n $config_file && -x $REPO_CONFIG_SH ]] || return 1
    value=$("$REPO_CONFIG_SH" --repo-root "$CONTRACT_ROOT" --config-file "$config_file" \
        --get "$key" 2>/dev/null) || return 1
    [[ -n $value ]] || return 1
    printf '%s' "$value"
}

# select_reviewer CONFIG_FILE -- CONFIG_FILE is the ONLY source ever consulted
# for AGENT_ADVERSARIAL_* declarations; pass '' for the pinned-defaults-only
# selection. The candidate PR's own working-tree checkout must never be that
# source: a PR under review can edit .agent/config.env in its own diff, and a
# reviewer that reads its declarations from the tree being reviewed lets the
# candidate steer the very review meant to scrutinize it (the PR's effort=low
# or a same-harness reviewer declaration would go unnoticed). The one caller
# that may pass a real path (main, below) resolves it from the PR's BASE
# revision instead, and only when the reviewed diff itself does not touch
# that file.
select_reviewer() {
    local config_file=$1 reviewer_cli=$PEER_CLI_NAME declared_reviewer='' declared_value='' fell_back=0

    if declared_reviewer=$(resolve_config_value AGENT_ADVERSARIAL_REVIEWER "$config_file"); then
        reviewer_cli=$declared_reviewer
        # AGENT_ADVERSARIAL_REVIEWER only ever names codex or claude (the
        # resolver refuses anything else), and HARNESS_NAME/PEER_CLI_NAME are
        # always that same two-item set with HARNESS_NAME guaranteed present
        # (it is literally running this script). So a declared reviewer is
        # either the running harness -- always available, no check needed --
        # or the peer, whose availability the contract already probed once
        # and encoded as PEER_CLI_ABSENT; re-probing here would both duplicate
        # that work and make this depend on whatever happens to be on PATH
        # instead of the one already-established environment fact.
        if [[ $reviewer_cli == "$PEER_CLI_NAME" ]] && ((PEER_CLI_ABSENT)); then
            warn "declared adversarial reviewer '$declared_reviewer' (AGENT_ADVERSARIAL_REVIEWER) is not available on this machine; falling back to the running harness '$HARNESS_NAME'"
            reviewer_cli=$HARNESS_NAME
            fell_back=1
        fi
    else
        # With no peer there is no cross-harness reviewer to select. Keep the
        # blind fallback on the running harness so its provider cannot be
        # mislabeled as cross-provider merely because the peer is unavailable.
        ((PEER_CLI_ABSENT)) && reviewer_cli=$HARNESS_NAME
    fi

    case $reviewer_cli in
        codex)
            PROVIDER=openai
            MODEL=gpt-5.6-terra
            EFFORT=xhigh
            HELPER=$SCRIPT_DIR/codex-adversarial-review.sh
            TRANSCRIPT_NAME=codex.jsonl
            ;;
        claude)
            PROVIDER=anthropic
            MODEL=claude-opus-5
            EFFORT=high
            HELPER=$SCRIPT_DIR/claude-adversarial-review.sh
            TRANSCRIPT_NAME=claude.ndjson
            ;;
        *)
            die "unsupported reviewer CLI: $reviewer_cli"
            ;;
    esac

    # AGENT_ADVERSARIAL_REVIEW_MODEL names a model for the declared primary
    # reviewer; AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK names one for the
    # running-harness fallback slot above. Neither is meaningful without
    # AGENT_ADVERSARIAL_REVIEWER declared -- a bare model id has no CLI to be
    # interpreted against. AGENT_ADVERSARIAL_REVIEW_EFFORT is harness-neutral
    # (same convention as AGENT_WORKER_EFFORT) and always applies.
    if ((fell_back)); then
        declared_value=$(resolve_config_value AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK "$config_file") &&
            MODEL=$declared_value
    elif [[ -n $declared_reviewer ]]; then
        declared_value=$(resolve_config_value AGENT_ADVERSARIAL_REVIEW_MODEL "$config_file") &&
            MODEL=$declared_value
    fi
    declared_value=$(resolve_config_value AGENT_ADVERSARIAL_REVIEW_EFFORT "$config_file") && EFFORT=$declared_value

    if [[ $PROVIDER == "$RUNNING_PROVIDER" ]]; then
        MODE=blind-fallback
    else
        MODE=cross-provider
    fi
}

require_helper_executable() {
    [[ -x $HELPER ]] || die "review helper is missing or not executable: $HELPER"
}

validate_args() {
    [[ $PR =~ ^[1-9][0-9]*$ ]] || die_usage '--pr must be a positive integer'
    [[ $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
        die_usage '--repo must look like OWNER/REPO'
    [[ -n $RUN_DIR ]] || die_usage '--run-dir is required'
    ((REAFFIRM_IF_COVERED == 0)) || [[ -n $LEDGER_COMMENTS ]] ||
        die_usage '--reaffirm-if-covered requires --comments'
    command -v gh >/dev/null 2>&1 || die 'gh is required to resolve the pull request base'
    command -v jq >/dev/null 2>&1 || die 'jq is required to validate the review result'
    load_environment_contract
    # Pinned-defaults-only pass: no trusted config source is available yet
    # (BASE_REF is not resolved until later), so this never reads
    # AGENT_ADVERSARIAL_* declarations from anywhere. It exists only to fail
    # fast on a missing helper before spending a gh api round trip.
    select_reviewer ''
    require_helper_executable
}

prepare_owned_artifact() {
    local path=$1
    [[ ! -L $path ]] || die "refusing to use an artifact symlink: $path"
    if [[ -e $path ]]; then
        [[ -f $path && -O $path ]] || die "refusing to replace an artifact not owned by this user: $path"
        rm -f -- "$path" || die "could not clear stale artifact: $path"
    fi
    local tmp="$path.tmp"
    [[ ! -L $tmp ]] || die "refusing to use an artifact temp symlink: $tmp"
    if [[ -e $tmp ]]; then
        [[ -f $tmp && -O $tmp ]] || die "refusing to replace an artifact temp not owned by this user: $tmp"
        rm -f -- "$tmp" || die "could not clear stale artifact temp: $tmp"
    fi
}

resolve_base() {
    local head_oid current_oid pr_json
    pr_json=$(gh api "repos/$REPO/pulls/$PR" 2>/dev/null) ||
        die "could not resolve the base branch for $REPO#$PR"
    BASE_REF=$(jq -er '.base.ref // empty' <<<"$pr_json" 2>/dev/null) ||
        die "could not resolve the base branch for $REPO#$PR"
    [[ -n $BASE_REF ]] || die 'the pull request base branch is empty'
    git check-ref-format --branch "$BASE_REF" >/dev/null 2>&1 ||
        die "the pull request base branch is invalid: $BASE_REF"
    head_oid=$(jq -er '.head.sha // empty' <<<"$pr_json" 2>/dev/null) ||
        die "could not resolve the pull request head for $REPO#$PR"
    [[ $head_oid =~ ^[[:xdigit:]]{40}$ ]] ||
        die "the pull request head OID is invalid: $head_oid"
    current_oid=$(git rev-parse HEAD 2>/dev/null) || die 'could not resolve the checkout HEAD'
    [[ $current_oid == "$head_oid" ]] ||
        die "checkout HEAD $current_oid does not match PR head $head_oid"
}

build_diff() {
    local diff_path=$RUN_DIR/adversarial.diff tmp="$RUN_DIR/adversarial.diff.tmp"
    prepare_owned_artifact "$diff_path"
    [[ ! -L $tmp ]] || die "refusing to use an adversarial diff temp symlink: $tmp"
    git fetch --quiet origin "$BASE_REF" || die "could not fetch origin/$BASE_REF"
    canonical_diff "$BASE_REF" >"$tmp" ||
        die 'could not build the adversarial diff'
    chmod 600 -- "$tmp" || die "could not secure the adversarial diff: $tmp"
    mv -f -- "$tmp" "$diff_path" || die "could not publish the adversarial diff: $diff_path"
    [[ -s $diff_path ]] || die 'the adversarial diff is empty; review is blocked'
    grep -q '[^[:space:]]' -- "$diff_path" || die 'the adversarial diff is empty; review is blocked'
}

# Populates BASE_CONFIG_FILE with a private snapshot of the PR's BASE-revision
# .agent/config.env and returns 0 when select_reviewer should be re-run
# against it; returns 1 (BASE_CONFIG_FILE left empty) when there is nothing
# trustworthy to re-run against, which is also correct: the pinned-defaults
# selection from validate_args already stands unchanged in that case.
#
# Two distinct reasons never apply a declaration, refused rather than merely
# skipped when it is the reviewed diff itself doing the tampering:
#   - the reviewed diff (origin/BASE_REF...HEAD, the exact range sent for
#     review) touches .agent/config.env at all -- the PR under review must
#     never be able to steer the review meant to scrutinize it, so this is
#     announced on stderr and the declarations are ignored outright, not
#     merely read from a stale copy;
#   - the base revision has no .agent/config.env -- nothing was ever
#     declared, so there is nothing to apply; silent, not a tampering signal.
resolve_base_declared_config() {
    local touched base_config="$RUN_DIR/state/adversarial-review-base-config.env" tmp
    touched=$(git diff --name-only "origin/$BASE_REF...HEAD" -- .agent/config.env 2>/dev/null) ||
        die 'could not determine whether the reviewed diff touches .agent/config.env'
    if [[ -n $touched ]]; then
        warn 'the reviewed diff changes .agent/config.env; ignoring any declared adversarial-reviewer settings for this review and using the pinned defaults'
        return 1
    fi
    prepare_owned_artifact "$base_config"
    tmp="$base_config.tmp"
    if ! git show "origin/$BASE_REF:.agent/config.env" >"$tmp" 2>/dev/null; then
        rm -f -- "$tmp"
        return 1
    fi
    chmod 600 -- "$tmp" || die "could not secure the base-revision config snapshot: $tmp"
    mv -f -- "$tmp" "$base_config" || die "could not publish the base-revision config snapshot: $base_config"
    BASE_CONFIG_FILE=$base_config
    return 0
}

# Stashed in the global PAYLOAD (not a local) so write_launch_attempted,
# verify_consent, and try_reaffirm_if_covered can all reuse the exact same
# payload identity without repeated gh/git round trips -- the marker, the
# consent check, and the ledger status check must all agree on what "this
# tree" means.
compute_payload() {
    local consent_script=$SCRIPT_DIR/consent-record.sh
    [[ -x $consent_script ]] || die "consent record helper is missing: $consent_script"
    PAYLOAD=$(
        "$consent_script" payload --repo "$REPO" --pr "$PR" --base-ref "$BASE_REF" \
            --diff "$RUN_DIR/adversarial.diff"
    ) || die 'cannot derive the exact consent payload; refusing to launch review'
}

verify_consent() {
    local consent_script=$SCRIPT_DIR/consent-record.sh
    local state=$RUN_DIR/state/cross-provider-consent check_error
    [[ -x $consent_script ]] || die "consent record helper is missing: $consent_script"
    [[ -n $PAYLOAD ]] || compute_payload
    # Capture only stderr (order matters: dup fd2 to the substitution's pipe
    # before redirecting fd1 away) so a mismatch names the expected and
    # recorded provider tokens instead of a bare boolean refusal.
    check_error=$(
        "$consent_script" check --state "$state" --provider "$PROVIDER" --payload "$PAYLOAD" \
            2>&1 1>/dev/null
    ) && return 0
    die "valid consent-record.sh check is required; refusing to launch review: ${check_error:-no consent record for provider $PROVIDER}"
}

# write_launch_attempted -- the pre-send marker (issue #473). Written as the
# FIRST action inside run_provider, before the external review helper is ever
# invoked, so its presence answers "did we at least try to send this?"
# independently of whether the send itself succeeded, crashed, or lost its
# receipt. Absence of this marker after a launch attempt proves nothing was
# sent -- e.g. the exact "leading comment" bug this issue fixes, where a
# shell comment silently swallowed the launcher before it ever reached this
# script -- so a retry needs no operator authorization. Presence of the
# marker with no completed/blocked result is genuinely ambiguous (sent and
# lost the receipt vs. crashed mid-send), so that case still requires the
# operator prompt described in adversarial-review.md.
# try_reaffirm_if_covered -- issue #477. Returns 0 (and has already appended
# a "reaffirmed_from" ledger entry) when the ledger already proves this exact
# tree, or a base-merge-only advance of it, was reviewed; the caller must
# then skip run_provider entirely. Returns 1 for every other case (stale,
# absent, an unparseable/blocked ledger, or any transport hiccup along the
# way) -- always the SAFE direction to fall back to, since it just means "run
# the review as if this flag were never given".
try_reaffirm_if_covered() {
    local ledger_script="$SCRIPT_DIR/review-ledger.sh"
    [[ -x $ledger_script ]] || {
        warn "review-ledger.sh is missing or not executable; running the review normally: $ledger_script"
        return 1
    }
    local head_oid status_out status_rc=0
    head_oid=$(git rev-parse HEAD 2>/dev/null) || return 1
    status_out=$(
        "$ledger_script" status --repo "$REPO" --pr "$PR" --comments "$LEDGER_COMMENTS" \
            --head "$head_oid" --diff-payload "$PAYLOAD" --kind adversarial \
            --repo-root "$CONTRACT_ROOT" 2>/dev/null
    ) || status_rc=$?
    case $status_rc in
        0) : ;;
        *) return 1 ;;
    esac
    [[ $status_out == covered-head || $status_out == covered-diff ]] || return 1

    local read_out read_rc=0
    read_out=$("$ledger_script" read --repo "$REPO" --pr "$PR" --comments "$LEDGER_COMMENTS" 2>/dev/null) ||
        read_rc=$?
    ((read_rc == 0)) || return 1
    local ledger_json
    ledger_json=$(tail -n +2 <<<"$read_out")

    local original
    original=$(jq -c --arg head "$head_oid" --arg dp "$PAYLOAD" '
      .reviews | map(select(.kind == "adversarial")) |
      (map(select(.head_sha == $head)) + map(select((.diff_payload // "") == $dp and (.diff_payload // "") != ""))) |
      first // empty
    ' <<<"$ledger_json" 2>/dev/null) || return 1
    [[ -n $original && $original != null ]] || return 1

    local entry_file
    entry_file=$(mktemp "${TMPDIR:-/tmp}/adversarial-run-reaffirm.XXXXXXXXXX") || return 1
    chmod 600 -- "$entry_file" 2>/dev/null || true
    jq -cn --arg provider "$PROVIDER" --arg head "$head_oid" --arg dp "$PAYLOAD" \
        --argjson original "$original" --arg verdict "$status_out" \
        '{kind: "adversarial", provider: $provider, head_sha: $head, diff_payload: $dp,
          reaffirmed_from: $original, reaffirmedVerdict: $verdict}' >"$entry_file" 2>/dev/null || {
        rm -f -- "$entry_file"
        return 1
    }

    # A failed append is deliberately non-fatal to the reaffirm decision
    # itself: the ORIGINAL ledger entry (already read above) is what proves
    # coverage, and that proof does not depend on this run successfully
    # recording a second, audit-trail entry on top of it. Treating an append
    # failure as "run the review anyway" would spend a full reviewer call to
    # recover from what is usually a transient comment-transport hiccup, the
    # exact over-spend this flag exists to avoid. A failed append only ever
    # loses the audit trail, never the underlying coverage guarantee.
    if ! "$ledger_script" append --repo "$REPO" --pr "$PR" --comments "$LEDGER_COMMENTS" \
        --entry-file "$entry_file" --agent-identity "$HARNESS_NAME" >&2; then
        warn 'could not append a reaffirmed-from ledger entry; the review is still skipped (the original ledger entry already proves coverage)'
    fi
    rm -f -- "$entry_file"
    printf 'reaffirmed-from-ledger provider=%s verdict=%s head=%s\n' \
        "$PROVIDER" "$status_out" "$head_oid"
    return 0
}

write_launch_attempted() {
    local marker=$RUN_DIR/state/launch-attempted tmp="$RUN_DIR/state/launch-attempted.tmp"
    local head_oid
    head_oid=$(git rev-parse HEAD 2>/dev/null) ||
        die 'could not resolve the checkout HEAD for the launch marker'
    [[ -n $PAYLOAD ]] || die 'no payload id available for the launch marker; refusing to launch review'
    prepare_owned_artifact "$marker"
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg pr "$PR" --arg head "$head_oid" \
        --arg payload "$PAYLOAD" \
        '{timestamp:$ts, pr:($pr|tonumber), head:$head, payload:$payload}' >"$tmp" ||
        die 'could not encode the launch marker'
    chmod 600 -- "$tmp" || die "could not secure the launch marker: $tmp"
    mv -f -- "$tmp" "$marker" || die "could not publish the launch marker: $marker"
}

write_blocked_result() {
    local reason=$1 detail=$2 path=$RUN_DIR/adversarial.result.json tmp="$RUN_DIR/adversarial.result.json.tmp"
    prepare_owned_artifact "$path"
    jq -cn --arg reason "$reason" --arg detail "$detail" --arg provider "$PROVIDER" \
        --arg model "$MODEL" --arg effort "$EFFORT" --arg mode "$MODE" \
        '{status:"blocked", blockedReason:$reason, detail:$detail, provider:$provider,
          requestedModel:$model, effort:$effort, mode:$mode}' >"$tmp" ||
        die 'could not encode the blocked result'
    chmod 600 -- "$tmp" || die "could not secure the blocked result: $tmp"
    mv -f -- "$tmp" "$path" || die "could not publish the blocked result: $path"
}

valid_completed_result() {
    local path=$1
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    jq -e '
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
        (.smallestFix | type) == "string")
    ' <"$path" >/dev/null 2>&1
}

# A blocked run produced no review, so it carries no verdict. Accepting an
# object here let a provider return status="blocked" alongside a findings-shaped
# verdict, which receipt_line then reported as verdict=findings with P1/P2 counts
# -- a blocked review reading as a completed one, which is exactly the state this
# runner exists to make impossible.
valid_blocked_result() {
    local path=$1
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    jq -e 'type == "object" and .status == "blocked" and
      (.blockedReason | type) == "string" and
      ((has("verdict") | not) or (.verdict | type) == "null")' \
        <"$path" >/dev/null 2>&1
}

receipt_line() {
    local path=$RUN_DIR/adversarial.result.json p1 p2 verdict
    # Status is authoritative over the verdict object: even if a blocked result
    # reaches here by some other path, it must never report findings.
    p1=$(jq -r 'if .status == "blocked" then 0 else [.verdict | objects | .findings[]? | select(.priority == "P1")] | length end' <"$path")
    p2=$(jq -r 'if .status == "blocked" then 0 else [.verdict | objects | .findings[]? | select(.priority == "P2")] | length end' <"$path")
    verdict=$(jq -r 'if .status == "blocked" then "blocked" else (.verdict | objects | .verdict) // "blocked" end' <"$path")
    printf 'provider=%s model=%s effort=%s mode=%s P1=%s P2=%s verdict=%s\n' \
        "$PROVIDER" "$MODEL" "$EFFORT" "$MODE" "$p1" "$p2" "$verdict"
}

validate_finding_ledger_if_present() {
    local ledger=$1
    [[ ! -L $ledger ]] || die "refusing to use a findings ledger symlink: $ledger"
    if [[ -e $ledger ]]; then
        [[ -f $ledger && -O $ledger && $(stat -c %a -- "$ledger" 2>/dev/null) == 600 ]] ||
            die "findings ledger is not an owned mode-0600 regular file: $ledger"
    fi
}

# Runs before the provider is ever launched, so a stale or hostile leftover
# findings ledger (e.g. from a prior attempt in a reused RUN_DIR) fails fast
# and names the path instead of surfacing only after the expensive review
# call already ran. A missing ledger is fine here -- it is created once the
# review actually completes, by initialize_finding_ledger below. A safe but
# NON-EMPTY existing ledger is also refused: silently accepting it would
# carry a prior review's dispositions into this review's receipt. An empty
# 0600-owned ledger stays acceptable -- the caller may legitimately
# pre-create one before launch.
check_finding_ledger() {
    local ledger=$RUN_DIR/findings.ndjson
    validate_finding_ledger_if_present "$ledger"
    [[ ! -s $ledger ]] ||
        die "a findings ledger from a prior review is present; use a fresh --run-dir: $ledger"
}

initialize_finding_ledger() {
    local ledger=$RUN_DIR/findings.ndjson
    validate_finding_ledger_if_present "$ledger"
    [[ -e $ledger ]] && return 0
    : >"$ledger" || die "could not create findings ledger: $ledger"
    chmod 600 -- "$ledger" || die "could not secure findings ledger: $ledger"
}

run_provider() {
    local result=$RUN_DIR/adversarial.result.json transcript=$RUN_DIR/$TRANSCRIPT_NAME
    local stdout_path=$RUN_DIR/$PROVIDER.stdout stderr_path=$RUN_DIR/$PROVIDER.stderr rc=0
    # Written before anything else in this function, and therefore before the
    # helper below ever runs -- this is the pre-send marker, not a post-hoc log.
    write_launch_attempted
    local -a helper_args=(
        --mode review --model "$MODEL" --effort "$EFFORT" --pr "$PR" --repo "$REPO"
        --consent-state "$RUN_DIR/state/cross-provider-consent"
        --base-ref "$BASE_REF" --diff "$RUN_DIR/adversarial.diff"
        --transcript "$transcript" --output "$result"
        --max-duration-seconds 900
    )
    if [[ $PROVIDER == anthropic ]]; then
        helper_args+=(--max-budget-usd 5.00)
    else
        helper_args+=(--max-tokens 400000)
    fi
    prepare_owned_artifact "$result"
    prepare_owned_artifact "$stdout_path"
    prepare_owned_artifact "$stderr_path"
    "$HELPER" "${helper_args[@]}" >"$stdout_path" 2>"$stderr_path" || rc=$?
    cat -- "$stderr_path" >&2 || true

    if ((rc == 0)); then
        valid_completed_result "$result" || {
            write_blocked_result invalid-verdict 'provider returned an unparseable or schema-invalid verdict'
            receipt_line
            return 1
        }
        receipt_line
        return 0
    fi
    if ((rc == 3)) && valid_blocked_result "$result"; then
        receipt_line
        return 3
    fi
    write_blocked_result provider-failure "review helper exited $rc without a validated verdict"
    receipt_line
    return 1
}

main() {
    parse_args "$@"
    validate_args
    private_dir_ensure "$RUN_DIR" '--run-dir'
    private_dir_ensure "$RUN_DIR/state" '--run-dir/state'
    prepare_owned_artifact "$RUN_DIR/adversarial.result.json"
    check_finding_ledger
    resolve_base
    build_diff
    if resolve_base_declared_config; then
        select_reviewer "$BASE_CONFIG_FILE"
        require_helper_executable
    fi
    compute_payload
    if ((REAFFIRM_IF_COVERED)) && try_reaffirm_if_covered; then
        return 0
    fi
    verify_consent
    run_provider
    initialize_finding_ledger
}

main "$@"
