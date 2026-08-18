#!/usr/bin/env bash
# Every SKILL.md pays its own way in context: this gate bounds body size,
# requires a trigger-only frontmatter description, and (forward-looking, since
# no skill has one yet) keeps references/ flat and navigable.
#
# .shared/*.md is out of scope -- it has no SKILL.md, so the discovery glob
# below never reaches it.
set -euo pipefail

skills_dir=${1:?usage: lint-skill-size.sh SKILLS_DIR}

# A skill already over budget stays green here only by an explicit, named
# entry below, in the form LINES:TOKENS:TARGET. LINES and TOKENS are that
# skill's body-line and estimated-token counts as of the entry being written
# -- hard caps in BOTH dimensions, because the budget this gate defends is
# context, and a body can grow by hundreds of kilobytes without adding a
# single line. TARGET is the line count to eventually work back down to,
# tracked in the named issue. Remove the entry the moment the skill is back
# under the standard budget -- see the ratchet check further down. If a
# deliberate change legitimately grows an allowlisted skill, raise the
# ceiling it crosses in the same PR so this stays a conscious ratchet, not a
# rubber stamp.
declare -A KNOWN_OVERSIZE=(
    # LINES:TOKENS:TARGET
    [review-remote-pr]="527:8084:450"    # target <=450 lines; issue #107 phase 2 (WS5b) moved the Runtime-neutrality/environment-contract prose (references/environment-contract.md), the Implementation-worker-gate/publication-handback prose (references/worker-gate.md), and the Step 1b materiality criteria (references/adversarial-review.md) out of the body, ratcheting this from the last-committed 603:9180 (origin/feat/issue-106) down; merging that parent branch in added 19 net lines of inherited correctness (PR #116's worktree-root ordering fix and RUN_DIR/REPO re-set guards, plus PR #118's hoisted Step 0a provenance guard and &&-chained commit/verify/push), which is why this entry reads 519:7823 rather than the 497:7503 measured before the merge; the WS5b fix pass (adversarial finding: the paste-scope sentence wrongly told dispatchers to paste the whole dispatcher-side spawn-contract.md into a worker prompt) and a wave-3 accepted-review fix pass (corrected the worker-gate.md pointer's overclaim about what it carries) each nudged this back up to the ceiling above; issue #122 deliberately adds the stale-base/approval-residue handoff rule here and in references/provider-rules.md; it closes with this PR without hitting the target -- a successor issue is needed to track the remaining shrink work (see PR deviations), since most of what remains is executable recipe bytes pinned verbatim by test-review-artifacts.sh/test-parallel-dispatch-contract.sh/test-skills-contract.sh; test-skill-size.sh pins these exact ceiling numbers in its ratchet-message assertions, so a further ratchet needs a companion update to that test in the same PR
    [parallel-issues]="980:16011:900"    # target <=900 lines; issue #107 phase 3 (WS5c) moved the triage/prior-art/board adjudication detail and the --fast-mode Step 2b set-selection procedure to NEW references/triage-and-selection.md (folding the bulk-mutation ledger recipe into the same file), compacted the Adversarial-review receipt section to point at review-remote-pr's references/adversarial-review.md contract instead of restating its mechanics, moved the draft-PR body template heredoc to references/worker-prompts.md (dispatch-output content read at publication time), and trimmed Step 3d's provider-detection duplicate of review-remote-pr's Step 5/6 plus a retired Common-Mistakes note -- with test-parallel-dispatch-contract.sh's publication_section/bulk_section extractions and test-autonomy-flags.sh's fast-mode-board/Step-2b assertions repointed at the reference files -- ratcheting this from the last-committed 1629:27651 (origin/feat/issue-106) down; a wave-3 accepted-review fix pass (corrected the dangling no-brainstorm-template pointer and the Step 3d review-detection misattribution) nudged this back up to the ceiling above. Issue #163 adds the compact changed-input refusal handoff pointer while keeping the detailed digest procedure in references/trust-and-fencing.md; issue #164 adds the dispatch-time PR-loop cap and isolation fallback contract, with the target remaining 900 lines. TARGET was re-baselined from the originally-stated 450 lines to 900: this is a design floor, not an interrupted ratchet -- the linear-execution spine (Step 0 preflight, Step 1 facts, the mandatory triage call, worktree creation, the dispatch/collect loop, board moves) stays in the body by design because the skill executes it sequentially every run, while everything moved out was either conditional (--fast-mode-only, per-issue opt-in) or content read once at a specific later moment (a template, a delegated contract). Shrinking further would mean cutting into the spine itself, which is out of scope for a moves-only pass. Merging the issue-142 receipt chain into this branch brings review-remote-pr to 527:8077 (its --severity operand and the receipt contract text); parallel-issues keeps the 980:15807 measured on the issue-167 chain. Both were then re-measured against the merged body and raised again -- parallel-issues 15807 -> 16011 and review-remote-pr 8077 -> 8084 -- because the merged tree carries BOTH chains' content while each chain's ceiling was measured against its own; no single PR's CI could observe the combined total. test-skill-size.sh's pinned ratchet message moves with it. An accepted-review fix in the same issue raised TOKENS 15330 -> 15339: the Collect heading stated the parking rule unconditionally, so it read as applying to a workstream that had returned a PR URL. Scoping it to a --yolo changed-input refusal costs those 9 tokens; the pinned clauses test-parallel-dispatch-contract.sh asserts ('parks that workstream only', 'continues every other workstream') are kept verbatim, so only the leading condition is new. Line count is unchanged at 940. Issue #167 then raised TOKENS 15800 -> 15807 for its own dispatch write-set content after merging the #164 chain; measured against the merged body and set to the minimum that passes rather than padded. TARGET was re-baselined from the originally-stated 450 lines to 900: this is a design floor, not an interrupted ratchet -- the linear-execution spine (Step 0 preflight, Step 1 facts, the mandatory triage call, worktree creation, the dispatch/collect loop, board moves) stays in the body by design because the skill executes it sequentially every run, while everything moved out was either conditional (--fast-mode-only, per-issue opt-in) or content read once at a specific later moment (a template, a delegated contract). Shrinking further would mean cutting into the spine itself, which is out of scope for a moves-only pass.
    # onboard-repo removed (issue #108, WS6): the judgment-heavy, ATTENDED, linear
    # onboarding skill was trimmed by deleting/relocating war stories (docs/onboarding-lessons.md)
    # and script-printed-output paraphrase, keeping the resumable-stage contract, approval-as-a-
    # human-step, VERIFY-vs-TEST guidance, protected-paths/no-bypass rules, and the config-key
    # Reference table intact -- landing at 350 body lines / ~4852 tokens, back under both the
    # ratcheted ceiling and the standard budget. No references/ split: onboarding is attended and
    # linear, not something a later pass reaches into by name.
)

# Issue #151 adds the session-ledger instructions to both orchestrator bodies.
# Issue #148 (already merged) added the root handback Stage 4 validation contract
# to parallel-issues, ratcheting it to 990:16193 measured against a tree without
# the ledger content. Neither chain's CI could observe the combined total, so both
# ceilings below are re-measured against the merged body and set to the minimum
# that passes -- the planned shrink targets are unchanged. Issue #147 then moves
# the role-separation rationale into references/, trimming both bodies: lines
# ratchet down (1020->1015, 550->547) while review-remote-pr's tokens rise 9
# (8413->8422), because the pointer it leaves behind is denser than the prose it
# replaced. Both dimensions are ratcheted independently, so both are re-set.
# Issue #145 extracts the deterministic S-risk helpers, repeating that shape for
# parallel-issues: 1015->1003 lines but 16724->16735 tokens, since the helper
# invocations that replace the inline procedure are denser per line.
# Issue #144 centralizes worktree setup into a shared library, and unlike the
# entries above this one moves BOTH dimensions down together: parallel-issues
# 1003->966 lines / 16735->16394 tokens, review-remote-pr 547->511 / 8422->7959.
# Ratcheted down rather than left slack -- a ceiling well above the measured
# body silently re-permits the growth this gate exists to catch.
# Issue #224 ("gotta go fast") adds spine content deliberately: named numeric
# wait bounds, the worker commit+push publication flow with its
# environment-refusal fallback, mtime-based stall detection, the pre-review
# materiality gate, once-per-run ledger authorization, per-issue effort, and
# chain-on-commit scheduling. Each buys a measured cost back (2h of timed-out
# waits, 9-10 root<->worker round trips per issue); ceilings re-measured
# against the merged body, minimum that passes. Target unchanged.
# Issue #238 ports the references-read-once/no-sizing rule and removes the
# provider-rules Step 5 re-read; issue #239 moves review-remote-pr fix-batch
# publication to the worker-owned commit+push model and adds the explicit
# no-test-seam red waiver; issue #240 adds the bounded inline-correction
# exception and same-worker-first correction call-site rule to the root review
# spine. The merged tree carries ALL chains' content while each ceiling was
# measured against its own, so both are re-measured against the merged body
# and set to the minimum that passes. Line targets unchanged.
KNOWN_OVERSIZE[review-remote-pr]="513:8144:450"
KNOWN_OVERSIZE[parallel-issues]="1064:18312:900"

readonly MAX_BODY_LINES=500
readonly MAX_BODY_TOKENS=5000
readonly MAX_DESC_CHARS=500
readonly MAX_REF_LINES_WITHOUT_TOC=100
readonly TOC_SCAN_WINDOW=30

violations=0
checked=0

report() {
    printf 'VIOLATION %s: %s\n' "$1" "$2" >&2
    violations=$((violations + 1))
}

# Prints the line number of the frontmatter's closing `---`, or nothing if the
# file has no frontmatter block. The opening delimiter must be line 1: without
# that anchor, any later pair of `---` rules in the body impersonates a
# frontmatter block, so a SKILL.md with no frontmatter at all passes every
# check below (its "description" being whatever sat between two horizontal
# rules). Deliberately reports nothing itself -- callers run this via command
# substitution, and a subshell's report() can't bump the parent's violation
# counter, so the caller must check for emptiness and call report() itself in
# the parent shell.
frontmatter_end() {
    awk '
        NR == 1 && !/^---[[:space:]]*$/ { exit }
        /^---[[:space:]]*$/ { c++; if (c == 2) { print NR; exit } }
    ' "$1"
}

# `wc -l` counts newline characters, so a file whose final line is unterminated
# measures one line short -- exactly enough to sit on a boundary and pass. NR
# counts logical lines, including that last one.
count_lines() {
    awk 'END { print NR }' "$1"
}

# Prints "LINES BYTES" for the body -- everything after the frontmatter's
# closing `---` at line $2.
body_stats() {
    local file=$1 fm_end=$2
    local total_lines body_lines body_bytes
    total_lines=$(count_lines "$file")
    body_lines=$((total_lines - fm_end))
    body_bytes=$(tail -n "+$((fm_end + 1))" "$file" | wc -c)
    printf '%s %s\n' "$body_lines" "$body_bytes"
}

check_size() {
    local file=$1 name=$2 body_lines=$3 body_bytes=$4
    local est_tokens=$((body_bytes / 4))
    local over=0
    if ((body_lines > MAX_BODY_LINES || est_tokens > MAX_BODY_TOKENS)); then
        over=1
    fi

    if [[ -v KNOWN_OVERSIZE[$name] ]]; then
        local entry=${KNOWN_OVERSIZE[$name]} line_ceiling token_ceiling target
        IFS=: read -r line_ceiling token_ceiling target <<< "$entry"
        # Every field must be a plain decimal integer before it reaches the
        # arithmetic below. Under `set -u` a non-numeric field is not a loud
        # zero -- `(( x > foo ))` aborts the whole lint with "unbound
        # variable". `08` dies as an invalid octal literal, and an expression
        # like `1+1` is silently evaluated, quietly moving the ceiling.
        # Leading zeros are rejected rather than normalized: a ceiling should
        # read as the number it is.
        local field
        for field in "$line_ceiling" "$token_ceiling" "$target"; do
            if [[ ! $field =~ ^(0|[1-9][0-9]*)$ ]]; then
                report "$file" \
                    "malformed KNOWN_OVERSIZE entry for '$name' ('$entry') -- expected LINES:TOKENS:TARGET, each a decimal integer without leading zeros"
                return 0
            fi
        done
        if ((over == 0)); then
            report "$file" \
                "allowlisted skill '$name' is now within budget ($body_lines lines, ~$est_tokens tokens) -- remove the stale KNOWN_OVERSIZE entry (target <=$target lines)"
            return 0
        fi
        # Both dimensions ratchet: a skill that trades lines for longer lines
        # is still growing the context it costs.
        if ((body_lines > line_ceiling)); then
            report "$file" \
                "allowlisted skill '$name' grew to $body_lines lines, past its ratcheted ceiling of $line_ceiling lines -- the allowlist tracks a skill shrinking toward its target (<=$target lines), never growing; either shrink it back or, for a deliberate change, raise LINES in this file's KNOWN_OVERSIZE entry in the same PR"
        fi
        if ((est_tokens > token_ceiling)); then
            report "$file" \
                "allowlisted skill '$name' grew to ~$est_tokens estimated tokens, past its ratcheted ceiling of $token_ceiling tokens -- either shrink it back or, for a deliberate change, raise TOKENS in this file's KNOWN_OVERSIZE entry in the same PR"
        fi
        return 0
    fi

    if ((over)); then
        report "$file" \
            "body is $body_lines lines / ~$est_tokens estimated tokens (budget: $MAX_BODY_LINES lines, $MAX_BODY_TOKENS tokens)"
    fi
    return 0
}

# Prints the joined frontmatter description text (possibly empty).
extract_description() {
    local file=$1
    awk '
        BEGIN { in_fm = 0; found = 0; folding = 0; desc = "" }
        /^---[[:space:]]*$/ { in_fm++; if (in_fm == 2) exit; next }
        in_fm != 1 { next }
        !found && /^description:[[:space:]]*/ {
            found = 1
            line = $0
            sub(/^description:[[:space:]]*/, "", line)
            if (line ~ /^[>|][-+]?[[:space:]]*$/) { folding = 1 } else { desc = line }
            next
        }
        found && folding {
            # A blank line inside a block scalar is a paragraph break, not the
            # end of the value -- YAML keeps folding afterwards. Ending here
            # would leave everything past the blank line uncounted, which is a
            # free way to smuggle an over-long description past the limit.
            # The break itself folds to one newline character, so it counts as
            # one character rather than nothing.
            if ($0 ~ /^[[:space:]]*$/) {
                if (desc != "") { desc = desc " " }
                next
            }
            if ($0 ~ /^[[:space:]]+/) {
                val = $0
                sub(/^[[:space:]]+/, "", val)
                desc = (desc == "" ? val : desc " " val)
            } else {
                folding = 0
            }
            next
        }
        END { print desc }
    ' "$file"
}

# YAML lets a trailing `#` comment follow a scalar, and the comment is not part
# of the value. Scoring it as part of the description rejects legal frontmatter
# -- `description: "Use when ..." # note` was reported as not starting with
# "Use when", which is both a false failure and a misleading message.
#
# The cut must never land on a quote *inside* the value: `"... \"q\" ..."` and
# `'... it''s ...'` both carry interior quotes, and cutting at the first one
# truncates the description to a few characters, so an over-long one measures
# short and passes. So a quoted scalar is closed by its LAST quote, and only
# when what follows is actually a comment. Anything else is left whole and
# measured in full -- this gate errs toward over-measuring, which fails loudly,
# never toward under-measuring, which fails silently.
strip_inline_comment() {
    local value=$1 quote=${1:0:1} head tail
    if [[ $quote == '"' || $quote == "'" ]]; then
        # Already a complete quoted scalar: no comment to remove.
        if ((${#value} >= 2)) && [[ ${value: -1} == "$quote" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        head=${value%"$quote"*}   # everything before the LAST quote
        tail=${value##*"$quote"}  # everything after it
        if [[ -n $head && $tail =~ ^[[:space:]]*# ]]; then
            printf '%s%s\n' "$head" "$quote"
            return 0
        fi
        printf '%s\n' "$value"
        return 0
    fi
    if [[ $value == *' #'* ]]; then
        value=${value%%' #'*}
    fi
    printf '%s\n' "$value"
}

check_description() {
    local file=$1 desc
    desc=$(extract_description "$file")
    desc=$(strip_inline_comment "$desc")
    if [[ -z $desc ]]; then
        report "$file" "frontmatter description is empty or missing"
        return 0
    fi
    # YAML allows (but doesn't require) quoting a scalar value; strip one
    # matching pair of leading/trailing quotes so a legally-quoted
    # `description: "Use when ..."` isn't scored on its quote characters.
    local first=${desc:0:1} last=${desc: -1}
    if ((${#desc} >= 2)) && [[ ($first == '"' && $last == '"') || ($first == "'" && $last == "'") ]]; then
        desc=${desc:1:-1}
    fi
    if ((${#desc} > MAX_DESC_CHARS)); then
        report "$file" "frontmatter description is ${#desc} characters (max $MAX_DESC_CHARS)"
    fi
    if [[ $desc != "Use when"* ]]; then
        report "$file" "frontmatter description must begin with \"Use when\": ${desc:0:60}..."
    fi
    return 0
}

check_references() {
    local skill_dir=$1 refs_dir=$1/references
    [[ -d $refs_dir ]] || return 0

    local sub
    while IFS= read -r sub; do
        report "$sub" "subdirectory not allowed under references/ (files must sit directly in it)"
    done < <(find "$refs_dir" -mindepth 1 -maxdepth 1 -type d)

    local doc lines has_toc
    while IFS= read -r doc; do
        lines=$(count_lines "$doc")
        ((lines > MAX_REF_LINES_WITHOUT_TOC)) || continue
        has_toc=$(head -n "$TOC_SCAN_WINDOW" "$doc" |
            grep -ciE '^(## Contents|## Table of contents)' || true)
        if ((has_toc == 0)); then
            report "$doc" \
                "$lines lines with no '## Contents' / '## Table of contents' marker in the first $TOC_SCAN_WINDOW lines"
        fi
    done < <(find "$refs_dir" -maxdepth 1 -name '*.md')
    return 0
}

while IFS= read -r skill_file; do
    checked=$((checked + 1))
    skill_dir=$(dirname "$skill_file")
    name=$(basename "$skill_dir")

    fm_end=$(frontmatter_end "$skill_file")
    if [[ -z $fm_end ]]; then
        report "$skill_file" \
            "no YAML frontmatter block -- it must open with --- on line 1 and close with a later ---"
        continue
    fi

    stats=$(body_stats "$skill_file" "$fm_end")
    read -r body_lines body_bytes <<< "$stats"
    check_size "$skill_file" "$name" "$body_lines" "$body_bytes"

    check_description "$skill_file"
    check_references "$skill_dir"
done < <(find "$skills_dir" -maxdepth 2 -name SKILL.md -not -path '*/.system/*' | sort)

printf 'skill size: %d skills checked, %d violations\n' "$checked" "$violations"
if ((checked == 0)); then
    printf 'VIOLATION %s: no SKILL.md files found -- lint ran against nothing\n' "$skills_dir" >&2
    violations=$((violations + 1))
fi
[[ $violations -eq 0 ]]
