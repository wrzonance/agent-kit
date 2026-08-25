#!/usr/bin/env bash
# Suite: prepare-issue-artifacts.sh -- the fetch/validate/fence/publish helper
# behind the "Root canonical issue fetch and fence preparation" recipe.
set -uo pipefail

TEST_NAME='prepare-issue-artifacts'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/parallel-issues/scripts/prepare-issue-artifacts.sh"
stub_gh="$here/stub/gh"
fixture="$here/fixtures/issue-fetch.json"
# Invoked by absolute path so a curated, jq-less PATH (used below to simulate
# a missing parser) can never make the interpreter itself unresolvable.
bash_bin=$(command -v bash)

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

stub_path="$tmp_dir/stub-bin"
mkdir -p "$stub_path"
ln -s "$stub_gh" "$stub_path/gh"

new_worktree() {
    mktemp -d "$tmp_dir/worktree.XXXXXX"
}

# run_prepare WORKTREE ISSUE BOUNDARY [PRIOR_ART_FILE]
run_prepare() {
    local worktree=$1 issue=$2 boundary=$3 prior=${4:-}
    local -a args=(--worktree "$worktree" --issue "$issue" --boundary "$boundary")
    [[ -z $prior ]] || args+=(--prior-art "$prior")
    PATH="$stub_path:$PATH" "$bash_bin" "$script" "${args[@]}"
}

expected_spec_text() {
    jq -r '
  [
    ("Title: " + (.title // "")),
    ("Body:\n" + (.body // "")),
    ("Labels:\n" + ((.labels // []) | map(.name) | join(", "))),
    ("Comments:\n" + ((.comments // [])
      | map("- " + ((.author.login // "unknown") | tostring) + ": " + (.body // ""))
      | join("\n")))
  ] | join("\n\n")
' <"$fixture"
}

# ---------------------------------------------------------------- happy path
# The published filename itself must never assert a fence that does not exist
# (issue #334): only public-fenced actually wraps the bytes, so only
# public-fenced keeps the fenced-spec.txt / fenced-prior-art.txt names;
# private-trusted and yolo-trusted publish under the mode-neutral
# spec.txt / prior-art.txt names instead.
for boundary in public-fenced private-trusted yolo-trusted; do
    worktree=$(new_worktree)
    out="$tmp_dir/out.$boundary"
    err="$tmp_dir/err.$boundary"
    rc=0
    GH_STUB_RESPONSE="$fixture" run_prepare "$worktree" 42 "$boundary" \
        >"$out" 2>"$err" || rc=$?
    assert_eq 0 "$rc" "$boundary: exits 0 on a healthy issue"
    assert_eq yes "$([[ -f "$worktree/.agent/fetched-issue.json" ]] && printf yes || printf no)" \
        "$boundary: publishes the raw fetched payload"
    assert_eq yes "$([[ -d "$worktree/.agent/fenced-ready" ]] && printf yes || printf no)" \
        "$boundary: publishes the readiness marker as a directory"
    assert_contains "$(<"$out")" "published: $worktree/.agent/fetched-issue.json" \
        "$boundary: reports the raw payload as published"
    assert_contains "$(<"$out")" "published: $worktree/.agent/fenced-ready" \
        "$boundary: reports the readiness marker as published"

    if [[ $boundary == public-fenced ]]; then
        spec_file="$worktree/.agent/fenced-spec.txt"
        prior_file="$worktree/.agent/fenced-prior-art.txt"
    else
        spec_file="$worktree/.agent/spec.txt"
        prior_file="$worktree/.agent/prior-art.txt"
        assert_eq no "$([[ -e "$worktree/.agent/fenced-spec.txt" ]] && printf yes || printf no)" \
            "$boundary: publishes no artifact whose name asserts fencing (spec)"
        assert_eq no "$([[ -e "$worktree/.agent/fenced-prior-art.txt" ]] && printf yes || printf no)" \
            "$boundary: publishes no artifact whose name asserts fencing (prior art)"
    fi
    assert_contains "$(<"$out")" "published: $spec_file" \
        "$boundary: reports the spec artifact as published"
    assert_contains "$(<"$out")" "published: $prior_file" \
        "$boundary: reports the prior-art artifact as published"

    spec=$(<"$spec_file")
    prior=$(<"$prior_file")
    if [[ $boundary == public-fenced ]]; then
        assert_contains "$spec" '<BEGIN UNTRUSTED ISSUE DATA: BND_' \
            "$boundary: spec carries the opening fence marker"
        assert_contains "$spec" '<END UNTRUSTED ISSUE DATA: BND_' \
            "$boundary: spec carries the closing fence marker"
        assert_contains "$prior" '<BEGIN UNTRUSTED ISSUE DATA: BND_' \
            "$boundary: prior-art carries the opening fence marker"
        assert_contains "$prior" '(no prior art selected by triage digest)' \
            "$boundary: fenced prior-art still carries the default sentinel text"
    else
        assert_eq "$(expected_spec_text)" "$spec" \
            "$boundary: spec is byte-identical to the rendered issue text"
        assert_eq '(no prior art selected by triage digest)' "$prior" \
            "$boundary: prior-art is byte-identical to the default sentinel"
    fi
done

# Two independent public-fenced runs must never reuse a boundary token.
worktree_a=$(new_worktree)
worktree_b=$(new_worktree)
GH_STUB_RESPONSE="$fixture" run_prepare "$worktree_a" 42 public-fenced >/dev/null 2>&1
GH_STUB_RESPONSE="$fixture" run_prepare "$worktree_b" 42 public-fenced >/dev/null 2>&1
nonce_a=$(grep -o 'BND_[0-9A-F]*' "$worktree_a/.agent/fenced-spec.txt" | head -n1)
nonce_b=$(grep -o 'BND_[0-9A-F]*' "$worktree_b/.agent/fenced-spec.txt" | head -n1)
assert_eq yes "$([[ -n $nonce_a && -n $nonce_b && $nonce_a != "$nonce_b" ]] && printf yes || printf no)" \
    'independent runs mint independent per-run nonces'

# A supplied --prior-art file publishes byte-identical content (not the
# default sentinel) in a verbatim-copy boundary mode.
#
# Compared with cmp, and with a fixture that ends in a blank line. The previous
# comparison was $(cat -- file) against $(<file): command substitution strips
# every trailing newline from BOTH sides, so it could not fail for the defect it
# existed to catch -- the file was round-tripped through a shell variable and
# published without the blank line that terminates a Markdown block, silently
# editing content these boundary modes promise to copy verbatim.
worktree=$(new_worktree)
prior_file="$tmp_dir/prior-art.txt"
printf 'triage found related PR #9\n\n' >"$prior_file"
GH_STUB_RESPONSE="$fixture" run_prepare "$worktree" 42 yolo-trusted "$prior_file" >/dev/null 2>&1
published_prior="$worktree/.agent/prior-art.txt"
if cmp -s "$prior_file" "$published_prior"; then
    _pass 'a supplied prior-art file publishes byte-identical content in yolo-trusted mode'
else
    _fail 'a supplied prior-art file publishes byte-identical content in yolo-trusted mode' \
        "source $(wc -c <"$prior_file") bytes, published $(wc -c <"$published_prior") bytes"
fi
assert_eq "$(wc -c <"$prior_file")" "$(wc -c <"$published_prior")" \
    'the published prior-art keeps its trailing blank line'

# ------------------------------------------------------------ empty issue
worktree=$(new_worktree)
empty_fixture="$tmp_dir/empty-issue.json"
printf '{}' >"$empty_fixture"
err="$tmp_dir/empty.err"
rc=0
GH_STUB_RESPONSE="$empty_fixture" run_prepare "$worktree" 1 private-trusted \
    >/dev/null 2>"$err" || rc=$?
assert_eq 1 "$rc" 'an empty issue payload is rejected before rendering'
assert_contains "$(<"$err")" 'evidence unavailable' \
    'the empty-issue rejection names the evidence-unavailable reason'
assert_eq yes "$([[ -f "$worktree/.agent/fetched-issue.json" ]] && printf yes || printf no)" \
    'an empty issue payload still persists the raw fetch for audit'
# private-trusted publishes the mode-neutral spec.txt name (issue #334).
assert_eq no "$([[ -e "$worktree/.agent/spec.txt" ]] && printf yes || printf no)" \
    'an empty issue payload leaves no spec artifact'
assert_eq no "$([[ -e "$worktree/.agent/fenced-ready" ]] && printf yes || printf no)" \
    'an empty issue payload leaves no readiness marker'

# --------------------------------------------------------------- missing jq
no_jq_dir="$tmp_dir/no-jq-bin"
mkdir -p "$no_jq_dir"
for tool in mkdir mktemp chmod mv cp rm rmdir; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$no_jq_dir/$tool"
done
ln -s "$stub_gh" "$no_jq_dir/gh"
worktree=$(new_worktree)
err="$tmp_dir/nojq.err"
rc=0
GH_STUB_RESPONSE="$fixture" PATH="$no_jq_dir" "$bash_bin" "$script" \
    --worktree "$worktree" --issue 1 --boundary private-trusted \
    >/dev/null 2>"$err" || rc=$?
assert_eq 1 "$rc" 'a missing jq parser is rejected'
assert_contains "$(<"$err")" 'jq is not installed; evidence unavailable' \
    'the missing-jq rejection names the evidence-unavailable reason'

# ------------------------------------------------------------ complete set
worktree=$(new_worktree)
GH_STUB_RESPONSE="$fixture" run_prepare "$worktree" 42 private-trusted >/dev/null 2>&1
spec_before=$(<"$worktree/.agent/spec.txt")
prior_before=$(<"$worktree/.agent/prior-art.txt")
fetched_before="$tmp_dir/fetched-before.json"
cp -- "$worktree/.agent/fetched-issue.json" "$fetched_before"
# The refused run is fed a DIFFERENT payload on purpose. With the same fixture
# both times, a re-fetch rewrites byte-identical content and the comparison
# below cannot detect the clobber it exists to catch -- it would pass whether or
# not the refusal happens before the fetch.
refuse_fixture="$tmp_dir/issue-fetch-changed.json"
jq '.title = "CHANGED AFTER THE FIRST RUN"' "$fixture" >"$refuse_fixture"
err="$tmp_dir/refuse.err"
rc=0
GH_STUB_RESPONSE="$refuse_fixture" run_prepare "$worktree" 42 private-trusted \
    >/dev/null 2>"$err" || rc=$?
assert_eq 12 "$rc" 'a complete fenced artifact set refuses re-fencing with exit 12'
assert_contains "$(<"$err")" 'delete the affected file deliberately before re-fencing' \
    'the refusal names the deliberate-delete remedy'
assert_eq "$spec_before" "$(<"$worktree/.agent/spec.txt")" \
    'the refusal leaves the existing spec artifact untouched'
assert_eq "$prior_before" "$(<"$worktree/.agent/prior-art.txt")" \
    'the refusal leaves the existing prior-art artifact untouched'
# fetched-issue.json is part of the same deliberate set. The refusal used to run
# after the fetch had already replaced it, so this compares bytes (cmp, not a
# command substitution that would strip trailing newlines) to prove the refusal
# now happens before any network call or publish.
if cmp -s "$fetched_before" "$worktree/.agent/fetched-issue.json"; then
    _pass 'the refusal leaves fetched-issue.json byte-identical'
else
    _fail 'the refusal leaves fetched-issue.json byte-identical' \
        "before $(wc -c <"$fetched_before") bytes, after $(wc -c <"$worktree/.agent/fetched-issue.json") bytes"
fi

# ------------------------------------------------- step-named publish failure
# The trio is published one member at a time and is not atomic, so a failure
# must name WHICH member did not land -- "mv/mkdir failed" leaves the caller to
# work out whether the spec, the prior-art pair, or the readiness marker is
# missing. Injected with a mv stub that fails only for the prior-art move
# (private-trusted publishes the mode-neutral prior-art.txt name, not
# fenced-prior-art.txt -- issue #334).
fail_mv_dir="$tmp_dir/fail-mv-bin"
mkdir -p "$fail_mv_dir"
real_mv=$(command -v mv)
cat >"$fail_mv_dir/mv" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    case \$arg in
        *prior-art.txt) printf 'mv: injected failure\\n' >&2; exit 1 ;;
    esac
done
exec "$real_mv" "\$@"
EOF
chmod +x "$fail_mv_dir/mv"
ln -sf "$stub_gh" "$fail_mv_dir/gh"
worktree=$(new_worktree)
err="$tmp_dir/publish-step.err"
rc=0
GH_STUB_RESPONSE="$fixture" PATH="$fail_mv_dir:$stub_path:$PATH" "$bash_bin" "$script" \
    --worktree "$worktree" --issue 42 --boundary private-trusted \
    >/dev/null 2>"$err" || rc=$?
assert_eq 1 "$rc" 'a failed publication step exits with that step'"'"'s status'
assert_contains "$(<"$err")" 'prior-art.txt' \
    'the publication failure names the member that did not land'
assert_contains "$(<"$err")" 'the fenced artifact set is incomplete' \
    'the publication failure says the set is incomplete'
assert_eq no "$([[ -d "$worktree/.agent/fenced-ready" ]] && printf yes || printf no)" \
    'a failed publication step leaves no readiness marker'

# --------------------------------------------------------------- incomplete
worktree=$(new_worktree)
mkdir -p "$worktree/.agent"
# private-trusted publishes the mode-neutral spec.txt name (issue #334).
printf 'stale spec\n' >"$worktree/.agent/spec.txt"
rc=0
GH_STUB_RESPONSE="$fixture" run_prepare "$worktree" 42 private-trusted >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" 'an incomplete stale artifact set is cleaned up and republished'
assert_not_contains "$(<"$worktree/.agent/spec.txt")" 'stale spec' \
    'the stale spec content does not survive cleanup'
assert_eq yes "$([[ -d "$worktree/.agent/fenced-ready" ]] && printf yes || printf no)" \
    'the retried run publishes the readiness marker'

# --------------------------------------------------------------- atomicity
# An unwritable staging directory fails after the trio's stale-check has run
# but before any of the trio's bytes are written -- nothing partial must land.
worktree=$(new_worktree)
bad_tmpdir="$tmp_dir/does-not-exist"
rc=0
GH_STUB_RESPONSE="$fixture" PATH="$stub_path:$PATH" TMPDIR="$bad_tmpdir" \
    "$bash_bin" "$script" --worktree "$worktree" --issue 42 --boundary public-fenced \
    >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'an unwritable staging TMPDIR is reported'
assert_eq no "$([[ -e "$worktree/.agent/fenced-spec.txt" ]] && printf yes || printf no)" \
    'the injected staging failure leaves no fenced spec'
assert_eq no "$([[ -e "$worktree/.agent/fenced-spec.txt.tmp" ]] && printf yes || printf no)" \
    'the injected staging failure leaves no temporary spec fence'
assert_eq no "$([[ -e "$worktree/.agent/fenced-prior-art.txt" ]] && printf yes || printf no)" \
    'the injected staging failure leaves no fenced prior art'
assert_eq no "$([[ -e "$worktree/.agent/fenced-ready" ]] && printf yes || printf no)" \
    'the injected staging failure leaves no readiness marker'

# ------------------------------------------------------------ bad arguments
worktree=$(new_worktree)
rc=0
"$bash_bin" "$script" --issue 1 --boundary private-trusted >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'a missing --worktree is rejected'

rc=0
"$bash_bin" "$script" --worktree "$worktree" --issue 1 --boundary nonsense >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'an unrecognized boundary mode is rejected'

rc=0
"$bash_bin" "$script" --worktree "$worktree" --issue not-a-number --boundary private-trusted \
    >/dev/null 2>&1 || rc=$?
assert_eq 1 "$rc" 'a non-numeric issue number is rejected'

rc=0
"$bash_bin" "$script" -h >/dev/null 2>&1 || rc=$?
assert_eq 0 "$rc" '--help exits 0'

finish
