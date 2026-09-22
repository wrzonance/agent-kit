#!/usr/bin/env bash
# Helper scripts are the largest token surface an agent can be made to read,
# and until this gate they were the only one without a ratchet: the 2026-09
# size waves cut them by ~16K tokens and the next two fix waves grew them back
# by ~19K without any check noticing. This mirrors lint-skill-size.sh for every
# *.sh under skills/ and hooks/ -- a per-file cap, an explicit allowlist for
# the files already over it, and a tree-total ceiling so growth spread across
# many under-cap files still fails.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/token-estimate.sh
source "$here/lib/token-estimate.sh"

plugin_dir=${1:?usage: lint-helper-size.sh PLUGIN_DIR}

# Keys are paths relative to PLUGIN_DIR. Values are LINES:TOKENS:TARGET --
# the file's measured size when the entry was written (hard caps in both
# dimensions) and the line count to work back down to. Remove the entry the
# moment the file is back under the standard budget; the ratchet check below
# fails a stale one. A deliberate growth raises the crossed ceiling in the
# same PR, so every raise is a reviewed line in the diff, never a drift.
declare -A KNOWN_OVERSIZE=(
    # LINES:TOKENS:TARGET
    [hooks/lib/guard-lib.sh]="2288:24898:800"
    # #777: complete Step 0 recipe moved from injected prose into --help.
    # #777 absolute-path guard + #778 harness-bound runtime-tool record.
    [skills/.shared/scripts/agent-preflight.sh]="1401:17157:800"
    # #731/#732/#776/#809: records, summaries, and truthful reuse diagnostics.
    [skills/.shared/scripts/agent-run.sh]="1920:20761:800"
    # #865: scope the generated regeneration hint to plugin-backed onboarding.
    [skills/.shared/scripts/bootstrap-repo.sh]="818:10363:800"
    # #777: repository-facts recipe moved from injected prose into --help.
    [skills/.shared/scripts/repo-config.sh]="1154:12008:800"
    [skills/.shared/scripts/worktree-commit.sh]="847:8772:800"
    # #852: distinguish configured missing scans at the retarget boundary.
    [skills/parallel-issues/scripts/chain-advance.sh]="1086:13108:800"
    # #777: guarded batch-move recipe moved from injected prose into --help.
    # #781 merge-down with #777: measured combined helper.
    # #845: keep the helper-owned recovery path readable.
    [skills/parallel-issues/scripts/move-github-project-item.sh]="1010:11462:800"
    # #782: literal-create classification and validation summary.
    [skills/parallel-issues/scripts/write-merge-plan.sh]="1087:13310:800"
    # #711/#765/#850/#843: landing replay and compatible receipt lineage.
    # #760 review: stop anchor probes after the first witness; 65,852 bytes / 4.
    [skills/pr-to-green/scripts/authorize-queue.sh]="1189:17748:800"
    # #834: carry a truthful corrective action for every blocked reason.
    # #834 review repair: retain human-only decisions in four corrective actions.
    # #852 + PR #858 merge-down: retain retarget checks and owned-path diagnostics.
    [skills/pr-to-green/scripts/merge-gate.sh]="899:11809:800"
    # Issue #706: preserve selected invalid model provenance through the result.
    # #717: durable reservation and canonical resume integration; exact size.
    [skills/review-remote-pr/scripts/adversarial-run.sh]="1016:12762:800"
    # #728 separates optional CI outcomes from required acceptance execution.
    [skills/review-remote-pr/scripts/gh-pr-state.sh]="1208:14622:800"
    # #706 skip-provenance refusal plus #707 observed CI evidence.
    # #717: validated attempt provenance in receipts and remote ledger entries.
    [skills/review-remote-pr/scripts/post-receipt.sh]="994:11350:800"
    # #727: independently validated remediation and repair resume.
    # #873: cover states its preconditions and binds fix:<id> via finding-ledger ids.
    [skills/review-remote-pr/scripts/review-ledger.sh]="829:10284:800"
)

# 800 lines is code.md's hard cap for any file; 10,000 tokens is what ~800
# lines of shell measure under bytes/4.
readonly MAX_HELPER_LINES=800
readonly MAX_HELPER_TOKENS=10000
# The whole tree's estimated tokens as of this ceiling being written. Raise it
# only in the PR that needs the room, and say why in that PR.
# #731: verification records and declarations.
# #726: atomic worker ownership and serialized run-state updates.
# #711: bounded invocation authorization and independent fix-push evidence.
# #729: structured handback schema and independently pinned completion evidence.
# #728: optional CI outcomes separated from required acceptance execution.
# #717: durable review attempts and validated receipt provenance.
# #727: confirmed open findings, validated repairs and independent readiness.
# #727 review repairs: preserve coverage context and portable verification hashes.
# #731: freshness fingerprints, durable results, and concurrent leases.
# #732: typed failures and recovery actions.
# #725: required execution and explicit review-only admin authorization.
# #725 review repair: resolve siblings for bare filename invocation.
# #739: retry limits and confirmed review repairs.
# #724: extracted declaration guard and generated-contract proposals; exact bytes / 4.
# #845: canonical executable recovery for copied workflow recipes.
# #764: REST CI evidence collection with bounded, validated archive extraction (+2241).
# #764 review: aggregate transfer/retention limits and independent log collection (+894).
# #761: line-addressable ledger diagnostics and locked conservative repair.
# #761 review repair: refresh record/release transition timestamps.
# #764/#761/#763 merge-down: measured combined helper bytes / 4.
# PR771: remeasure final parent heads and the gh minimum-version declaration.
# #760 recovery: 1,726,607 final bytes / 4 = 431,651 tokens (430,842 + 809).
# #760 Opus repairs: 1,726,679 bytes / 4 = 431,669 tokens (431,651 + 18).
# #765: conflict evidence, generated default history and parked rows; measured growth.
# #761: line-addressable ledger diagnostics and locked conservative repair.
# #761 review repair: refresh record/release transition timestamps.
# #763 + predecessor #772: exact combined helper total; no spare allowance.
# #760 + predecessor #769: 1,750,963 bytes / 4 = 437,740 tokens; exact combined total.
# #764 + predecessor #770: 1,763,705 bytes / 4 = 440,926 tokens; exact combined total.
# #765: recover executable heredocs and retain combined-output file targets.
# #764 + #772 security repair: 1,763,940 bytes / 4 = 440,985 tokens; exact total.
# #760 + updated #772: 1,751,198 bytes / 4 = 437,799 tokens; exact combined total.
# #760 review: 1,751,372 helper bytes / 4 = 437,843 tokens; exact total.
# #764 + #770 review: 1,764,114 helper bytes / 4 = 441,028 tokens; exact total.
# #776: terminal verification summaries and the composed runbook; exact total.
# #774 + #776: partial publication evidence and terminal verification summaries.
# #777: preserve complete helper-owned recipes after the blocker-file merge-down.
# #779: destination-adjacent atomic scratch and .agent parent validation.
# #778: one harness-to-runtime-tool mapping and contract/composer integration.
# #783: computed run-state handoff coverage and lifecycle blocker rendering.
# #782 + final #778 merge-down: literal-create validation and contract fixtures; exact total.
# #785: durable PR recording, trusted backend discovery, and default review rehydration.
# #785: preserve a trusted fallback selector after primary access recovers.
# #782 bot repair: provenance-aware root filename creation; exact integrated total.
# #778 + updated #777: keyed tool contracts and explicit unavailable runbooks.
# #783: atomic, idempotent summary producer and queue records.
# #785 review: optional fallback trust filtering and standalone PR transport.
# #777 review repair + #778: refreshed readers and harness-bound cached tools.
# #780: affirmative consent parsing and refused-source provenance; exact total.
# #780 PR #793 review: bind authorization, reviewer/model, and review purpose; exact total.
# #780 PR #793 bot repair: bind persisted destination and purpose; exact total.
# #776 + #780 merge-down: canonical helper lint measured the exact combined total.
# #774 + #780 merge-down: canonical helper lint measured the exact combined total.
# #779 + #780 merge-down: canonical helper lint measured the exact combined total.
# #783: filename-bound report identity.
# #784 review: cached requirements and work-shape enforcement atop the final parent.
# #785 bot repair: reject duplicate run IDs across trusted state roots.
# #777 review: command-specific attached reader options and fail-fast ledger help.
# Combined #777 review repairs + #778: 1,794,180 helper bytes / 4 = 448,545 tokens.
# #784 review plus final #792 parent: cached verdicts and reader fixes.
# Combined #777 review repairs + #778: GNU awk and bundled-option parsing.
# #784 final #792 parser repairs: cached verdicts and reader fixes.
# #783: computed coverage, atomic producers, and filename-bound report identity.
# #781: shared repository-linked board discovery and atomic cache writer.
# #781 review: paginated discovery, membership selection and optional persistence.
# #781 merge-down with #776: measured combined helper tree.
# #781 merge-down with #774/#776: measured combined helper tree.
# #781 merge-down with #779: measured combined helper tree.
# #781 merge-down with #777: measured combined helper tree.
# #781 merge-down with #778: measured combined helper tree.
# #781 merge-down with #783: measured combined helper tree.
# #782 bot integration: provenance-aware root filename creation; exact combined total.
# #781 merge-down with #782: measured combined helper tree.
# #784 review plus final #792 parser repairs: cached verdicts and reader fixes; exact total.
# #784 settlement repair: validated private body-cache handoff; exact combined total.
# #781 merge-down with #784/#792: measured combined helper tree.
# #800 settlement cache repair: validated private body-cache handoff; 1,826,556 bytes / 4.
# #781 merge-down with #785/#800: measured combined helper tree.
# #756: ordered stdin redirects and queued heredoc recovery; exact total.
# PR #794: descriptor provenance for aliased and nonstdin heredocs; exact total.
# PR #794 bot follow-up: descriptor moves and nested command scopes; exact total.
# #776 + PR #794 merge-down: combined helper tree exact total.
# #774/#776 + PR #794 merge-down: combined helper tree exact total.
# #779 + PR #794 merge-down: 1,786,587 helper bytes / 4 = 446,646 tokens; exact total.
# #777 review + PR #794 merge-down: 1,802,953 helper bytes / 4 = 450,738 tokens; exact total.
# #778 + PR #794 merge-down: 1,806,262 helper bytes / 4 = 451,565 tokens; exact total.
# #783 + PR #794 merge-down: 1,818,298 helper bytes / 4 = 454,574 tokens; exact total.
# #782 + PR #794 merge-down: 1,822,939 helper bytes / 4 = 455,734 tokens; exact total.
# #784/#792 + PR #794 merge-down: 1,828,276 helper bytes / 4 = 457,069 tokens; exact total.
# #800 + PR #794 merge-down: 1,838,638 helper bytes / 4 = 459,659 tokens; exact total.
# #781 merge-down with PR #794: measured combined helper tree.
# #777 + #780 merge-down: canonical helper lint measured the exact combined total.
# #778 + #780 merge-down: canonical helper lint measured the exact combined total.
# #783 + #780 merge-down: canonical helper lint measured the exact combined total.
# #782 + #780 merge-down: canonical helper lint measured the exact combined total.
# #784 + #780 merge-down: canonical helper lint measured the exact combined total.
# #785 + #780 merge-down: canonical helper lint measured the exact combined total.
# #756 + #780 merge-down: canonical helper lint measured the exact combined total.
# #780 PR #793 final review repair: curly-quote consent boundary; exact total.
# #781 merge-down with PR #793: measured combined helper tree.
# #781 review repair: private cache parent and per-issue membership selection.
# #809: cause-accurate verification reuse diagnostics and usage documentation.
# #810: surface the newest completed verification in the existing stall sample.
# #811: field-specific worker-result diagnostics and a self-describing write interface.
# #852: post-retarget CodeQL freshness and configured-missing scan diagnostics.
# #849: cause-specific owned-path diagnostics shared by workflow helpers.
# #850/#843: bounded landing replay and compatible receipt lineage.
# #844: scoped ledger validation, quarantine, and direct-write guards.
# #845 prerequisite join: exact combined helper tree measurement.
# #834: blocked merge-gate reasons carry their corrective actions in-band.
# Issue #844: exact-row quarantine plus payload-scoped Python ledger guarding
# add measured recovery code to the shipped helper tree.
# #834 + repaired #845 parent: exact combined helper tree measurement.
# #834 review repair: exact combined helper tree measurement.
# #865 reference-use clauses and bounded no-run diagnostics: 1,891,483 bytes / 4.
# #873 (trimmed): IDs, evidence producer, cover preconditions: 1,898,236 bytes / 4.
# #875 review: coverage failures preserve handoff evidence across every report path.
readonly MAX_TREE_TOKENS=474846

violations=0
checked=0
tree_bytes=0

report() {
    printf 'VIOLATION %s: %s\n' "$1" "$2" >&2
    violations=$((violations + 1))
}

# NR counts an unterminated final line; `wc -l` would not.
count_lines() {
    awk 'END { print NR }' "$1"
}

check_allowlisted() {
    local file=$1 rel=$2 lines=$3 tokens=$4 over=$5
    local entry=${KNOWN_OVERSIZE[$rel]} line_ceiling token_ceiling target field
    local line_margin token_margin
    IFS=: read -r line_ceiling token_ceiling target <<< "$entry"
    # Non-numeric fields abort arithmetic under `set -u`; `08` is an invalid
    # octal literal; `1+1` silently evaluates. Name the entry instead.
    for field in "$line_ceiling" "$token_ceiling" "$target"; do
        if [[ ! $field =~ ^(0|[1-9][0-9]*)$ ]]; then
            report "$file" \
                "malformed KNOWN_OVERSIZE entry for '$rel' ('$entry') -- expected LINES:TOKENS:TARGET, each a decimal integer without leading zeros"
            return 0
        fi
    done
    if ((over == 0)); then
        line_margin=$((MAX_HELPER_LINES - lines))
        token_margin=$((MAX_HELPER_TOKENS - tokens))
        report "$file" \
            "allowlisted helper '$rel' is now within budget ($lines/$MAX_HELPER_LINES lines, ~$tokens/$MAX_HELPER_TOKENS tokens; line margin $line_margin, token margin $token_margin) -- remove the stale KNOWN_OVERSIZE entry"
        return 0
    fi
    if ((lines > line_ceiling)); then
        report "$file" \
            "allowlisted helper '$rel' grew to $lines lines, past its ratcheted ceiling of $line_ceiling lines -- either shrink it back or, for a deliberate change, raise LINES in this file's KNOWN_OVERSIZE entry in the same PR (target <=$target)"
    fi
    if ((tokens > token_ceiling)); then
        report "$file" \
            "allowlisted helper '$rel' grew to ~$tokens estimated tokens, past its ratcheted ceiling of $token_ceiling tokens -- either shrink it back or, for a deliberate change, raise TOKENS in this file's KNOWN_OVERSIZE entry in the same PR"
    fi
    return 0
}

check_size() {
    local file=$1 rel=$2 lines bytes tokens over=0
    lines=$(count_lines "$file")
    bytes=$(wc -c < "$file")
    tokens=$(estimate_tokens "$bytes")
    tree_bytes=$((tree_bytes + bytes))
    if ((lines > MAX_HELPER_LINES || tokens > MAX_HELPER_TOKENS)); then
        over=1
    fi
    # `-v arr[$key]` re-expands $key as a subscript on Bash 5.1+, so a helper
    # path containing a command substitution would execute it during linting.
    # The `+present}` parameter-expansion form does not re-evaluate the
    # subscript and is the safe membership check.
    if [[ ${KNOWN_OVERSIZE[$rel]+present} ]]; then
        check_allowlisted "$file" "$rel" "$lines" "$tokens" "$over"
        return 0
    fi
    if ((over)); then
        report "$file" \
            "body is $lines lines / ~$tokens estimated tokens (budget: $MAX_HELPER_LINES lines, $MAX_HELPER_TOKENS tokens)"
    fi
    return 0
}

# Scan only the roots that exist: a missing hooks/ in a fixture is not an
# error, but a `find` on it would print one and hide real failures behind it.
scan_roots=()
for sub in skills hooks; do
    [[ -d $plugin_dir/$sub ]] && scan_roots+=("$plugin_dir/$sub")
done
if ((${#scan_roots[@]})); then
    # Captured into a variable rather than piped through `< <(...)` process
    # substitution: a process substitution's exit status is never checked, so
    # a `find` failure (e.g. an unreadable subtree) would be silently
    # discarded and the lint would exit 0 having scanned only part of the
    # tree. `set -o pipefail` (on via the file-level `set -euo pipefail`)
    # makes this assignment fail if either `find` or `sort` does.
    files_list=''
    if ! files_list=$(find "${scan_roots[@]}" -name '*.sh' -not -path '*/.system/*' | sort); then
        report "$plugin_dir" \
            "helper scan failed: find or sort exited non-zero -- the tree may be incompletely scanned (check for an unreadable subtree)"
    fi
    if [[ -n $files_list ]]; then
        while IFS= read -r file; do
            checked=$((checked + 1))
            rel=${file#"$plugin_dir"/}
            check_size "$file" "$rel"
        done <<< "$files_list"
    fi
fi

tree_tokens=$(estimate_tokens "$tree_bytes")
if ((tree_tokens > MAX_TREE_TOKENS)); then
    report "$plugin_dir" \
        "helper tree total is ~$tree_tokens estimated tokens, past the tree total ceiling of $MAX_TREE_TOKENS -- shrink something, or raise MAX_TREE_TOKENS in this file in the same PR and say why"
fi

printf 'helper size: %d helpers checked, %d violations (tree ~%d tokens, ceiling %d)\n' \
    "$checked" "$violations" "$tree_tokens" "$MAX_TREE_TOKENS"
if ((checked == 0)); then
    printf 'VIOLATION %s: no helper scripts found -- lint ran against nothing\n' "$plugin_dir" >&2
    violations=$((violations + 1))
fi
[[ $violations -eq 0 ]]
