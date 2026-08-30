#!/usr/bin/env bash
# Suite: every scripts/ helper that already speaks a repository-slug or
# checkout-path flag accepts the kit's canonical spelling -- --repo and
# --repo-root respectively (issue #556). A helper that still only recognizes
# an older spelling (--repository, --dir) punishes a caller who just used the
# canonical flag on the previous helper in the same run.
#
# "Takes a flag for that concept" is judged structurally, from the helper's
# own argv case statement, never from a hand-maintained list here -- a new
# helper copied from a --repository- or --dir-only starting point is caught
# the same way this suite catches the drift issue #556 reports, and a helper
# with neither branch is simply not in scope.
set -uo pipefail

TEST_NAME='helper-argv-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

agentkit="$root/agentkit"

# A rejection is judged by the message text, not the exit code: usage exits
# span 0/1/2 across the tree for unrelated reasons -- a subcommand-first
# helper (payload/precheck/read/...) shows its own usage for ANY unrecognized
# top-level token, --repo included, and still exits 0. This suite only asks
# "was the flag itself rejected as unrecognized", which every helper in this
# tree phrases as "Unknown argument: ..." or "Unknown option: ...".
assert_accepts_flag() {
    local file=$1 flag=$2 value=$3 out
    out=$(bash "$file" "$flag" "$value" --help 2>&1) || true
    if [[ $out == *[Uu]nknown\ argument* || $out == *[Uu]nknown\ option* ]]; then
        _fail "${file#"$agentkit"/} accepts $flag" "rejected -- $out"
    else
        _pass "${file#"$agentkit"/} accepts $flag"
    fi
}

# --- repository-slug helpers: canonical --repo -----------------------------
mapfile -t repo_flag_helpers < <(
    grep -lE -- '--repo\)|--repository\)|--repo=\*|--repository=\*' \
        "$agentkit"/skills/*/scripts/*.sh "$agentkit"/skills/.shared/scripts/*.sh 2>/dev/null | sort -u
)

min_repo_helpers=21
if ((${#repo_flag_helpers[@]} >= min_repo_helpers)); then
    _pass "enumerates >= $min_repo_helpers repository-slug helpers (found ${#repo_flag_helpers[@]})"
else
    _fail "enumerates >= $min_repo_helpers repository-slug helpers" \
        "found only ${#repo_flag_helpers[@]}: ${repo_flag_helpers[*]:-none}"
fi

for f in "${repo_flag_helpers[@]}"; do
    assert_accepts_flag "$f" --repo owner/repo
done

# --- checkout-path helpers: canonical --repo-root --------------------------
mapfile -t repo_root_flag_helpers < <(
    grep -lE -- '--repo-root\)|--dir\)|--repo-root=\*|--dir=\*' \
        "$agentkit"/skills/*/scripts/*.sh "$agentkit"/skills/.shared/scripts/*.sh 2>/dev/null | sort -u
)

min_repo_root_helpers=20
if ((${#repo_root_flag_helpers[@]} >= min_repo_root_helpers)); then
    _pass "enumerates >= $min_repo_root_helpers checkout-path helpers (found ${#repo_root_flag_helpers[@]})"
else
    _fail "enumerates >= $min_repo_root_helpers checkout-path helpers" \
        "found only ${#repo_root_flag_helpers[@]}: ${repo_root_flag_helpers[*]:-none}"
fi

for f in "${repo_root_flag_helpers[@]}"; do
    assert_accepts_flag "$f" --repo-root /tmp
done

# --- the regression this suite exists to catch -----------------------------
# A helper whose argv case statement recognizes ONLY the older spelling (no
# --repo/--repo-root branch at all) must fail assert_accepts_flag above, the
# same way move-github-project-item.sh and agent-run.sh did before #556 --
# pin that here with a throwaway fixture so a change that weakens
# assert_accepts_flag itself is caught too.
fixture_tmp=$(mktemp -d)
trap 'rm -rf -- "$fixture_tmp"' EXIT
cat > "$fixture_tmp/repository-only.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
    case $1 in
        --repository) shift 2 ;;
        -h|--help) echo usage; exit 0 ;;
        *) echo "Unknown argument: $1." >&2; exit 1 ;;
    esac
done
EOF
chmod +x "$fixture_tmp/repository-only.sh"
out=$(bash "$fixture_tmp/repository-only.sh" --repo owner/repo --help 2>&1) || true
assert_contains "$out" 'Unknown argument' \
    'a --repository-only fixture is caught as rejecting --repo (regression pin)'

finish
