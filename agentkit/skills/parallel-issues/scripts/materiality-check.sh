#!/usr/bin/env bash
# materiality-check.sh -- may this diff take the documented-skip path instead of
# spending the one adversarial review?
#
# review-remote-pr already permits a documented skip when every changed line is
# mechanically verifiable; the draft loops never called it, so a +67/-2
# test-only PR paid the same review ceremony as an 875-line rewrite (issue #224
# WS2b). This helper answers the mechanical half deterministically: a diff is
# skip-eligible only when EVERY changed file is a test or documentation file
# and every issue-declared acceptance command has green evidence. Acceptance
# declarations come from --acceptance-file or the prepared worktree artifact;
# missing status is not-run and fails closed.
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
acceptance_file=''
acceptance_status_file=''

usage() {
    printf 'usage: %s (--worktree PATH|--repo-root PATH) --base REF [--acceptance-file PATH] [--acceptance-status-file PATH]\n' "$PROGRAM" >&2
    exit 2
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 2
}

while (($#)); do
    case $1 in
        --) shift; break ;;
        --worktree | --repo-root)
            [[ -n ${2:-} ]] || die "$1 requires a value"
            worktree=$2
            shift 2
            ;;
        --base)
            [[ -n ${2:-} ]] || die '--base requires a value'
            base=$2
            shift 2
            ;;
        --acceptance-file)
            [[ -n ${2:-} ]] || die '--acceptance-file requires a value'
            acceptance_file=$2
            shift 2
            ;;
        --acceptance-status-file)
            [[ -n ${2:-} ]] || die '--acceptance-status-file requires a value'
            acceptance_status_file=$2
            shift 2
            ;;
        -h | --help) usage ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ -n $worktree && -d $worktree ]] || die '--worktree must be an existing directory'
[[ -n $base ]] || die '--base is required'
[[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die '--base must be a safe ref name'

if [[ -z $acceptance_file && -f $worktree/.agent/acceptance.txt &&
    ! -L $worktree/.agent/acceptance.txt && -r $worktree/.agent/acceptance.txt ]]; then
    acceptance_file=$worktree/.agent/acceptance.txt
fi
if [[ -z $acceptance_status_file && -f $worktree/.agent/acceptance-status.txt &&
    ! -L $worktree/.agent/acceptance-status.txt && -r $worktree/.agent/acceptance-status.txt ]]; then
    acceptance_status_file=$worktree/.agent/acceptance-status.txt
fi
if [[ -n $acceptance_file ]]; then
    [[ -f $acceptance_file && ! -L $acceptance_file && -r $acceptance_file ]] ||
        die '--acceptance-file must be a readable regular file'
fi
if [[ -n $acceptance_status_file && -e $acceptance_status_file ]]; then
    [[ -f $acceptance_status_file && ! -L $acceptance_status_file && -r $acceptance_status_file ]] ||
        die '--acceptance-status-file must be a readable regular file'
fi

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
    # .agent is excluded workflow evidence, never a source diff to classify.
    [[ $path == .agent/* ]] && continue
    count=$((count + 1))
    if [[ -z $first_material ]] && ! is_skip_eligible_path "$path"; then
        first_material=$path
    fi
done <<< "$changed"

((count > 0)) || die 'the diff is empty; nothing to classify'

acceptance_records=()
if [[ -n $acceptance_file ]]; then
    while IFS= read -r command || [[ -n $command ]]; do
        command=${command#"${command%%[![:space:]]*}"}
        command=${command%"${command##*[![:space:]]}"}
        [[ -n $command ]] || continue
        [[ $command == acceptance=* ]] && command=${command#acceptance=}
        [[ $command != *[[:cntrl:]]* ]] || die 'acceptance declaration contains control characters'
        status=not-run
        if [[ -n $acceptance_status_file && -f $acceptance_status_file &&
            ! -L $acceptance_status_file && -r $acceptance_status_file ]]; then
            while IFS= read -r status_line || [[ -n $status_line ]]; do
                if [[ $status_line == "$command="* ]]; then
                    candidate=${status_line##*=}
                elif [[ $status_line == "acceptance=$command:"* ]]; then
                    candidate=${status_line##*:}
                else
                    continue
                fi
                case $candidate in
                    pass | fail | not-run) status=$candidate ;;
                esac
            done < "$acceptance_status_file"
        fi
        acceptance_records+=("acceptance=$command:$status")
        if [[ $status != pass ]]; then
            # Report the first blocked declaration, not merely the first
            # declaration in the file. A passing command followed by a failed
            # one must name the failure that made this otherwise mechanical
            # diff material.
            [[ -n $first_material ]] || first_material="acceptance=$command:$status"
        fi
    done < "$acceptance_file"
fi

acceptance_summary=''
if ((${#acceptance_records[@]})); then
    acceptance_summary=$(IFS=,; printf '%s' "${acceptance_records[*]}")
fi
if [[ -n $first_material ]]; then
    printf 'materiality= files=%s verdict=material first-material=%s\n' \
        "$count" "$first_material"
else
    printf 'materiality= files=%s verdict=skip-eligible\n' "$count"
    printf 'oracle=path-mechanical: every changed file is under a test or documentation root, so no executable logic, workflow, authorization, or persistence surface changed; the caller records this classification as the skip reason\n'
fi
[[ -z $acceptance_summary ]] || printf '%s\n' "$acceptance_summary"
exit 0
