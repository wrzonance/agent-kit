#!/usr/bin/env bash
# Fetches a GitHub issue exactly once, fails closed unless it carries real
# evidence, renders it into the canonical Title/Body/Labels/Comments spec
# text, fences (or copies) it alongside a prior-art digest per the caller's
# trust boundary, and publishes both plus a readiness marker atomically into
# the target worktree's excluded .agent/ state.
#
# This is the single source of truth for the "Root canonical issue fetch and
# fence preparation" recipe in parallel-issues/SKILL.md. Boundary-mode
# SELECTION (public-fenced vs private-trusted vs yolo-trusted) happens
# upstream of this script -- it only consumes the mode it is given.
set -euo pipefail
# fetched-issue.json is explicitly chmod'd 0600, but the spec/prior-art pair
# (fenced-spec.txt + fenced-prior-art.txt in public-fenced mode, or the
# mode-neutral spec.txt + prior-art.txt otherwise) are created by plain
# redirection (fence-untrusted-data.sh output, or a straight cp) and then
# mv'd into place -- without this, they land world-readable under the default
# umask while the byte-equivalent raw payload next to them does not. All
# three carry the same issue text.
umask 077

usage() {
    printf 'Usage: %s --worktree PATH --issue N --boundary MODE [--prior-art FILE] [--resume]\n' "${0##*/}"
    cat <<'EOF'

Options:
  --worktree PATH   Git worktree root; artifacts are written under its
                    .agent/ directory.
  --issue N         Issue number to fetch (positive integer).
  --boundary MODE   One of:
                      public-fenced    - wrap both artifacts in nonce-bound
                                          untrusted-data markers; published as
                                          fenced-spec.txt / fenced-prior-art.txt.
                      private-trusted  - copy bytes verbatim (no fencing);
                                          published as mode-neutral
                                          spec.txt / prior-art.txt so the
                                          filename never asserts a fence that
                                          does not exist.
                      yolo-trusted     - copy bytes verbatim (no fencing);
                                          published as mode-neutral
                                          spec.txt / prior-art.txt, same as
                                          private-trusted.
  --prior-art FILE  File holding prior-art digest text. Defaults to the
                    literal "(no prior art selected by triage digest)".
  --resume          Archive existing generated artifacts and regenerate them
                    while preserving all other worktree contents.
  -h, --help        Print this help and exit 0.

Published on success (stdout, one line per artifact). The spec/prior-art
filenames depend on --boundary:
  published: <worktree>/.agent/fetched-issue.json
  published: <worktree>/.agent/fenced-spec.txt        (public-fenced only)
  published: <worktree>/.agent/fenced-prior-art.txt    (public-fenced only)
  published: <worktree>/.agent/spec.txt                (private-trusted, yolo-trusted)
  published: <worktree>/.agent/prior-art.txt           (private-trusted, yolo-trusted)
  published: <worktree>/.agent/acceptance.txt          (all modes; one command per line)
  published: <worktree>/.agent/fenced-ready

Exit status:
  0   success
  12  a complete fenced artifact set already exists; delete it deliberately
      before re-fencing
  1   bad arguments, missing evidence, or any other failure
EOF
}

die() {
    printf 'prepare-issue-artifacts: %s\n' "$1" >&2
    exit "${2:-1}"
}

worktree=
issue_number=
boundary_mode=
prior_art_file=
resume=0

while (($#)); do
    case $1 in
        --) shift; (( $# == 0 )) || { printf "%s: unexpected argument after --: %s\n" "${0##*/}" "$1" >&2; exit 2; }; break ;;
        --worktree)
            (($# >= 2)) || die "Missing value for $1."
            worktree=$2
            shift 2
            ;;
        --issue)
            (($# >= 2)) || die "Missing value for $1."
            issue_number=$2
            shift 2
            ;;
        --boundary)
            (($# >= 2)) || die "Missing value for $1."
            boundary_mode=$2
            shift 2
            ;;
        --prior-art)
            (($# >= 2)) || die "Missing value for $1."
            prior_art_file=$2
            shift 2
            ;;
        --resume)
            resume=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown argument: $1."
            ;;
    esac
done

[[ -n $worktree ]] || die 'Missing required --worktree.'
[[ -d $worktree ]] || die "Worktree is not a directory: $worktree"
[[ $issue_number =~ ^[1-9][0-9]*$ ]] || die 'Issue number must be a positive integer (--issue N).'
case $boundary_mode in
    public-fenced | private-trusted | yolo-trusted) ;;
    *)
        die "Boundary mode must be one of: public-fenced, private-trusted, yolo-trusted (got: '${boundary_mode:-}')."
        ;;
esac

prior_art_contents=
if [[ -n $prior_art_file ]]; then
    [[ -f $prior_art_file && ! -L $prior_art_file && -r $prior_art_file ]] ||
        die "Prior-art file is missing, unreadable, or a symlink: $prior_art_file"
    # Deliberately NOT read into a variable here. Command substitution strips
    # every trailing newline, so a digest ending in the blank line that
    # terminates a Markdown block would be published without it -- a silent
    # edit to content the trusted boundary modes promise to copy verbatim. The
    # file is staged byte-for-byte further down instead.
fi

command -v jq >/dev/null 2>&1 || die 'jq is not installed; evidence unavailable'

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd) ||
    die "Could not resolve this script's directory."
fence_script="$script_dir/fence-untrusted-data.sh"
[[ -x $fence_script ]] || die "fence-untrusted-data.sh is missing or not executable: $fence_script"

# A symlinked or non-directory .agent would let mkdir -p silently succeed
# while every later write lands somewhere outside the worktree.
agent_dir="$worktree/.agent"
if [[ -e $agent_dir ]] && { [[ -L $agent_dir ]] || [[ ! -d $agent_dir ]]; }; then
    die "$agent_dir exists and is not a plain directory"
fi
mkdir -p -- "$agent_dir" || die "Could not create $agent_dir"

issue_payload_file="$agent_dir/fetched-issue.json"
# The published filename itself must never assert a fence that does not
# exist (issue #334): only public-fenced actually wraps the bytes in
# nonce-bound markers, so only public-fenced keeps the fenced-* name.
# private-trusted and yolo-trusted copy bytes verbatim and publish under the
# mode-neutral spec.txt / prior-art.txt names instead.
case $boundary_mode in
    public-fenced)
        target="$agent_dir/fenced-spec.txt"
        prior_target="$agent_dir/fenced-prior-art.txt"
        ;;
    private-trusted | yolo-trusted)
        target="$agent_dir/spec.txt"
        prior_target="$agent_dir/prior-art.txt"
        ;;
esac
ready_marker="$agent_dir/fenced-ready"
tmp="$target.tmp"
prior_tmp="$prior_target.tmp"
acceptance_target="$agent_dir/acceptance.txt"
acceptance_tmp="$acceptance_target.tmp"

resume_untracked=0
resume_modified=0
resume_history_dir=

count_preserved_worktree_state() {
    local status_line status_code
    if ! git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        return 0
    fi
    while IFS= read -r status_line; do
        [[ -n $status_line ]] || continue
        status_code=${status_line:0:2}
        if [[ $status_code == '??' ]]; then
            resume_untracked=$((resume_untracked + 1))
        elif [[ $status_code != '!!' ]]; then
            resume_modified=$((resume_modified + 1))
        fi
    done < <(git -C "$worktree" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)
}

print_resume_command() {
    local script_path=$1
    printf 'resume command:' >&2
    printf ' %q' "$script_path" --resume --worktree "$worktree" --issue "$issue_number" \
        --boundary "$boundary_mode" >&2
    [[ -z $prior_art_file ]] || printf ' %q %q' --prior-art "$prior_art_file" >&2
    printf '\n' >&2
}

archive_existing_artifacts() {
    local artifact history_root timestamp basename
    local -a artifacts=(
        "$issue_payload_file"
        "$agent_dir/fenced-spec.txt"
        "$agent_dir/fenced-prior-art.txt"
        "$agent_dir/spec.txt"
        "$agent_dir/prior-art.txt"
        "$acceptance_target"
        "$ready_marker"
    )
    for artifact in "${artifacts[@]}"; do
        if [[ -e $artifact || -L $artifact ]]; then
            if [[ -z $resume_history_dir ]]; then
                history_root="$agent_dir/evidence/fence-history"
                if [[ -L "$agent_dir/evidence" ||
                    (-e "$agent_dir/evidence" && ! -d "$agent_dir/evidence") ]]; then
                    die "$agent_dir/evidence exists and is not a plain directory"
                fi
                if [[ -L "$history_root" ||
                    (-e "$history_root" && ! -d "$history_root") ]]; then
                    die "$history_root exists and is not a plain directory"
                fi
                mkdir -p -- "$history_root" || die "Could not create $history_root"
                timestamp=$(date -u +%Y%m%dT%H%M%SZ) || die 'Could not generate fence history timestamp'
                resume_history_dir=$(mktemp -d "$history_root/${timestamp}.XXXXXX") ||
                    die "Could not create a fence history directory under $history_root"
                chmod 700 -- "$resume_history_dir" || die 'Could not secure the fence history directory'
            fi
            basename=${artifact##*/}
            mv -f -- "$artifact" "$resume_history_dir/$basename" ||
                die "Could not archive $artifact under $resume_history_dir"
        fi
    done
    [[ -z $resume_history_dir ]] || printf 'archived: %s\n' "$resume_history_dir"
}

# Persisted acceptance declarations are data only. Keep the parser before the
# complete-artifact refusal so an interrupted run that published the spec but
# not acceptance.txt can recover that missing member without refetching the
# issue and clobbering the existing evidence.
extract_acceptance_to_file() {
    local file=$1 output=$2
    local heading_re='^(#{1,6})[[:space:]]+'
    local acceptance_re='^#{1,6}[[:space:]]*(acceptance|verification|verify)'
    local fence_re='^[[:space:]]*(```|~~~)'
    local item_re='^[[:space:]]*([0-9]+[.)]|[-*+])[[:space:]]+'
    local marker_re='^([0-9]+[.)]|[-*+]|\$)[[:space:]]+'
    local line candidate item level in_section=0 in_fence=0 section_level=0 in_comments=0 seen_labels=0
    : > "$output"
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*Labels:[[:space:]]*$ ]]; then
            seen_labels=1
        elif ((seen_labels)) && [[ $line =~ ^[[:space:]]*Comments:[[:space:]]*$ ]]; then
            in_comments=1
        fi
        if ((in_fence == 0 && in_comments == 0)) &&
            [[ $line =~ ^[[:space:]]*AGENT_ACCEPTANCE_CMD[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            candidate=${BASH_REMATCH[1]}
            case $candidate in
                \"*\") candidate=${candidate:1:${#candidate}-2} ;;
                \'*\') candidate=${candidate:1:${#candidate}-2} ;;
            esac
            candidate=${candidate#"${candidate%%[![:space:]]*}"}
            candidate=${candidate%"${candidate##*[![:space:]]}"}
            [[ -n $candidate && $candidate != *[[:cntrl:]]* ]] || continue
            [[ $candidate =~ ^[A-Za-z0-9_./:=\ -]{1,120}$ ]] || continue
            grep -Fqx -- "$candidate" "$output" 2>/dev/null || printf '%s\n' "$candidate" >> "$output"
        fi
        if [[ $line =~ $fence_re ]]; then
            in_fence=$((1 - in_fence))
            continue
        fi
        if ((in_fence == 0)) && [[ $line =~ $heading_re ]]; then
            level=${#BASH_REMATCH[1]}
            if [[ ${line,,} =~ $acceptance_re ]]; then
                in_section=1
                section_level=$level
            elif ((in_section)) && ((level <= section_level)); then
                in_section=0
            fi
            continue
        fi
        ((in_section)) || continue
        candidate=''
        if ((in_fence)); then
            candidate=${line#"${line%%[![:space:]]*}"}
            [[ -n $candidate && $candidate != \#* ]] || continue
            if [[ $candidate =~ $marker_re ]]; then
                candidate=${candidate#"${BASH_REMATCH[0]}"}
            fi
        else
            [[ $line =~ $item_re ]] || continue
            item=${line#"${BASH_REMATCH[0]}"}
            [[ $item == '`'* ]] || continue
            candidate=${item#\`}
            candidate=${candidate%%\`*}
        fi
        candidate=${candidate#"${candidate%%[![:space:]]*}"}
        candidate=${candidate%"${candidate##*[![:space:]]}"}
        [[ -n $candidate && $candidate != *[[:cntrl:]]* ]] || continue
        [[ $candidate =~ ^[A-Za-z0-9_./:=\ -]{1,120}$ ]] || continue
        grep -Fqx -- "$candidate" "$output" 2>/dev/null || printf '%s\n' "$candidate" >> "$output"
    done < "$file"
}

# Refused BEFORE the fetch. A complete, ready-marked set is deliberate state,
# and fetched-issue.json is part of that set -- checking only after the fetch
# meant a run that was about to refuse had already overwritten the published
# raw payload the previous run left behind, and had spent two gh calls doing
# it. The stale-debris cleanup stays below, where the run actually continues,
# so a failed fetch still leaves the previous artifacts untouched.
if ((resume)); then
    count_preserved_worktree_state
    printf 'preserved: untracked=%d modified=%d\n' "$resume_untracked" "$resume_modified"
    archive_existing_artifacts
elif [[ -d $ready_marker && -f $target && -f $prior_target &&
    ! -e $tmp && ! -e $prior_tmp && ! -e $acceptance_tmp ]]; then
    if [[ -f $acceptance_target ]]; then
        print_resume_command "$script_dir/prepare-issue-artifacts.sh"
        die 'fence artifacts already exist; delete the affected file deliberately before re-fencing' 12
    fi
    # Recover only the missing derived acceptance artifact. The source target
    # and readiness marker prove the issue fetch is complete, so no gh call is
    # permitted on this path.
    extract_acceptance_to_file "$target" "$acceptance_tmp" ||
        die 'could not recover the missing acceptance artifact' 1
    chmod 600 -- "$acceptance_tmp" || die 'could not set permissions on the recovered acceptance artifact'
    mv -f -- "$acceptance_tmp" "$acceptance_target" || die 'could not publish the recovered acceptance artifact'
    print_resume_command "$script_dir/prepare-issue-artifacts.sh"
    die 'fence artifacts already exist; delete the affected file deliberately before re-fencing' 12
fi

# Every temp file this run might create, so a normal exit or a signal cleans
# up exactly what it left behind and nothing else. The EXIT trap always runs;
# the signal traps additionally force a nonzero exit rather than letting the
# script resume past a HUP/INT/TERM.
issue_payload_tmp=
spec_payload=
prior_payload=

cleanup_temp_files() {
    [[ -z $issue_payload_tmp ]] || rm -f -- "$issue_payload_tmp"
    rm -f -- "$tmp" "$prior_tmp" "$acceptance_tmp"
    [[ -z $spec_payload ]] || rm -f -- "$spec_payload"
    [[ -z $prior_payload ]] || rm -f -- "$prior_payload"
}
temp_signal_handler() {
    cleanup_temp_files
    trap - EXIT HUP INT TERM
    exit 1
}
trap cleanup_temp_files EXIT
trap temp_signal_handler HUP INT TERM

# Resolved from the target worktree, never from the caller's cwd -- otherwise
# invoking this from a different repository's directory would silently fetch
# issue $issue_number from that OTHER repository and publish it as this
# worktree's spec.
repo_slug=$(cd -- "$worktree" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) ||
    die "Could not resolve the repository from gh in $worktree"

issue_payload=$(gh issue view "$issue_number" --repo "$repo_slug" --json title,body,labels,comments) || exit 1

# Persist the raw fetched bytes before any evidence parser runs, atomically:
# a temp file in the same directory, chmod'd private, then moved into place.
issue_payload_tmp=$(mktemp "$agent_dir/.fetched-issue.XXXXXX") ||
    die 'Could not create a temporary file for the raw issue payload.'
chmod 600 -- "$issue_payload_tmp" ||
    die 'Could not set permissions on the raw issue payload temp file.'
printf '%s\n' "$issue_payload" >"$issue_payload_tmp" ||
    die 'Could not write the raw issue payload.'
mv -f -- "$issue_payload_tmp" "$issue_payload_file" ||
    die "Could not publish $issue_payload_file"
issue_payload_tmp=

issue_has_content=$(jq -r '
  ((.title // "") != "") or ((.body // "") != "")
    or (((.labels // []) | length) > 0) or (((.comments // []) | length) > 0)
' <<<"$issue_payload")

# Empty evidence is acceptable only after jq has run successfully and proved
# the payload fields are empty; a missing parser is a blocked check.
if [[ $issue_has_content != true ]]; then
    printf 'prepare-issue-artifacts: issue #%s has no title, body, labels, or comments; evidence unavailable\n' \
        "$issue_number" >&2
    exit 1
fi

issue_contents=$(jq -r '
  [
    ("Title: " + (.title // "")),
    ("Body:\n" + (.body // "")),
    ("Labels:\n" + ((.labels // []) | map(.name) | join(", "))),
    ("Comments:\n" + ((.comments // [])
      | map("- " + ((.author.login // "unknown") | tostring) + ": " + (.body // ""))
      | join("\n")))
  ] | join("\n\n")
' <<<"$issue_payload")

: "${prior_art_contents:="(no prior art selected by triage digest)"}"

# The complete, ready-marked case was already refused before the fetch, so
# anything still present here is stale debris from an interrupted run and is
# cleared before this run republishes both members.
if [[ -e $ready_marker || -e $target || -e $prior_target || -e $acceptance_target ||
    -e $tmp || -e $prior_tmp || -e $acceptance_tmp ]]; then
    printf 'incomplete stale fence artifacts; removing them before retry\n' >&2
    rm -f -- "$target" "$prior_target" "$acceptance_target" "$tmp" "$prior_tmp" "$acceptance_tmp"
    rmdir -- "$ready_marker" 2>/dev/null || rm -f -- "$ready_marker"
fi

# Staged outside the worktree so a fence producer is always fed by stdin
# redirection, never a pipe: a pipe writer that outlives an early-exiting
# reader hits SIGPIPE, which this recipe must survive deterministically.
spec_payload=$(mktemp "${TMPDIR:-/tmp}/prepare-issue-artifacts-spec.XXXXXXXXXX") ||
    die 'Could not create a temporary spec payload file.'
prior_payload=$(mktemp "${TMPDIR:-/tmp}/prepare-issue-artifacts-prior.XXXXXXXXXX") ||
    die 'Could not create a temporary prior-art payload file.'
chmod 600 -- "$spec_payload" "$prior_payload" ||
    die 'Could not set permissions on the temporary payload files.'

printf '%s' "$issue_contents" >"$spec_payload" ||
    die 'Could not stage the spec payload.'
extract_acceptance_to_file "$spec_payload" "$acceptance_tmp" ||
    die 'Could not extract the issue acceptance commands.'
if [[ -n $prior_art_file ]]; then
    cp -- "$prior_art_file" "$prior_payload" ||
        die 'Could not stage the prior-art payload.'
    chmod 600 -- "$prior_payload" ||
        die 'Could not set permissions on the prior-art payload.'
else
    printf '%s' "$prior_art_contents" >"$prior_payload" ||
        die 'Could not stage the prior-art payload.'
fi

if [[ $boundary_mode == public-fenced ]]; then
    if "$fence_script" <"$spec_payload" >"$tmp" &&
        "$fence_script" <"$prior_payload" >"$prior_tmp"; then
        :
    else
        rm -f -- "$target" "$prior_target" "$tmp" "$prior_tmp"
        die 'Could not fence the issue-derived artifacts.'
    fi
else
    if cp -- "$spec_payload" "$tmp" && cp -- "$prior_payload" "$prior_tmp"; then
        :
    else
        rm -f -- "$target" "$prior_target" "$tmp" "$prior_tmp"
        die 'Could not copy the issue-derived artifacts.'
    fi
fi

# Published one step at a time so the failure can name WHICH member did not
# land. The trio is not atomic: fenced-spec.txt can be published without its
# prior-art pair and without the readiness marker, and "mv/mkdir failed" would
# leave the caller to work out which of the three that was.
publish_rc=0
publish_step=''
mv -f -- "$tmp" "$target" ||
    { publish_rc=$?; publish_step="publish $target"; }
if ((publish_rc == 0)); then
    mv -f -- "$prior_tmp" "$prior_target" ||
        { publish_rc=$?; publish_step="publish $prior_target"; }
fi
if ((publish_rc == 0)); then
    mv -f -- "$acceptance_tmp" "$acceptance_target" ||
        { publish_rc=$?; publish_step="publish $acceptance_target"; }
fi
if ((publish_rc == 0)); then
    mkdir -- "$ready_marker" ||
        { publish_rc=$?; publish_step="create the readiness marker $ready_marker"; }
fi
if ((publish_rc != 0)); then
    rm -f -- "$tmp" "$prior_tmp" "$acceptance_tmp"
    printf 'Could not %s (exit %s); the fenced artifact set is incomplete.\n' \
        "$publish_step" "$publish_rc" >&2
    exit "$publish_rc"
fi

rm -f -- "$spec_payload" "$prior_payload" || die 'Could not remove the temporary payload files.'
spec_payload=
prior_payload=

trap - EXIT HUP INT TERM

printf 'published: %s\n' "$issue_payload_file"
printf 'published: %s\n' "$target"
printf 'published: %s\n' "$prior_target"
printf 'published: %s\n' "$acceptance_target"
printf 'published: %s\n' "$ready_marker"
