#!/usr/bin/env bash
# materiality-check.sh -- may this diff take the documented-skip path instead of
# spending the one adversarial review?
#
# review-remote-pr already permits a documented skip when every changed line is
# mechanically verifiable; the draft loops never called it, so a +67/-2
# test-only PR paid the same review ceremony as an 875-line rewrite (issue #224
# WS2b). This helper answers the mechanical half deterministically: a diff is
# skip-eligible only when EVERY changed file is a test or documentation file.
# Anything else -- executable logic, workflow definitions, authorization,
# persistence, configuration -- is material and gets the full review. Judgment
# stays with the caller; this gate can only say "nothing here needs judgment".
#
# Prints one machine-readable line:
#   materiality= files=N verdict=skip-eligible|material [first-material=PATH]
# then, for skip-eligible, one oracle line to record in the receipt:
#   oracle=<why the skip is safe>
#
# EXIT CODES
#   0  verdict printed (either verdict -- the verdict is data, not an error)
#   2  usage error or unreadable evidence (fails closed: no verdict, no skip)
set -euo pipefail

readonly PROGRAM=${0##*/}

worktree=''
base=''

usage() {
    printf 'usage: %s --worktree PATH --base REF\n' "$PROGRAM" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --worktree)
            [[ -n ${2:-} ]] || die '--worktree requires a value'
            worktree=$2
            shift 2
            ;;
        --base)
            [[ -n ${2:-} ]] || die '--base requires a value'
            base=$2
            shift 2
            ;;
        -h | --help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n $worktree && -d $worktree ]] || die '--worktree must be an existing directory'
[[ -n $base ]] || die '--base is required'
[[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die '--base must be a safe ref name'

git -C "$worktree" rev-parse --verify --quiet "$base^{commit}" > /dev/null ||
    die "--base does not resolve to a commit: $base"

# --no-renames: with rename detection, src/x.sh moved to tests/test-x.sh
# reports only the destination path, and relocated executable code would read
# as a test-only diff. The source path staying in the list keeps it material.
changed=$(git -C "$worktree" diff --no-renames --name-only "$base...HEAD") ||
    die 'could not compute the changed-file list'

# A test file lives under a test root or carries a test-name shape; a docs file
# is prose. Both are exercised by their own oracle (the test suite; a docs
# render), which is what makes the skip DOCUMENTED rather than silent.
is_skip_eligible_path() {
    local path=$1 basename=${1##*/}
    case $path in
        tests/* | */tests/* | test/* | */test/* | spec/* | */spec/*) return 0 ;;
        docs/* | */docs/*) return 0 ;;
    esac
    case $basename in
        test_*.* | *_test.* | *.test.* | *.spec.*) return 0 ;;
        README | README.* | CHANGELOG | CHANGELOG.* | LICENSE | LICENSE.*) return 0 ;;
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
done <<< "$changed"

((count > 0)) || die 'the diff is empty; nothing to classify'

if [[ -n $first_material ]]; then
    printf 'materiality= files=%s verdict=material first-material=%s\n' \
        "$count" "$first_material"
else
    printf 'materiality= files=%s verdict=skip-eligible\n' "$count"
    printf 'oracle=path-mechanical: every changed file is under a test or documentation root, so no executable logic, workflow, authorization, or persistence surface changed; the caller records this classification as the skip reason\n'
fi
exit 0
