#!/usr/bin/env bash
# materiality-check.sh -- classify the current PR diff and emit the exact
# consent payload that a skip receipt covers.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly SLUG_RE='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
readonly PR_RE='^[1-9][0-9]*$'

worktree=''
base=''
repo=''
pr=''

usage() {
    printf 'usage: %s --worktree PATH --base REF --repo OWNER/NAME --pr N\n' "$PROGRAM" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --worktree|--repo-root)
            [[ -n ${2:-} ]] || die "$1 requires a value"
            worktree=$2
            shift 2
            ;;
        --base)
            [[ -n ${2:-} ]] || die '--base requires a value'
            base=$2
            shift 2
            ;;
        --repo)
            [[ -n ${2:-} ]] || die '--repo requires a value'
            repo=$2
            shift 2
            ;;
        --pr)
            [[ -n ${2:-} ]] || die '--pr requires a value'
            pr=$2
            shift 2
            ;;
        -h|--help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n $worktree && -d $worktree && ! -L $worktree && -O $worktree ]] ||
    die '--worktree must be an owned, non-symlink directory'
[[ -n $base ]] || die '--base is required'
git -C "$worktree" check-ref-format --branch "$base" >/dev/null 2>&1 ||
    die '--base must be a safe branch name'
[[ $repo =~ $SLUG_RE ]] || die '--repo must be OWNER/NAME using safe characters'
[[ $pr =~ $PR_RE ]] || die '--pr must be a positive integer'

# consent-record.sh renders origin/$base after refreshing it. Mirror that
# refresh whenever this is a normal remote-backed worktree; local-only
# fixtures have no origin and use the supplied base without weakening the
# production path.
diff_base=$base
fetch_base=$base
if [[ $fetch_base == origin/* ]]; then
    fetch_base=${fetch_base#origin/}
fi
if git -C "$worktree" remote get-url origin >/dev/null 2>&1; then
    git -C "$worktree" fetch --quiet origin "$fetch_base" ||
        die "could not refresh origin/$fetch_base before rendering the diff"
    diff_base="origin/$fetch_base"
fi

git -C "$worktree" rev-parse --verify --quiet "$diff_base^{commit}" >/dev/null ||
    die "--base does not resolve to a commit: $base"

changed=$(git -C "$worktree" diff --no-renames --name-only "$diff_base...HEAD") ||
    die 'could not compute the changed-file list'
canonical_file=$(mktemp "${TMPDIR:-/tmp}/materiality-diff.XXXXXXXXXX") ||
    die 'could not create a temporary file for the canonical diff'
trap 'rm -f -- "$canonical_file"' EXIT
git -C "$worktree" diff --no-renames --binary "$diff_base...HEAD" >"$canonical_file" ||
    die 'could not render the canonical diff'
[[ -s $canonical_file ]] || die 'the diff is empty; nothing to classify'
grep -q '[^[:space:]]' -- "$canonical_file" || die 'the diff is empty; nothing to classify'
digest=$(sha256sum -- "$canonical_file" | awk '{print $1}') ||
    die 'could not hash the canonical diff'
[[ $digest =~ ^[[:xdigit:]]{64}$ ]] || die 'sha256sum returned an invalid digest'
payload="$repo:$pr:$digest"

is_skip_eligible_path() {
    local path=$1 basename=${1##*/}
    case $path in
        tests/*|*/tests/*|test/*|*/test/*|spec/*|*/spec/*|docs/*|*/docs/*) return 0 ;;
    esac
    case $basename in
        test_*.*|*_test.*|*.test.*|*.spec.*|README|README.*|CHANGELOG|CHANGELOG.*|LICENSE|LICENSE.*)
            return 0
            ;;
    esac
    return 1
}

count=0
first_material=''
while IFS= read -r path; do
    [[ -n $path ]] || continue
    count=$((count + 1))
    if [[ -z $first_material ]] && ! is_skip_eligible_path "$path"; then
        first_material=$path
    fi
done <<<"$changed"
((count > 0)) || die 'the diff is empty; nothing to classify'

if [[ -n $first_material ]]; then
    printf 'materiality= files=%s verdict=material first-material=%s\n' "$count" "$first_material"
else
    printf 'materiality= files=%s verdict=skip-eligible\n' "$count"
    printf 'oracle=path-mechanical: every changed file is under a test or documentation root; diff-payload=%s\n' "$payload"
fi
printf 'diff-payload=%s\n' "$payload"
