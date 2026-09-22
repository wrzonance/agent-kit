# review-remote-pr remediation path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make review-remote-pr's documented "record a fix" path run as written. That means:
- the receipt payload recipe works;
- finding IDs exist and bind to `cover --reason fix:<id>`;
- `cover` states its own preconditions;
- a helper produces fixed-verdict evidence;
- the receipt credits the posting agent;
- the worker-ledger path is unambiguous;
- Step 0 no longer mixes two helpers' flags.

**Architecture:** Every change is local to the helpers and prose that already own each step. There are no new files in `agentkit/`.
- `finding-ledger.sh` gains two subcommands: `ids` (a single source of truth for finding IDs) and `evidence` (a producer that runs the existing `validate_repairs` checks before emitting JSON).
- `review-ledger.sh cover` calls `finding-ledger.sh ids` rather than re-deriving IDs.
- The remaining fixes are prose edits plus one diagnostic message.

**Tech Stack:** Bash 5.2 (`set -euo pipefail`), jq ≥ 1.6, git, ShellCheck 0.11.0 (`-S style`). Tests are the plain-bash suites in `tests/` using `tests/lib/assert.sh`.

**Spec:** https://github.com/wrzonance/agent-kit/issues/873 (read items 1–8 before starting; each task cites its item).

## Global Constraints

- **Work directly on `main` in the primary checkout, `/home/adam/github/agent-kit`.** The user makes every commit and push. Every "Checkpoint" step means stop and hand over for a commit. Never run `git commit` or `git push`.
- **Nothing specific to agent-kit goes into `agentkit/`.** Every shipped change must be correct for any user repository.
- **Shell style:**
  - Shipped scripts keep `set -euo pipefail` and existing idioms (`die_usage` exits 2, `die_evidence` exits 1).
  - Any new shell `sort`/`comm` pins `LC_ALL=C`; `tests/lint-collation.sh` enforces this.
- **ShellCheck** runs as `shellcheck -x -P SCRIPTDIR -S style` and must stay clean for every edited script.
- **Size ratchets** (`tests/lint-skill-size.sh`, `tests/lint-helper-size.sh`) may only be raised in the final task. Each raise carries a `# #873: <reason>` comment. Never lower a gate or add a skip to go green.
- **Version:** `v0.9.9` is tagged and `main` still declares `0.9.9`. Any shipped-byte change must move to the untagged `0.9.10` (Task 0), or `tests/check-release-version.sh` fails.
- **Focused runs** execute a suite file directly (for example `bash tests/test-finding-ledger.sh`). Only the final task runs the full `tests/run-tests.sh`.

---

### Task 0: Baseline and version

**Files:**
- Modify (by tool): `agentkit/.claude-plugin/plugin.json`, `agentkit/.codex-plugin/plugin.json`, plus the third source manifest `bump-version.sh` owns
- Regenerate: `plugin/` (via `tests/build-plugin.sh`)

**Interfaces:** Consumes nothing. Produces a tree whose declared version (`0.9.10`) is untagged, so later tasks can change shipped bytes.

- [ ] **Step 1: Sync and confirm a clean tree**

Run:
```bash
cd /home/adam/github/agent-kit
git checkout main && git pull --ff-only
git status --short
```
Expected: on `main`, fast-forwarded. The only acceptable untracked entry is `agentkit/hooks/lib/__pycache__/`. Stop and ask if anything else is modified.

- [ ] **Step 2: Bump to the next unpublished patch version and rebuild**

Run:
```bash
agentkit/skills/.shared/scripts/bump-version.sh 0.9.10
tests/build-plugin.sh
tests/check-release-version.sh
```
Expected: the last command exits 0. It fails today ("shipped content changed under existing version 0.9.9") because `plugin/` is stale and `0.9.9` is tagged.

- [ ] **Step 3: Record the baseline**

Run: `tests/run-tests.sh --gates-only`
Expected: `ALL GREEN` or the gates section passes. If a gate fails before any change, stop and report it. It is pre-existing and out of scope.

- [ ] **Step 4: Checkpoint.** Hand over for the user to commit as `chore(release): open 0.9.10 for the #873 fixes`.

---

### Task 1: The receipt publish recipe runs verbatim (issue items 1 and 5)

**Files:**
- Modify: `agentkit/skills/review-remote-pr/SKILL.md`, the publish recipe block around lines 386–399
- Create: `tests/test-rrp-remediation-contract.sh`

**Interfaces:**
- Consumes: `consent-record.sh payload --repo R --pr N --diff FILE`, which prints `R:N:<sha256(FILE)>`; `contract-read.sh --repo-root DIR --get harness.identity --worker-model M`, which prints `<Harness> M <email>`.
- Produces: the test file that Tasks 2–5 append their pins to. Its skeleton is below; later tasks insert above the final `finish` line.

**Background:**
- Today the recipe runs `consent-record.sh payload --repo … --pr … --base-ref … --diff …` with `2>/dev/null || rdp=''`.
- `--base-ref` without `--worktree` always dies (`consent-record.sh:162-163`). The redirect hides that, so the receipt silently loses `--diff-payload`.
- `--diff` alone hashes the reviewed bytes, which is the reviewed payload's identity. Adding `--worktree` would be wrong: after fix commits the canonical re-render no longer matches `adversarial.diff`, and `consent-record.sh:298` dies.
- `$AGENT_IDENTITY` is used at `SKILL.md:399` but never defined, so the root guessed and credited the reviewer.

- [ ] **Step 1: Write the failing test**

Create `tests/test-rrp-remediation-contract.sh`:

```bash
#!/usr/bin/env bash
# Issue #873: review-remote-pr's documented remediation path must run as written.
set -uo pipefail

TEST_NAME='review-remote-pr remediation contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
rrp_skill="$skills/review-remote-pr/SKILL.md"
consent="$skills/review-remote-pr/scripts/consent-record.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

# --- item 1: the receipt payload recipe -------------------------------------
recipe_line=$(grep -F 'consent-record.sh" payload' "$rrp_skill" | grep -F 'adversarial.diff' || true)
assert_contains "$recipe_line" '--diff "$RUN_DIR/adversarial.diff"' \
    'the publish recipe derives the payload from the reviewed diff'
assert_not_contains "$recipe_line" '--base-ref' \
    'the publish recipe passes exactly one diff source (no --base-ref re-render)'
assert_not_contains "$recipe_line" '2>/dev/null' \
    'the publish recipe does not swallow a payload failure'

run_dir="$tmp/run"
mkdir -m 700 -- "$run_dir"
printf 'diff --git a/x b/x\n+y\n' >"$run_dir/adversarial.diff"
chmod 600 -- "$run_dir/adversarial.diff"
digest=$(sha256sum -- "$run_dir/adversarial.diff"); digest=${digest%% *}
payload_rc=0
payload=$(cd -- "$tmp" && "$consent" payload --repo owner/repo --pr 14 \
    --diff "$run_dir/adversarial.diff" 2>"$tmp/payload.err") || payload_rc=$?
assert_eq 0 "$payload_rc" 'the recipe payload call succeeds without a worktree'
assert_eq "owner/repo:14:$digest" "$payload" 'the payload identity is the reviewed diff digest'

# --- item 5: the receipt credits the posting agent --------------------------
publish_block=$(sed -n '/post-receipt.sh" publish/,/publish_rc=\$?/p' "$rrp_skill")
identity_line=$(grep -F 'AGENT_IDENTITY=$(' "$rrp_skill" || true)
assert_contains "$identity_line" '--get harness.identity --worker-model "$ROOT_MODEL"' \
    'the recipe derives AGENT_IDENTITY from the contract harness identity and the root model'
assert_contains "$(cat -- "$rrp_skill")" 'never the reviewer' \
    'the recipe says the identity is the posting agent, never the reviewer'
assert_contains "$publish_block" '--agent-identity "$AGENT_IDENTITY"' \
    'publish still consumes the defined identity'

finish
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-rrp-remediation-contract.sh`
Expected: FAIL on "passes exactly one diff source", "does not swallow", and both identity assertions. The executable payload assertions already pass; they pin the corrected call.

- [ ] **Step 3: Fix the recipe**

In `agentkit/skills/review-remote-pr/SKILL.md`, replace this line:

```bash
rdp=$("$agentkit/review-remote-pr/scripts/consent-record.sh" payload --repo "$REPO" --pr "$PR" --base-ref "$BASE_BRANCH" --diff "$RUN_DIR/adversarial.diff" 2>/dev/null) || rdp=''
```

with:

```bash
# The reviewed payload is the hash of the bytes the reviewer saw; a verified skip has no diff.
rdp=''
if [[ -e $RUN_DIR/adversarial.diff ]]; then
    rdp=$("$agentkit/review-remote-pr/scripts/consent-record.sh" payload --repo "$REPO" --pr "$PR" --diff "$RUN_DIR/adversarial.diff") || exit 1
fi
# The agent posting this receipt -- your own harness and model, never the reviewer's.
: "${ROOT_MODEL:?set ROOT_MODEL to your own model id, e.g. gpt-5.6-luna}"
AGENT_IDENTITY=$("$agentkit/.shared/scripts/contract-read.sh" --repo-root "$contract_root" --get harness.identity --worker-model "$ROOT_MODEL") || exit 1
AGENT_IDENTITY=${AGENT_IDENTITY% <*}
```

Leave the following `rla=(); … [[ -z $rdp ]] || rla+=(--diff-payload "$rdp")` line and the `post-receipt.sh publish … --agent-identity "$AGENT_IDENTITY"` call unchanged.

- [ ] **Step 4: Run the test and the markdown-block gate**

Run:
```bash
bash tests/test-rrp-remediation-contract.sh
tests/lint-markdown-blocks.sh agentkit/skills
```
Expected: the suite prints `review-remote-pr remediation contract: N assertions, 0 failed`, and the lint prints `markdown blocks: N checked, 0 failed`. The new `if` block and the `: "${ROOT_MODEL:?…}"` line must stay valid bash inside the fenced recipe.

- [ ] **Step 5: Checkpoint.** Hand over for commit: `fix(review-remote-pr): make the receipt publish recipe run verbatim (#873)`.

---

### Task 2: Finding IDs bind `cover --reason fix:<id>`, and `cover` states its preconditions (items 2 and 3)

**Files:**
- Modify: `agentkit/skills/review-remote-pr/scripts/finding-ledger.sh` (usage, `append_record`, new `cmd_ids`, `main`)
- Modify: `agentkit/skills/review-remote-pr/scripts/review-ledger.sh` (the `cmd_cover` argument checks around lines 681–688; usage lines 39–42)
- Modify: `agentkit/skills/review-remote-pr/references/adversarial-review.md:461-462`
- Test: `tests/test-finding-ledger.sh`, `tests/test-review-ledger.sh`, `tests/test-rrp-remediation-contract.sh`

**Interfaces:**
- Produces:
  - `finding-ledger.sh ids --file FILE` prints one `ID<TAB>TITLE` line per record, in file order. It exits 1 (evidence) on a missing or invalid file.
  - `finding-ledger.sh add …` prints `added finding verdict=V id=ID title=T`.
  - ID rule, the jq function `finding_id`: lowercase the title, collapse each run of `[^a-z0-9]` to `-`, trim one leading and one trailing `-`, and use `finding` if the result is empty.
  - `add` refuses (exit 2) a new title whose ID collides with a different existing title.
  - `review-ledger.sh cover --findings-file F` without `--repo-root` exits 2 with `--findings-file requires --repo-root`.
  - With `--findings-file` and `--reason fix:X`, `cover` exits 2 unless `X` is one of `finding-ledger.sh ids --file F`'s IDs, and the message lists the known IDs.
- Consumes: nothing from Task 1.

- [ ] **Step 1: Write the failing finding-ledger test**

Insert above the final `finish` in `tests/test-finding-ledger.sh`:

```bash
# --- finding IDs (issue #873) ------------------------------------------------
id_run="$tmp/id-run"
mkdir -m 700 "$id_run"
cp "$run_dir/adversarial.result.json" "$id_run/adversarial.result.json"
id_out=$(run_ledger_at "$id_run" add --title 'Guard cleared substring numeric inputs!' \
    --severity P2 --verdict open --rationale 'repair required')
assert_contains "$id_out" 'id=guard-cleared-substring-numeric-inputs' \
    'add prints the finding ID that cover --reason fix: names'
assert_eq $'guard-cleared-substring-numeric-inputs\tGuard cleared substring numeric inputs!' \
    "$("$script" ids --file "$id_run/findings.ndjson")" \
    'ids prints one ID<TAB>title row per finding'
assert_rc 2 'a different title that maps to the same ID is refused' -- run_ledger_at "$id_run" add \
    --title 'guard cleared substring  numeric inputs' --severity P2 --verdict open --rationale 'repair required'
assert_rc 1 'ids refuses a missing findings file as unavailable evidence' -- \
    "$script" ids --file "$id_run/absent.ndjson"
```

- [ ] **Step 2: Write the failing cover tests**

Insert above the final `finish` in `tests/test-review-ledger.sh`. The code reuses `lineage_repo`, `lineage_a`, `lineage_b`, `gh_comment_stub`, `make_comments` and `ledger_body`, all defined earlier in that file:

```bash
# -- cover: finding IDs and --findings-file preconditions (issue #873) --------
id_reviews=$(jq -cn --arg a "$lineage_a" \
    '[{kind:"adversarial",provider:"anthropic",head_sha:$a,counts:{p1:0,p2:1}}]')
id_comments="$tmp/cover-id.json"
make_comments "$id_comments" "$(ledger_body "$id_reviews")" 81
id_findings="$tmp/cover-findings.ndjson"
jq -cn '{title:"Guard cleared input",severity:"P2",verdict:"fixed",sha:"abc1234"}' >"$id_findings"

rc=0
"$script" cover --repo owner/repo --pr 1 --comments "$id_comments" --head "$lineage_b" \
    --reason 'fix:guard-cleared-input' --findings-file "$id_findings" \
    --gh-comment-script "$gh_comment_stub" >/dev/null 2>"$tmp/cover-noroot.err" || rc=$?
assert_eq '2' "$rc" 'cover --findings-file without --repo-root fails at its own argument check'
assert_contains "$(cat "$tmp/cover-noroot.err")" '--findings-file requires --repo-root' \
    'the refusal names the missing cover flag, not a nested helper'

rc=0
"$script" cover --repo owner/repo --pr 1 --comments "$id_comments" --head "$lineage_b" \
    --reason 'fix:not-a-finding' --findings-file "$id_findings" --repo-root "$lineage_repo" \
    --gh-comment-script "$gh_comment_stub" >/dev/null 2>"$tmp/cover-badid.err" || rc=$?
assert_eq '2' "$rc" 'cover refuses a fix: reason that names no finding'
assert_contains "$(cat "$tmp/cover-badid.err")" 'known IDs: guard-cleared-input' \
    'the refusal lists the IDs finding-ledger.sh ids prints'

rc=0
out=$(GH_COMMENT_STUB_OUT="$tmp/cover-id-body.txt" "$script" cover --repo owner/repo --pr 1 \
    --comments "$id_comments" --head "$lineage_b" --reason 'fix:guard-cleared-input' \
    --findings-file "$id_findings" --repo-root "$lineage_repo" \
    --agent-identity 'Codex gpt-5.6-luna' --gh-comment-script "$gh_comment_stub") || rc=$?
assert_eq '0' "$rc" 'cover accepts a fix: reason naming a real finding ID'
assert_contains "$(cat "$tmp/cover-id-body.txt")" '"reason": "fix:guard-cleared-input"' \
    'the ledger records the bound finding ID'
```

Also insert above `finish` in `tests/test-rrp-remediation-contract.sh`:

```bash
# --- item 2/3: cover prose names the real ID source and --repo-root ----------
adv_ref="$skills/review-remote-pr/references/adversarial-review.md"
assert_not_contains "$(cat -- "$adv_ref")" 'fix:FINDING_ID' \
    'the prose no longer names an ID that finding records do not carry'
assert_contains "$(cat -- "$adv_ref")" 'finding-ledger.sh ids --file' \
    'the prose points at the ID source'
assert_contains "$(cat -- "$adv_ref")" '--findings-file FILE --repo-root' \
    'the cover recipe passes --repo-root with --findings-file'
```

- [ ] **Step 3: Run them to verify they fail**

Run:
```bash
bash tests/test-finding-ledger.sh; bash tests/test-review-ledger.sh; bash tests/test-rrp-remediation-contract.sh
```
Expected, each suite with non-zero failures:
- `test-finding-ledger.sh` fails on `id=`, `ids` ("unknown subcommand") and the collision check.
- `test-review-ledger.sh` fails on the `--findings-file requires --repo-root` message (today it's a nested `invalid remediation evidence`) and on the ID binding.
- `test-rrp-remediation-contract.sh` fails on the three prose assertions.

- [ ] **Step 4: Implement finding IDs in `finding-ledger.sh`**

(a) Directly below `readonly ORDER_RC=13`, add:

```bash
readonly FINDING_ID_JQ='def finding_id: ascii_downcase | gsub("[^a-z0-9]+"; "-") | ltrimstr("-") | rtrimstr("-") | if . == "" then "finding" else . end;'
```

(b) Add these two functions directly above `cmd_status() {`:

```bash
finding_id_of() {
    jq -rn --arg title "$1" "$FINDING_ID_JQ"' $title | finding_id'
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
    [[ -f $file ]] || die_evidence 'findings file is missing'
    validate_existing_ledger "$file"
    jq -rs "$FINDING_ID_JQ"' .[] | "\(.title | finding_id)\t\(.title)"' "$file"
}
```

(c) In `append_record`, directly after the `if [[ -f $ledger ]]; then prior=… fi` block, add the collision guard:

```bash
    local finding_id
    finding_id=$(finding_id_of "$TITLE")
    if [[ -f $ledger ]] && jq -se --arg title "$TITLE" --arg id "$finding_id" \
        "$FINDING_ID_JQ"' any(.[]; .title != $title and (.title | finding_id) == $id)' "$ledger" >/dev/null; then
        die_usage "--title maps to finding ID $finding_id, which another title already uses; choose a distinguishable title"
    fi
```

(d) Replace the final line of `append_record`:

```bash
    printf 'added finding verdict=%s title=%s\n' "$VERDICT" "$TITLE"
```

with:

```bash
    printf 'added finding verdict=%s id=%s title=%s\n' "$VERDICT" "$finding_id" "$TITLE"
```

(e) In `main`, add the case above `status|validate) cmd_status "$@" ;;`:

```bash
        ids) cmd_ids "$@" ;;
```

and change the fallback message to `"unknown subcommand: $1 (expected add, ids, status, or validate)"`.

(f) In `usage()`, add this line below the `status|validate` line:

```
       $PROGNAME ids --file FILE    (prints ID<TAB>TITLE; review-ledger.sh cover --reason fix:ID names one)
```

- [ ] **Step 5: Implement the `cover` preconditions and ID binding in `review-ledger.sh`**

(a) In `cmd_cover`, directly after the `--kind` validation (`[[ -z $kind || … ]] || die_usage …`), add:

```bash
    [[ -z $findings_file || -n $repo_root ]] ||
        die_usage '--findings-file requires --repo-root: repair evidence is verified against that checkout'
```

(b) Directly after the existing `require_tools` line in `cmd_cover`, add:

```bash
    if [[ -n $findings_file && $reason == fix:* ]]; then
        local finding_ids
        finding_ids=$("$SCRIPT_DIR/finding-ledger.sh" ids --file "$findings_file") ||
            evidence_unavailable 'could not read finding IDs from --findings-file'
        cut -f1 <<<"$finding_ids" | grep -Fxq -- "${reason#fix:}" ||
            die_usage "--reason $reason names no finding in $findings_file; known IDs: $(cut -f1 <<<"$finding_ids" | paste -sd, -)"
    fi
```

(c) In `usage()`, change the `cover` lines to:

```
       $PROGNAME cover  --repo OWNER/REPO --pr N --comments FILE --head SHA \\
                 --reason (fix:ID|merge-down:SHA|retarget:REF) [--findings-file FILE --repo-root DIR] \\
                 [--kind adversarial|bot] [--provider NAME] [--agent-identity NAME] \\
                 [--trusted-author LOGIN] [--repo-root DIR] [--gh-comment-script PATH]
       fix:ID is an ID printed by finding-ledger.sh ids; --findings-file requires --repo-root.
```

- [ ] **Step 6: Update the prose**

In `agentkit/skills/review-remote-pr/references/adversarial-review.md`, replace:

```
names unresolved obligations and next actions. After repairs, `review-ledger.sh cover` with
`--findings-file FILE --reason fix:FINDING_ID` updates the existing review entry and retains its
```

with:

```
names unresolved obligations and next actions. After repairs, `review-ledger.sh cover` with
`--findings-file FILE --repo-root WORKTREE --reason fix:ID` (ID from `finding-ledger.sh ids --file
FILE`, also printed by each `add`) updates the existing review entry and retains its
```

- [ ] **Step 7: Run the tests and ShellCheck**

Run:
```bash
bash tests/test-finding-ledger.sh; bash tests/test-review-ledger.sh; bash tests/test-rrp-remediation-contract.sh
shellcheck -x -P SCRIPTDIR -S style agentkit/skills/review-remote-pr/scripts/finding-ledger.sh agentkit/skills/review-remote-pr/scripts/review-ledger.sh
```
Expected: all three suites report `0 failed`, and ShellCheck prints nothing. Also run `bash tests/test-post-receipt.sh`. `post-receipt.sh` calls `finding-ledger.sh status`, and that path must be unchanged.

- [ ] **Step 8: Checkpoint.** Hand over for commit: `fix(review-remote-pr): give findings IDs and make cover state its preconditions (#873)`.

---

### Task 3: A producer for fixed-verdict evidence, accepting only an unfocused green log (items 4 and 8)

**Files:**
- Modify: `agentkit/skills/review-remote-pr/scripts/finding-ledger.sh` (new `cmd_evidence`, a `SCRIPT_DIR` definition, usage, `main`)
- Modify: `agentkit/skills/review-remote-pr/references/adversarial-review.md:446-449` (the "Terminal evidence and resume" paragraph)
- Modify: `agentkit/skills/review-remote-pr/SKILL.md`, the two comment lines after the `finding-ledger.sh add … --verdict open` recipe line
- Modify: `agentkit/skills/review-remote-pr/references/worker-gate.md:53-55`
- Test: `tests/test-finding-ledger.sh`, `tests/test-rrp-remediation-contract.sh`

**Interfaces:**
- Consumes: `validate_repairs FILE ROOT HEAD`, the existing function in `finding-ledger.sh`. It checks ancestry, that the repair commit changed the path, that the path is unchanged since testing, the log digest, that the log line matches the command, and a final `rc=0`. Also consumes `repo-config.sh --repo-root DIR --get-argv AGENT_CMD_TEST`, which prints NUL-separated argv.
- Produces: `finding-ledger.sh evidence --title T --path P --log LOG --repo-root DIR [--repair-sha SHA] [--head SHA]`.
  - It prints one JSON object on stdout: `{finding, repairSha, head, path, command, status:"passed", log, logSha256}`.
  - `--head` defaults to `git rev-parse HEAD`.
  - `--repair-sha` defaults to the last commit reachable from head that changed `P`.
  - It exits 1 for a log whose first line isn't the unfocused declared `AGENT_CMD_TEST`, a red log, or a repair commit that doesn't change `P`.
  - The output passes `add --verdict fixed --evidence` unmodified.

- [ ] **Step 1: Write the failing test**

Insert above the final `finish` in `tests/test-finding-ledger.sh`:

```bash
# --- evidence producer (issue #873) -------------------------------------------
ev_repo="$tmp/ev-repo"
git init -q "$ev_repo"
git -C "$ev_repo" config user.name Test
git -C "$ev_repo" config user.email test@example.invalid
mkdir -p "$ev_repo/.agent"
printf 'AGENT_CMD_TEST=tests/regression.sh\nAGENT_CMD_TEST_FOCUS=tests/regression.sh --only %%s\n' \
    >"$ev_repo/.agent/config.env"
printf '.agent/\n' >"$ev_repo/.gitignore"
printf 'broken\n' >"$ev_repo/affected.sh"
git -C "$ev_repo" add .gitignore affected.sh
git -C "$ev_repo" commit -qm baseline
printf 'repaired\n' >"$ev_repo/affected.sh"
git -C "$ev_repo" commit -qam repair
ev_repair=$(git -C "$ev_repo" rev-parse HEAD)
printf 'tidy\n' >"$ev_repo/other.txt"
git -C "$ev_repo" add other.txt
git -C "$ev_repo" commit -qm 'format follow-up'
ev_head=$(git -C "$ev_repo" rev-parse HEAD)
printf '=== agent-run tests/regression.sh\n=== agent-run exited rc=0 after 1s\n' >"$tmp/ev-full.log"
printf '=== agent-run tests/regression.sh --only one\n=== agent-run exited rc=0 after 1s\n' >"$tmp/ev-focused.log"
printf '=== agent-run tests/regression.sh\n=== agent-run exited rc=1 after 1s\n' >"$tmp/ev-red.log"

ev_out=$("$script" evidence --title 'Guard input' --path affected.sh --log "$tmp/ev-full.log" \
    --repo-root "$ev_repo")
assert_eq "$ev_repair" "$(jq -r .repairSha <<<"$ev_out")" \
    'evidence defaults repairSha to the last commit that changed the path, not the head'
assert_eq "$ev_head" "$(jq -r .head <<<"$ev_out")" 'evidence records the tested head'
assert_eq 'tests/regression.sh' "$(jq -r .command <<<"$ev_out")" 'evidence records the logged command'
printf '%s\n' "$ev_out" >"$tmp/ev.json"
ev_run="$tmp/ev-run"
mkdir -m 700 "$ev_run"
cp "$run_dir/adversarial.result.json" "$ev_run/adversarial.result.json"
run_ledger_at "$ev_run" add --title 'Guard input' --severity P2 --verdict open \
    --rationale 'repair required' >/dev/null
assert_rc 0 'producer output is accepted by add --verdict fixed unmodified' -- run_ledger_at "$ev_run" add \
    --title 'Guard input' --severity P2 --verdict fixed --sha "$ev_repair" --evidence "$tmp/ev.json" \
    --repo-root "$ev_repo" --head "$ev_head"
assert_rc 1 'a focused log is refused as repair evidence' -- "$script" evidence --title 'Guard input' \
    --path affected.sh --log "$tmp/ev-focused.log" --repo-root "$ev_repo"
assert_rc 1 'a red log is refused as repair evidence' -- "$script" evidence --title 'Guard input' \
    --path affected.sh --log "$tmp/ev-red.log" --repo-root "$ev_repo"
assert_rc 1 'a repair SHA that does not change the path is refused' -- "$script" evidence \
    --title 'Guard input' --path affected.sh --log "$tmp/ev-full.log" --repo-root "$ev_repo" \
    --repair-sha "$ev_head"
focused_err=$("$script" evidence --title 'Guard input' --path affected.sh --log "$tmp/ev-focused.log" \
    --repo-root "$ev_repo" 2>&1 >/dev/null || true)
assert_contains "$focused_err" 'without --only' 'the focused-log refusal says how to produce valid evidence'
```

Insert above `finish` in `tests/test-rrp-remediation-contract.sh`:

```bash
# --- item 4/8: prose routes evidence through the producer ---------------------
assert_contains "$(cat -- "$adv_ref")" 'finding-ledger.sh evidence' \
    'the evidence contract names the producer'
assert_contains "$(cat -- "$rrp_skill")" 'finding-ledger.sh" evidence' \
    'the SKILL recipe comment uses the producer'
worker_gate="$skills/review-remote-pr/references/worker-gate.md"
assert_contains "$(cat -- "$worker_gate")" 'unfocused' \
    'the worker completion report names the unfocused test log'
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/test-finding-ledger.sh; bash tests/test-rrp-remediation-contract.sh`
Expected: FAIL. `evidence` is an unknown subcommand, exiting 2 rather than the expected 0 or 1, and the three prose assertions fail.

- [ ] **Step 3: Implement `cmd_evidence`**

(a) Directly below `readonly ORDER_RC=13` (and the `FINDING_ID_JQ` line from Task 2), add:

```bash
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
```

(b) Add this function directly above `cmd_status() {`:

```bash
# Emit fixed-verdict evidence for one finding, refusing anything add would
# later reject: the log must be the unfocused declared test run and green, and
# the repair commit must change the finding's path.
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
    [[ -n $title && -n $path && -n $log && -n $root ]] ||
        die_usage 'evidence requires --title, --path, --log and --repo-root'
    reject_unsafe_text '--title' "$title"
    [[ -n $head ]] || head=HEAD
    head=$(git -C "$root" rev-parse --verify "$head^{commit}" 2>/dev/null) ||
        die_evidence "not a commit in $root: $head"
    if [[ -z $repair_sha ]]; then
        repair_sha=$(git -C "$root" log -1 --format=%H "$head" -- "$path")
        [[ -n $repair_sha ]] || die_evidence "no commit reachable from $head changes $path"
    fi
    repair_sha=$(git -C "$root" rev-parse --verify "$repair_sha^{commit}" 2>/dev/null) ||
        die_evidence "not a commit in $root: $repair_sha"
    [[ -f $log && ! -L $log ]] || die_evidence "verification log is unavailable: $log"
    log=$(cd -- "$(dirname -- "$log")" && pwd -P)/${log##*/}
    command=$(sed -n '1s/^=== agent-run //p' "$log")
    declared=$("$SCRIPT_DIR/../../.shared/scripts/repo-config.sh" --repo-root "$root" \
        --get-argv AGENT_CMD_TEST | tr '\0' ' ') || die_evidence 'the repository declares no AGENT_CMD_TEST'
    declared=${declared% }
    [[ -n $command && $command == "$declared" ]] ||
        die_evidence "log is not the unfocused declared test run (log: ${command:-<none>}; declared: $declared); run agent-run.sh --cmd test without --only"
    digest=$(verification_digest "$log") || die_evidence 'verification log digest unavailable (requires sha256sum or shasum)'
    row=$(mktemp "${TMPDIR:-/tmp}/finding-evidence.XXXXXXXX")
    jq -cn --arg finding "$title" --arg sha "$repair_sha" --arg head "$head" --arg path "$path" \
        --arg command "$command" --arg log "$log" --arg digest "${digest%% *}" \
        '{schemaVersion:2, verdict:"fixed", sha:$sha, evidence:{finding:$finding, repairSha:$sha,
          head:$head, path:$path, command:$command, status:"passed", log:$log, logSha256:$digest}}' >"$row"
    ( validate_repairs "$row" "$root" "$head" ) || { rm -f -- "$row"; exit 1; }
    jq '.evidence' "$row"
    rm -f -- "$row"
}
```

(c) In `main`, add `evidence) cmd_evidence "$@" ;;` next to the `ids)` case, and extend the fallback message to `(expected add, evidence, ids, status, or validate)`.

(d) In `usage()`, add below the `ids` line:

```
       $PROGNAME evidence --title T --path P --log LOG --repo-root DIR [--repair-sha SHA] [--head SHA]
                 (prints fixed-verdict evidence JSON; LOG must be a green unfocused agent-run.sh --cmd test log)
```

- [ ] **Step 4: Update the prose**

(a) In `references/adversarial-review.md`, replace the paragraph that starts `Update the same title after repair using` and ends `It never runs a command from evidence.` with:

```
Update the same title after repair. Produce its evidence with
`finding-ledger.sh evidence --title TITLE --path AFFECTED_PATH --log GREEN_LOG --repo-root WORKTREE > FILE`:
the log must be the green, unfocused `agent-run.sh --cmd test` run (a focused `--only` or red log is
refused), `--head` defaults to the checkout's HEAD, and `--repair-sha` defaults to the last commit
that changed that path (a later formatting-only commit is not the repair). Then record it with
`add --verdict fixed --sha "$(jq -r .repairSha FILE)" --evidence FILE --repo-root WORKTREE --head CURRENT_SHA`
(also supply title and severity). One evidence file per finding. The helper checks commit ancestry,
the changed path, and verification bytes; missing or unreachable evidence blocks resolution. It
never runs a command from evidence.
```

(b) In `SKILL.md`, replace the two comment lines:

```bash
# After repair, update the same title with --verdict fixed --sha FULL_SHA --evidence FILE
# --repo-root "$contract_root" --head CURRENT_SHA; declines require --evidence FILE too.
```

with:

```bash
# After repair: ev="$RUN_DIR/evidence-ID.json"; "$agentkit/review-remote-pr/scripts/finding-ledger.sh" evidence --title 'SHORT_TITLE'
# --path AFFECTED_PATH --log GREEN_UNFOCUSED_LOG --repo-root "$contract_root" >"$ev", then add --verdict fixed
# --sha "$(jq -r .repairSha "$ev")" --evidence "$ev" --repo-root "$contract_root" --head CURRENT_SHA; declines require --evidence FILE too.
```

(c) In `references/worker-gate.md`, replace:

```
Workers commit and push their own branch after focused/full verification and a completion report
(branch, full SHA, diffstat, green log); `worktree-commit.sh` uses explicit files and trailer.
```

with:

```
Workers commit and push their own branch after focused/full verification and a completion report
(branch, full SHA, diffstat, and the path of the green unfocused `agent-run.sh --cmd test` log);
`worktree-commit.sh` uses explicit files and trailer. Root turns that log into repair evidence with
`finding-ledger.sh evidence`, which refuses a focused or red log -- send the worker back to verify
rather than accepting the handback.
```

- [ ] **Step 5: Run the tests and ShellCheck**

Run:
```bash
bash tests/test-finding-ledger.sh; bash tests/test-rrp-remediation-contract.sh; bash tests/test-post-receipt.sh
shellcheck -x -P SCRIPTDIR -S style agentkit/skills/review-remote-pr/scripts/finding-ledger.sh
```
Expected: `0 failed` for each suite, and no ShellCheck output.

- [ ] **Step 6: Checkpoint.** Hand over for commit: `feat(review-remote-pr): produce fixed-finding evidence from an unfocused green log (#873)`.

---

### Task 4: The worker-ledger path is unambiguous, and the error names the real root (item 6)

**Files:**
- Modify: `agentkit/skills/parallel-issues/scripts/named-active-state.sh:70`
- Modify: `agentkit/skills/.shared/spawn-contract.md:248-249`
- Test: `tests/test-named-active-state.sh`, `tests/test-rrp-remediation-contract.sh`

**Interfaces:**
- Produces: the ledger-path refusal message is `--ledger must be inside <resolved primary checkout>/.agent/runs (the primary checkout; linked worktrees share its ledger)`, still exiting 2.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Insert above the final `finish` in `tests/test-named-active-state.sh`. It reuses `$repo` and the `$worker` linked worktree created earlier in the file:

```bash
# Issue #873: a caller in a linked worktree passing its own .agent/runs path is
# told the primary checkout's path, not a REPO_ROOT it never passed.
primary_real=$(cd -P -- "$repo" && pwd -P)
wt_rc=0
wt_err=$("$helper" --repo-root "$worker" --ledger "$worker/.agent/runs/active-workers.ndjson" \
    --issue 511 --open-pr none --fresh-hours 2 --now-epoch 2000000000 2>&1 >/dev/null) || wt_rc=$?
assert_eq '2' "$wt_rc" 'a worktree-local ledger path is refused'
assert_contains "$wt_err" "$primary_real/.agent/runs" \
    'the refusal names the resolved primary checkout ledger directory'
```

Insert above `finish` in `tests/test-rrp-remediation-contract.sh`:

```bash
# --- item 6: the spawn contract names the primary checkout's ledger ----------
assert_contains "$(cat -- "$skills/.shared/spawn-contract.md")" "primary checkout's \`.agent/runs/active-workers.ndjson\`" \
    'the spawn contract says the ledger lives in the primary checkout'
```

- [ ] **Step 2: Run them to verify they fail**

Run: `bash tests/test-named-active-state.sh; bash tests/test-rrp-remediation-contract.sh`
Expected: FAIL on "names the resolved primary checkout" (today's message is the literal `REPO_ROOT`) and on the spawn-contract assertion.

- [ ] **Step 3: Implement**

In `named-active-state.sh`, replace:

```bash
    *) die '--ledger must be inside REPO_ROOT/.agent/runs' ;;
```

with:

```bash
    *) die "--ledger must be inside $repo_root/.agent/runs (the primary checkout; linked worktrees share its ledger)" ;;
```

In `.shared/spawn-contract.md`, replace:

```
Root uses `parallel-issues/scripts/named-active-state.sh` with
`.agent/runs/active-workers.ndjson`, shared across runs/worktrees. Keep the dispatch plan's
```

with:

```
Root uses `parallel-issues/scripts/named-active-state.sh` with the primary checkout's
`.agent/runs/active-workers.ndjson` (from a linked worktree:
`"$(git worktree list --porcelain | sed -n '1s/^worktree //p')/.agent/runs/active-workers.ndjson"`),
shared across runs/worktrees. Keep the dispatch plan's
```

- [ ] **Step 4: Run the tests and ShellCheck**

Run:
```bash
bash tests/test-named-active-state.sh; bash tests/test-rrp-remediation-contract.sh
shellcheck -x -P SCRIPTDIR -S style agentkit/skills/parallel-issues/scripts/named-active-state.sh
```
Expected: `0 failed`, and no ShellCheck output.

- [ ] **Step 5: Checkpoint.** Hand over for commit: `fix(shared): name the primary-checkout worker ledger (#873)`.

---

### Task 5: Step 0 stops listing two helpers' flags in one sentence (item 7)

**Files:**
- Modify: `agentkit/skills/review-remote-pr/SKILL.md:12-14`, `agentkit/skills/pr-to-green/SKILL.md:17-19`, `agentkit/skills/onboard-repo/SKILL.md:17-19`, `agentkit/skills/parallel-issues/SKILL.md:21-23`
- Test: `tests/test-rrp-remediation-contract.sh`

**Interfaces:** The only flags `workflow-activation.sh check` accepts are `--require`, `--repo-root`, `--target-root`, `--session`, `--skill`, `--nonce`, `--skills` and `--digest` (`lib/workflow-activation.py:377-385`). `--activation-session/--workflow` belong to `agent-preflight.sh`.

- [ ] **Step 1: Write the failing test**

Insert above `finish` in `tests/test-rrp-remediation-contract.sh`:

```bash
# --- item 7: Step 0 keeps check's flags and preflight's flags apart -----------
for skill in review-remote-pr pr-to-green onboard-repo parallel-issues; do
    step0=$(sed -n '/Step 0 prerequisite/,/^Missing challenge/p' "$skills/$skill/SKILL.md")
    check_sentence=$(grep -F 'check --require pre-tool-use' <<<"$step0" || true)
    assert_contains "$check_sentence" "--repo-root R --session ID --skill $skill" \
        "$skill Step 0 spells check's full flag set on one line"
    assert_not_contains "$check_sentence" '--activation-session' \
        "$skill Step 0 keeps preflight flags out of the check sentence"
    assert_contains "$step0" 'agent-preflight.sh' "$skill Step 0 attributes the session flags to preflight"
done
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash tests/test-rrp-remediation-contract.sh`
Expected: FAIL for all four skills.

- [ ] **Step 3: Implement**

In `review-remote-pr/SKILL.md`, replace:

```
Require `workflow-activation.sh check --require pre-tool-use` with the boundary's
`--repo-root`, `--session`, `--skill` before work; preflight uses
`--activation-session ID --workflow review-remote-pr`.
```

with:

```
Before work, require `workflow-activation.sh check --require pre-tool-use --repo-root R --session ID --skill review-remote-pr`;
`check` takes no other flags. `agent-preflight.sh` separately takes `--activation-session ID --workflow review-remote-pr`.
```

Make the same replacement in `pr-to-green/SKILL.md` and `onboard-repo/SKILL.md`, substituting `pr-to-green` or `onboard-repo` in both places. In `parallel-issues/SKILL.md`, replace:

```
Before dispatch, require `workflow-activation.sh check --require pre-tool-use` with
the boundary's `--repo-root`, `--session`, `--skill`; pass that session to preflight
with `--activation-session ID --workflow parallel-issues`.
```

with:

```
Before dispatch, require `workflow-activation.sh check --require pre-tool-use --repo-root R --session ID --skill parallel-issues`;
`check` takes no other flags. `agent-preflight.sh` separately takes `--activation-session ID --workflow parallel-issues`.
```

- [ ] **Step 4: Run the tests**

Run:
```bash
bash tests/test-rrp-remediation-contract.sh
grep -rn 'check --require pre-tool-use' tests/*.sh | cut -c1-120
```
Expected: `0 failed`. The grep shows only the new suite (no other test pins the old wording; this was verified while planning).

- [ ] **Step 5: Checkpoint.** Hand over for commit: `docs(skills): separate check and preflight flags in Step 0 (#873)`.

---

### Task 6: Ratchets, generated plugin, full verification

**Files:**
- Modify: `tests/lint-skill-size.sh` (only the ceilings the lint names), `tests/lint-helper-size.sh` (only named entries and `MAX_TREE_TOKENS`)
- Regenerate: `plugin/`

**Interfaces:** Consumes every earlier task. Produces a green full suite.

- [ ] **Step 1: Rebuild and measure**

Run:
```bash
tests/build-plugin.sh
tests/lint-skill-size.sh agentkit/skills; tests/lint-helper-size.sh agentkit
```
Expected: either both pass, or each names the files over their ratchet with exact measured sizes (for example `past its ratcheted ceiling of 8725 tokens`).

- [ ] **Step 2: Raise only what the lint names, with the reason**

For each file the lint names, edit its entry to the measured `lines:tokens:limit` and add a comment on the line above. For example, in `tests/lint-skill-size.sh`:

```bash
    # #873: runnable publish recipe (payload, identity) and evidence-producer steps.
    [review-remote-pr]="<measured-lines>:<measured-tokens>:450"
```

For `MAX_TREE_TOKENS` in `tests/lint-helper-size.sh`, replace the comment and value with the measured total:

```bash
# #873 finding IDs, evidence producer, cover preconditions: <bytes> bytes / 4.
readonly MAX_TREE_TOKENS=<measured>
```

Then update any test that hard-codes an old ceiling. Find them with:
```bash
grep -rn '<old-token-ceiling>\|<old-line-ceiling>' tests/*.sh
```
Change only the numbers those assertions pin (the #865 run needed this in `tests/test-skill-size.sh`).

- [ ] **Step 3: Full suite**

Run: `agentkit/skills/.shared/scripts/agent-run.sh --cmd test`
Expected: one `PASS:` line and `=== agent-run exited rc=0`. On `FAIL`, read the log tail, fix the cause in the task that owns it, and re-run. Never loosen a gate.

- [ ] **Step 4: Confirm scope**

Run:
```bash
git status --short
git diff --stat
```
Expected: changes only in the files the tasks list, plus `plugin/` manifests and the new `tests/test-rrp-remediation-contract.sh`.
- Nothing under `.agent/` or `.worktrees/`.
- Under `agentkit/`, only the `review-remote-pr` scripts and prose, `named-active-state.sh`, `spawn-contract.md`, the four `SKILL.md` Step 0 lines and the manifests.

- [ ] **Step 5: Checkpoint.** Hand over for commit: `chore(tests): raise #873 size ratchets` (or fold it into the previous commit, at the user's choice). Then close #873 when it's pushed.
