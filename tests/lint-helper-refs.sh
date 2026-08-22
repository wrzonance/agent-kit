#!/usr/bin/env bash
# Verify that skill prose points at files that actually ship with the plugin.
set -euo pipefail

program=${0##*/}
skills_dir=${1:?usage: lint-helper-refs.sh SKILLS_DIR}
[[ -d $skills_dir ]] || { printf '%s: skills directory is missing: %s\n' "$program" "$skills_dir" >&2; exit 2; }
skills_dir=$(cd -- "$skills_dir" && pwd -P)
plugin_dir=$(cd -- "$skills_dir/.." && pwd -P)
repo_dir=$(cd -- "$plugin_dir/.." && pwd -P)

violations=0
declare -A seen=()

# A markdown-link bracket TEXT counts as a path claim only when it is an
# unformatted token: the same character set every other extraction loop in
# this file already restricts itself to, with no interior whitespace or
# markdown markup. This tells "the policy.md" (prose that happens to end in
# .md) apart from "policy.md" (a path). A backtick-quoted label such as
# "`policy.md`" is excluded the same way check_token already excludes any
# other token with a trailing non-path character: it ends in a backtick, not
# in .sh/.md.
# shellcheck disable=SC2016  # the regex intentionally matches literal $ names
readonly bracket_path_token_re='^[[:alnum:]_.${}/-]+\.(sh|md)(#[[:alnum:]_.${}/-]*)?$'

report() {
    local kind=${5:-helper/reference path}
    printf 'VIOLATION %s:%s: unresolved %s %s (looked for %s)\n' \
        "$1" "$2" "$kind" "$3" "$4" >&2
    violations=$((violations + 1))
}

placement_report() {
    printf 'VIOLATION %s: helper scripts must live in .shared/scripts/ or a skill scripts/ directory; found %s\n' \
        "$program" "$1" >&2
    violations=$((violations + 1))
}

resolve_relative() {
    local source_file=$1 token=$2 source_dir
    source_dir=$(dirname -- "$source_file")
    realpath -m -- "$source_dir/$token"
}

skill_root_for() {
    local source_file=$1 relative skill_name
    relative=${source_file#"$skills_dir/"}
    skill_name=${relative%%/*}
    printf '%s\n' "$skills_dir/$skill_name"
}

resolve_token() {
    local source_file=$1 token=$2
    case $token in
        "\$agentkit/"*) printf '%s\n' "$skills_dir/${token#\$agentkit/}" ;;
        "\$shared/"*) printf '%s\n' "$skills_dir/.shared/scripts/${token#\$shared/}" ;;
        agentkit/*) printf '%s\n' "$plugin_dir/${token#agentkit/}" ;;
        skills/*)
            # Installed plugin prose uses skills/ relative to the plugin root;
            # accepting the repository-root spelling too keeps fixture paths
            # unambiguous when the lint is run against a bare skills directory.
            local installed=$plugin_dir/$token repository=$repo_dir/$token
            if [[ -e $installed || -L $installed ]]; then
                printf '%s\n' "$installed"
            else
                printf '%s\n' "$repository"
            fi
            ;;
        .shared/*) printf '%s\n' "$skills_dir/$token" ;;
        scripts/*|references/*) printf '%s\n' "$(skill_root_for "$source_file")/$token" ;;
        review-remote-pr/*|parallel-issues/*|onboard-repo/*) printf '%s\n' "$skills_dir/$token" ;;
        *) resolve_relative "$source_file" "$token" ;;
    esac
}

check_token() {
    local source_file=$1 line_no=$2 token=$3 kind=${4:-helper/reference path} candidate key
    [[ -n $token ]] || return 0
    # Markdown destinations may carry an anchor; it is not part of the file.
    token=${token%%#*}
    [[ $token == *.sh || $token == *.md ]] || return 0
    key="$source_file:$line_no:$token"
    [[ -n ${seen[$key]:-} ]] && return 0
    seen[$key]=1
    candidate=$(resolve_token "$source_file" "$token")
    [[ -f $candidate ]] || report "$source_file" "$line_no" "$token" "$candidate" "$kind"
}

scan_file() {
    local source_file=$1 line_no content match token bracket_text dest_token
    while IFS=: read -r line_no content; do
        # Markdown link destinations are resolved from the document
        # containing the link. This extraction is deliberately
        # label-independent -- it anchors on `](` rather than on the opening
        # `[`, so a label containing an escaped `]` (e.g.
        # `[policy \] archive](dest)`) still gets its destination checked;
        # pairing the whole `[label](` would let that label swallow the `]`
        # and make the entire link invisible to this loop.
        while IFS= read -r match; do
            dest_token=${match#*](}
            check_token "$source_file" "$line_no" "$dest_token" 'link destination'
        done < <(grep -oE '\]\([^)#[:space:]]+\.(sh|md)(#[^)]*)?' <<< "$content" || true)

        # Bracket TEXT holds the same resolve-or-fail bar as the
        # destination: these documents are read by agents, not rendered for
        # humans, and an agent following prose frequently retypes the path
        # it sees rather than dereferencing the link. Extracted as its own
        # pass, rather than reusing the destination match above, precisely
        # because pairing `[label](` requires the label to contain no
        # literal `]` -- a label with an escaped `]` is silently skipped
        # here without losing the destination check above. Only an
        # unformatted path token is validated; see bracket_path_token_re.
        while IFS= read -r match; do
            bracket_text=${match%%](*}
            bracket_text=${bracket_text#\[}
            [[ $bracket_text =~ $bracket_path_token_re ]] || continue
            check_token "$source_file" "$line_no" "$bracket_text" 'link bracket text'
        done < <(grep -oE '\[[^]]*\]\([^)#[:space:]]+\.(sh|md)(#[^)]*)?' <<< "$content" || true)

        # Shell snippets and prose that name the installed tree use one of the
        # explicit roots below. Bare helper basenames are intentionally ignored:
        # they have no deterministic location to validate.
        # shellcheck disable=SC2016  # the regex intentionally matches literal $ names
        while IFS= read -r token; do
            check_token "$source_file" "$line_no" "$token"
        done < <(grep -oE '(\$agentkit|\$shared|agentkit|skills|\.shared)/[[:alnum:]_.${}/-]+\.(sh|md)' <<< "$content" || true)

        # Unqualified skill-relative paths are valid when they start at a
        # documented boundary. The leading boundary prevents matching the
        # `references/` suffix of a cross-skill path already handled above.
        if [[ $content != *']('* ]]; then
            # shellcheck disable=SC2016  # the regex intentionally matches literal path syntax
            while IFS= read -r token; do
                if [[ $token != scripts/* && $token != references/* &&
                    $token != review-remote-pr/* && $token != parallel-issues/* &&
                    $token != onboard-repo/* ]]; then
                    token=${token:1}
                fi
                check_token "$source_file" "$line_no" "$token"
            done < <(grep -oE '(^|[^[:alnum:]_./-])((scripts|references|review-remote-pr|parallel-issues|onboard-repo)/[[:alnum:]_.${}/-]+\.(sh|md))' <<< "$content" || true)
        fi

        # Relative references such as ../.shared/foo.md are not covered by the
        # root-prefixed expression above, but are deterministic from this file.
        # shellcheck disable=SC2016  # the regex intentionally matches literal $ names
        while IFS= read -r token; do
            check_token "$source_file" "$line_no" "$token"
        done < <(grep -oE '(\.\./)+\.shared/[[:alnum:]_.${}/-]+\.(sh|md)' <<< "$content" || true)
    done < <(grep -nE '\.(sh|md)' "$source_file" || true)
}

shopt -s nullglob
for helper in "$skills_dir/.shared"/*.sh; do
    [[ -e $helper || -L $helper ]] || continue
    placement_report "$helper"
done

# The reference manifest joins the scanned set: every path it names is a
# promise an agent will follow without searching, so it holds the same
# resolve-or-fail bar as a link in the prose that sends the agent there.
mapfile -t documents < <(
    find "$skills_dir" -type f \( \
        -name 'SKILL.md' -o \
        -path '*/references/*.md' -o \
        -name '*prompt*.md' -o \
        -path "$skills_dir/.shared/*.md" -o \
        -path "$skills_dir/references.md" \
    \) -print | sort
)
for document in "${documents[@]}"; do
    scan_file "$document"
done

if ((violations)); then
    printf '%s: %d violation(s)\n' "$program" "$violations" >&2
    exit 1
fi
printf '%s: %d documents checked, helper/reference paths resolve\n' \
    "$program" "${#documents[@]}"
