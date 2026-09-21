#!/usr/bin/env bash
# Canonical local verification for the skill tree. Run from anywhere.
set -euo pipefail

# Pin the locale (issue #846). Collation decides sort order and the byte
# grammar decides how multibyte quotes are matched, so an unpinned run is a
# different gate on every developer's shell: `C` fails the curly-quote consent
# suite, a UTF-8 locale fails the path-prediction suite, and only a C-collating
# UTF-8 locale -- what CI happens to use -- passes both. Pin it so the local
# gate is the CI gate, rather than red on a clean tree for reasons nothing
# names.
#
# POSIX guarantees only `C` and `POSIX`, and macOS ships no `C.UTF-8`, so
# resolve against what this host actually has instead of asserting a name.
pin_locale() {
    local candidate available
    available=$(locale -a 2> /dev/null || true)
    for candidate in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
        if printf '%s\n' "$available" | grep -Fxq -- "$candidate"; then
            export LC_ALL="$candidate"
            return 0
        fi
    done
    export LC_ALL=C
    printf 'run-tests: no C-collating UTF-8 locale found; using LC_ALL=C.\n' >&2
    printf '  Suites asserting multibyte text may fail; install locale C.UTF-8 to match CI.\n' >&2
}
pin_locale

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# The plugin root holds both the skills and the hook dispatchers. The hooks are
# not skills, but they ship in the same artifact, so every gate that guards the
# skills guards them too -- scanning the plugin root covers both in one pass.
plugin="$root/agentkit"
skills="$plugin/skills"

rc=0
step() { printf '\n== %s\n' "$1"; }

usage() {
    printf 'Usage: %s [--only NAME[,NAME...] | --shard I/N | --gates-only]\n' "${0##*/}" >&2
    printf '  --only NAME[,NAME...]  run only the named test suites\n' >&2
    printf '  --shard I/N             run suite shard I of N (one-based)\n' >&2
    printf '  --gates-only            run static gates without unit suites\n' >&2
    exit "${1:-2}"
}

only=''
shard=''
gates_only=no
while (($#)); do
    case $1 in
        --only)
            (($# >= 2)) || { printf 'run-tests: --only requires a value\n' >&2; usage; }
            only=$2
            [[ -n $only ]] || { printf 'run-tests: --only requires a non-empty value\n' >&2; usage; }
            [[ $only != ,* && $only != *, && $only != *,,* ]] || {
                printf 'run-tests: --only contains an empty suite name\n' >&2
                usage
            }
            shift 2
            ;;
        --shard)
            (($# >= 2)) || { printf 'run-tests: --shard requires a value\n' >&2; usage; }
            shard=$2
            shift 2
            ;;
        --gates-only)
            gates_only=yes
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            printf 'run-tests: unknown argument: %s\n' "$1" >&2
            usage
            ;;
    esac
done

mode_count=0
[[ -z $only ]] || mode_count=$((mode_count + 1))
[[ -z $shard ]] || mode_count=$((mode_count + 1))
[[ $gates_only == no ]] || mode_count=$((mode_count + 1))
if ((mode_count > 1)); then
    printf 'run-tests: --only, --shard, and --gates-only are mutually exclusive\n' >&2
    usage
fi

shard_index=''
shard_count=''
if [[ -n $shard ]]; then
    if [[ $shard =~ ^([1-9][0-9]*)/([1-9][0-9]*)$ ]]; then
        shard_index=${BASH_REMATCH[1]}
        shard_count=${BASH_REMATCH[2]}
    fi
    if [[ -z $shard_index || $shard_index -gt $shard_count ]]; then
        printf 'run-tests: invalid --shard value: %s (expected I/N with 1 <= I <= N)\n' "$shard" >&2
        usage
    fi
fi

run_gates=yes
run_suites=yes
[[ -z $shard ]] || run_gates=no
[[ $gates_only == no ]] || run_suites=no

jobs=${AGENT_TEST_JOBS:-}
if [[ -z $jobs ]]; then
    jobs=$(nproc 2>/dev/null || printf '1')
fi
[[ $jobs =~ ^[1-9][0-9]*$ ]] || {
    printf 'run-tests: AGENT_TEST_JOBS must be a positive integer\n' >&2
    exit 2
}

shopt -s nullglob
suites=()
suite_names=()
for suite in "$here"/test-*.sh; do
    name=${suite##*/test-}
    name=${name%.sh}
    suites+=("$suite")
    suite_names+=("$name")
done

selected=()
selected_names=()
if [[ $run_suites == no ]]; then
    :
elif [[ -n $only ]]; then
    IFS=, read -r -a requested <<< "$only"
    for name in "${requested[@]}"; do
        valid=no
        for known in "${suite_names[@]}"; do
            [[ $name == "$known" ]] && valid=yes && break
        done
        if [[ $valid == no || -z $name ]]; then
            printf 'run-tests: unknown suite name: %s\n' "$name" >&2
            printf 'Valid suite names: %s\n' "${suite_names[*]:-none}" >&2
            exit 2
        fi
    done
    # Discovery order is sorted by the glob, so output order is deterministic
    # even when callers provide a different focus-list order.
    for i in "${!suites[@]}"; do
        for name in "${requested[@]}"; do
            if [[ ${suite_names[i]} == "$name" ]]; then
                selected+=("${suites[i]}")
                selected_names+=("${suite_names[i]}")
                break
            fi
        done
    done
elif [[ -n $shard ]]; then
    weights_file=$here/suite-weights.tsv
    [[ -r $weights_file ]] || {
        printf 'run-tests: missing suite weights: %s\n' "$weights_file" >&2
        exit 2
    }

    declare -A suite_exists=() suite_weight=() suite_assignment=()
    for name in "${suite_names[@]}"; do
        suite_exists[$name]=yes
    done

    while IFS=$'\t' read -r name weight extra; do
        [[ -n $name && $name != \#* ]] || continue
        if [[ -n $extra || ! $weight =~ ^[1-9][0-9]*$ ]]; then
            printf 'run-tests: invalid suite weight record: %s\t%s%s\n' \
                "$name" "$weight" "${extra:+\t$extra}" >&2
            exit 2
        fi
        [[ ${suite_exists[$name]:-} == yes ]] || {
            printf 'run-tests: suite weight names an unknown suite: %s\n' "$name" >&2
            exit 2
        }
        [[ -z ${suite_weight[$name]:-} ]] || {
            printf 'run-tests: duplicate suite weight: %s\n' "$name" >&2
            exit 2
        }
        suite_weight[$name]=$weight
    done <"$weights_file"

    declare -a shard_totals=()
    for ((i = 0; i < shard_count; i++)); do
        shard_totals[i]=0
    done

    while IFS=$'\t' read -r weight name; do
        best=0
        for ((i = 1; i < shard_count; i++)); do
            ((shard_totals[i] < shard_totals[best])) && best=$i
        done
        suite_assignment[$name]=$best
        shard_totals[best]=$((shard_totals[best] + weight))
    done < <(
        for name in "${!suite_weight[@]}"; do
            printf '%s\t%s\n' "${suite_weight[$name]}" "$name"
        done | sort -t $'\t' -k1,1nr -k2,2
    )

    for name in "${suite_names[@]}"; do
        [[ -z ${suite_assignment[$name]:-} ]] || continue
        read -r checksum _ < <(printf '%s' "$name" | cksum)
        suite_assignment[$name]=$((checksum % shard_count))
    done

    target=$((shard_index - 1))
    for i in "${!suites[@]}"; do
        if [[ ${suite_assignment[${suite_names[i]}]} -eq $target ]]; then
            selected+=("${suites[i]}")
            selected_names+=("${suite_names[i]}")
        fi
    done
else
    selected=("${suites[@]}")
    selected_names=("${suite_names[@]}")
fi

if [[ $run_gates == yes ]]; then
step 'shellcheck (shipped scripts)'
mapfile -t scripts < <(find "$plugin" -name '*.sh' | sort)
printf '  %d scripts\n' "${#scripts[@]}"
# -x follows `# shellcheck source=` so the hooks' shared library is analysed as
# part of each caller; -P SCRIPTDIR resolves those paths against each script's
# own directory rather than the one this gate is invoked from.
if ((${#scripts[@]})); then
    printf '%s\0' "${scripts[@]}" |
        xargs -0 -n 1 -P "$jobs" shellcheck -x -P SCRIPTDIR -S style || rc=1
else
    printf '  ok (none)\n'
fi

step 'bash -n (shipped scripts)'
for f in "${scripts[@]}"; do
    bash -n "$f" || rc=1
done
printf '  ok\n'

step 'bash 5.2 compatibility'
# The target is Debian trixie (bash 5.2.37); this machine runs 5.3. `bash -n`
# here would accept 5.3-only syntax that is a syntax error there, and no 5.2
# binary is available to test against -- so grep for the additions.
if grep -rnE '\$\{[[:space:]]|\$\{\||compgen -V|GLOBSORT' "$plugin" \
    --include='*.sh' --include='*.md'; then
    printf '  FAIL  bash 5.3-only syntax; the target is 5.2\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'shellcheck (test scripts)'
# The exclusion must be anchored to this directory. `-not -path '*/tmp/*'` was
# intended to skip the scratch dir, but the working root itself lives under /tmp,
# so it matched EVERY test script and this gate linted nothing for its whole life.
mapfile -t tscripts < <(find "$here" -name '*.sh' -not -path "$here/tmp/*" | sort)
((${#tscripts[@]} >= 5)) || {
    printf '  FAIL  only %d test scripts matched; the filter is excluding too much\n' \
        "${#tscripts[@]}" >&2
    rc=1
}
printf '  %d test scripts\n' "${#tscripts[@]}"
# -x follows `# shellcheck source=` directives so the helper's use of TEST_NAME
# is visible and does not read as a dead variable. -P SCRIPTDIR resolves those
# relative paths against each script's own directory rather than the caller's
# cwd, which is what this gate is run from.
printf '%s\0' "${tscripts[@]}" "$here/stub/gh" |
    xargs -0 -n 1 -P "$jobs" shellcheck -x -P SCRIPTDIR -S style -e SC1091 || rc=1

step 'markdown code blocks'
"$here/lint-markdown-blocks.sh" "$skills" || rc=1

step 'skill helper invocations'
"$here/lint-skill-invocations.sh" "$skills" || rc=1

step 'skill size'
"$here/lint-skill-size.sh" "$skills" || rc=1

step 'helper size'
"$here/lint-helper-size.sh" "$plugin" || rc=1

step 'helper/reference paths'
"$here/lint-helper-refs.sh" "$skills" || rc=1

step 'reference manifest'
"$here/lint-reference-manifest.sh" "$skills" || rc=1

step 'collation pinning'
"$here/lint-collation.sh" "$plugin" || rc=1

step 'versioned plugin paths'
# Scans the whole plugin root, not just $skills: the hooks tree ships the
# detector this lint must not flag (agentkit/hooks/post-tool-use.sh's own
# regex literal) alongside the skills it protects.
"$here/lint-versioned-plugin-paths.sh" --selftest || rc=1
"$here/lint-versioned-plugin-paths.sh" "$plugin" || rc=1

step 'no vendored system skills'
# .system/ is Codex's OWN bundled skill set (imagegen, skill-creator,
# plugin-creator, review-agent, skill-installer, openai-docs), each under its own
# licence. It appeared here only because an early snapshot copied all of
# ~/.codex/skills. Shipping it would redistribute OpenAI's skills under this
# manifest and shadow ones Codex already provides.
if [[ -e $plugin/skills/.system ]]; then
    printf '  FAIL  .system/ is Codex own bundled skills and must not ship\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'ecosystem-neutrality'
# The skills must name commands, never ecosystems. A repo driven by make, cargo,
# uv, or a bespoke dispatcher gets a wrong example otherwise, and the agent burns
# a failed call discovering that.
#
# Detection code is the deliberate exception and marks itself: enumerating the
# ecosystems a repository MIGHT use is how the tree stays agnostic -- the
# opposite of prescribing one. Those lines carry an `ecosystem-allow:` marker
# stating why, so the exemption is per-line and visible in review rather than a
# whole file quietly dropping out of the gate.
#
# Matched as <tool> <subcommand>, not as `npm run` alone: the leak this gate
# missed was `-- npm test`, six lines away from a block that had already been
# converted. Naming the tool is what makes a line wrong, whatever subcommand
# follows it.
if grep -rnE -e '(^|[^a-z-])(pnpm|yarn)\b' \
    -e '(^|[^a-z./-])(npm|pnpm|yarn|bun|cargo|uv|poetry|pipenv|go|make|just|task|mvn|gradle|pytest|tox)[[:space:]]+(run|test|ci|install|build|check|lint|fmt|typecheck)([^a-z-]|$)' \
    "$plugin" --include='*.md' --include='*.sh' |
    grep -v 'ecosystem-allow:'; then
    printf '  FAIL  ecosystem-specific command in the shipped tree\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'no pre-plugin paths'
# Packaging moves the tree, so `$codex_home/skills/...` no longer resolves. The
# hooks kept teaching it in their deny messages long after the skills stopped
# using it -- a guard that corrects you with a broken command is worse than no
# guard, and only a live session surfaced it.
if grep -rn 'codex_home' "$plugin" \
    --include='*.sh' --include='*.md'; then
    printf '  FAIL  references the pre-plugin skills path\n' >&2
    rc=1
else
    printf '  ok\n'
fi

step 'harness-neutrality'
# The tree runs under more than one agent CLI, from more than one account. Three
# ways that breaks, each of which has actually happened:
#
#   1. A resolver that searches one harness's plugin cache. Every helper
#      invocation then resolves to nothing on the other CLI.
#   2. A manifest for one harness only. The plugin does not install at all.
#   3. Prose that names one CLI as THE harness -- "the shell Codex runs",
#      "one Codex issue lead" -- which reads as an instruction, not a note.
#
# Cross-harness references are the deliberate exception and mark themselves with
# `harness-allow:`, the same per-line, visible-in-review escape the
# ecosystem gate uses. Naming BOTH CLIs in one line is inherently even-handed and
# passes without a marker.
harness_rc=0

while IFS= read -r resolver_file; do
    if grep -q 'CODEX_HOME' "$resolver_file" && ! grep -q 'CLAUDE_CONFIG_DIR' "$resolver_file"; then
        printf '  FAIL  %s searches one harness cache only\n' "$resolver_file" >&2
        harness_rc=1
    fi
done < <(grep -rl 'plugins/cache' "$plugin" --include='*.sh' --include='*.md')

for manifest in .claude-plugin/plugin.json .codex-plugin/plugin.json; do
    if [[ ! -r $plugin/$manifest ]]; then
        printf '  FAIL  missing %s; the plugin will not install on that harness\n' "$manifest" >&2
        harness_rc=1
    fi
done

# Both harnesses look for the hook manifest at hooks/hooks.json.
if [[ ! -r $plugin/hooks/hooks.json ]]; then
    printf '  FAIL  hooks/hooks.json is where both harnesses look for it\n' >&2
    harness_rc=1
fi

# Naming a CLI is not the failure -- the concrete review recipes MUST name one,
# and instruction files, config paths, model ids and script flags all carry the
# names harmlessly. The failure is prose that tells the agent WHAT IT IS, so this
# matches assumption-shaped phrasing rather than every mention. A curated pattern
# risks missing a novel phrasing; matching every mention produced forty lines of
# noise and would have been switched off within a week.
if grep -rniE '\b(codex|claude)\b[[:space:]]+(runs|uses|exposes|commonly|issue lead|session|harness|runtime|agent\b)|the shell (codex|claude)|(codex|claude) (credit|equivalent)|one \*\*(codex|claude)' \
    "$skills" --include='*.md' --include='*.sh' |
    grep -viE 'harness-allow:' |
    grep -viE '\bcodex\b.*\bclaude\b|\bclaude\b.*\bcodex\b'; then
    printf '  FAIL  prose that names one agent CLI as THE harness. Write it from the\n' >&2
    printf '        contract (harness= / peer-cli=), or mark a deliberate\n' >&2
    printf '        cross-harness reference with harness-allow:\n' >&2
    harness_rc=1
fi

[[ $harness_rc -eq 0 ]] && printf '  ok\n' || rc=1

step 'environment-neutrality'
# Runtime permissions and review automation belong to the current session and
# repository configuration. A public skill must not turn one operator's
# measured sandbox or SaaS settings into universal instructions.
environment_rc=0
if grep -rniE \
    -e 'The network is disabled inside the sandbox' \
    -e 'Every git write needs elevation' \
    -e 'Only the workspace is writable' \
    -e 'automatic and incremental reviews are disabled' \
    -e 'push(es)? trigger(s)? (no|nothing)' \
    -e 'ready flip triggers no review' \
    -e 'no review is automatic' \
    -e 'Nothing is automatic' \
    -e 'automatic reviews are off' \
    "$skills" --include='*.md' --include='*.sh' |
    # The preflight helper emits measured contract notes; these are runtime
    # facts, not guidance the neutrality gate is meant to reject.
    grep -vE '/agent-preflight\.sh:[0-9]+:.*note='; then
    printf '  FAIL  skill guidance hardcodes runtime or provider configuration\n' >&2
    environment_rc=1
else
    printf '  ok\n'
fi
[[ $environment_rc -eq 0 ]] || rc=1

step 'org-neutrality'
# The identifier list is deliberately not committed: export AGENTKIT_ORG_PATTERN
# as a grep -E pattern of org-identifying strings (names, hosts, addresses).
if [[ -z "${AGENTKIT_ORG_PATTERN:-}" ]]; then
    printf '  ok (AGENTKIT_ORG_PATTERN unset; nothing to scan for)\n'
elif grep -rniE "$AGENTKIT_ORG_PATTERN" \
    "$plugin" \
    --include='*.sh' --include='*.md' --include='*.yaml' --include='*.json'; then
    printf '  FAIL  organization-identifying text in the shipped tree\n' >&2
    rc=1
else
    printf '  ok\n'
fi

# There was a gate here that pinned a spelled-out suite count in the README to
# the number of files in this directory. It was added because the README once
# claimed eight suites over a tree of eleven, and an external review read the
# understatement as a coverage claim.
#
# It is gone because the cost landed on the wrong thing. Every branch that adds
# a suite has to edit one shared line of prose, so a run of parallel PRs pays a
# failed CI round and a merge conflict each -- for a number nobody reads, when
# the run prints its real totals a few lines later. The README no longer states
# a count, which is the honest version of the same claim.
fi

if [[ $run_suites == yes ]]; then
step 'unit suites'
selection_note=''
[[ -z $only ]] || selection_note=", focus=$only"
[[ -z $shard ]] || selection_note=", shard=$shard"
printf '  %d selected (jobs=%s%s)\n' "${#selected[@]}" "$jobs" "$selection_note"

suite_tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-test-suites.XXXXXX")
trap 'rm -rf -- "$suite_tmp"' EXIT
declare -a suite_status suite_output suite_pid active_pids=()
declare -A pid_index=()

wait_for_suite() {
    local done_pid index status
    if wait -n -p done_pid "${active_pids[@]}"; then
        status=0
    else
        status=$?
    fi
    index=${pid_index[$done_pid]}
    suite_status[index]=$status
    unset 'pid_index[$done_pid]'
    for index in "${!active_pids[@]}"; do
        [[ ${active_pids[index]} == "$done_pid" ]] || continue
        unset 'active_pids[index]'
        break
    done
}

for i in "${!selected[@]}"; do
    suite_output[i]=$suite_tmp/$i.out
    if ((jobs == 1)); then
        "${selected[i]}" >"${suite_output[i]}" 2>&1 || suite_status[i]=$?
    else
        "${selected[i]}" >"${suite_output[i]}" 2>&1 &
        suite_pid[i]=$!
        active_pids+=("${suite_pid[i]}")
        pid_index[${suite_pid[i]}]=$i
        while ((${#active_pids[@]} >= jobs)); do
            wait_for_suite
        done
    fi
done
while ((${#active_pids[@]})); do
    wait_for_suite
done

for i in "${!selected[@]}"; do
    printf '\n-- test-%s.sh\n' "${selected_names[i]}"
    cat -- "${suite_output[i]}"
    [[ ${suite_status[i]:-0} -eq 0 ]] || rc=1
done
fi

printf '\n%s\n' "$([[ $rc -eq 0 ]] && echo 'ALL GREEN' || echo 'FAILURES ABOVE')"
exit "$rc"
