#!/usr/bin/env bash
# Static collation scan (issue #846). Shell `sort` and `comm` order by the
# CALLER's locale, so an unpinned call makes a helper emit different bytes on a
# UTF-8 desktop than on a C.UTF-8 runner -- and `comm` silently misreports when
# its two inputs were ordered under different collations. Evidence, fingerprints
# and set comparisons have to be byte-stable across machines, so every shell
# `sort`/`comm` in the shipped tree pins `LC_ALL=C` (or `LC_COLLATE=C`) on the
# invocation itself.
#
# Known blind spots, accepted because closing them needs a real shell parser and
# nothing in the tree hits them today:
#   * a `sort` inside a single-quoted child program (`bash -c 'sort f'`) is not
#     seen -- single-quoted spans are dropped so that jq's own locale-independent
#     `sort`/`sort_by` never reports;
#   * a `sort` inside a heredoc piped into a shell (`bash <<EOF`) is not seen --
#     heredoc bodies are recipe prose here, and their apostrophes would otherwise
#     desync quote tracking for the rest of the file.
set -euo pipefail

root=${1:-}
if [[ -z $root || $root == -h || $root == --help ]]; then
    printf 'Usage: %s HELPER_ROOT\n' "${0##*/}" >&2
    exit 2
fi
[[ -d $root ]] || {
    printf '%s: helper root is not a directory: %s\n' "${0##*/}" "$root" >&2
    exit 2
}

rc=0
while IFS= read -r file; do
    awk -v file="$file" '
        function report(reason) {
            printf "%s:%d: %s\n", file, NR, reason
            bad = 1
        }
        # Drop quoted regions, tracking the state across lines. Single-quoted
        # spans hold jq programs, whose `| sort` is not a shell call;
        # double-quoted spans hold prose and expansions, and a documented
        # pipeline inside one ("cat f | sort") is not an invocation either. An
        # apostrophe inside a double-quoted span -- "doesn\x27t" -- must not open
        # a quote, or every later line in the file is misread.
        function shell_code(line,   out, i, ch) {
            out = ""
            for (i = 1; i <= length(line); i++) {
                ch = substr(line, i, 1)
                if (ch == "\\" && !in_squote) { i++; continue }
                # A trailing comment is not code, and an apostrophe in one
                # ("the worker\x27s tree") would otherwise desync the state.
                if (ch == "#" && !in_squote && !in_dquote &&
                    (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) break
                if (ch == "\x22" && !in_squote) { in_dquote = !in_dquote; continue }
                if (ch == "\x27" && !in_dquote) { in_squote = !in_squote; continue }
                if (!in_squote && !in_dquote) out = out ch
            }
            return out
        }
        # One command: leading assignments, then the command word. Returns the
        # command word, and leaves the assignments it consumed in ASSIGNMENTS --
        # so `TMPDIR=/tmp sort` is recognised as a sort, and
        # `LC_ALL=en_US.UTF-8 sort` is recognised as an UNPINNED sort.
        function command_word(segment,   word) {
            ASSIGNMENTS = ""
            sub(/^[[:space:]]+/, "", segment)
            while (match(segment, /^[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+/)) {
                ASSIGNMENTS = ASSIGNMENTS substr(segment, RSTART, RLENGTH)
                segment = substr(segment, RSTART + RLENGTH)
            }
            word = segment
            sub(/[[:space:]].*$/, "", word)
            return word
        }
        {
            # A reasoned marker applies only to the immediately following
            # command, so no file-level exemption is possible, and it must
            # actually carry a reason.
            marker = pending_marker
            pending_marker = ""
            if ($0 ~ /^[[:space:]]*#[[:space:]]*collation-allow:[[:space:]]*[^[:space:]]/) {
                pending_marker = "yes"
                next
            }
            if (heredoc != "") {
                body = $0
                sub(/^[[:space:]]+/, "", body)
                if (body == heredoc) heredoc = ""
                next
            }
            if (in_squote == 0 && $0 ~ /^[[:space:]]*#/) next

            # Detect the opener on the RAW line: scrubbing removes the quoted
            # delimiter of `cat << \x27EOF\x27` along with the quotes. `<<<` is a
            # here-string, not a heredoc, and must not arm the body skip.
            opens_heredoc = (in_squote == 0 && in_dquote == 0 &&
                match($0, /<<-?[[:space:]]*[\x27\x22]?[A-Za-z_][A-Za-z0-9_]*[\x27\x22]?/) &&
                substr($0, RSTART + 2, 1) != "<" &&
                (RSTART == 1 || substr($0, RSTART - 1, 1) != "<"))
            if (opens_heredoc) {
                next_heredoc = substr($0, RSTART, RLENGTH)
                sub(/^<<-?[[:space:]]*/, "", next_heredoc)
                gsub(/[\x27\x22]/, "", next_heredoc)
            }

            code = shell_code($0)
            if (opens_heredoc) heredoc = next_heredoc

            # Split into commands and check each one on its own, so a pinned
            # call earlier on the line cannot vouch for an unpinned one after it.
            n = split(code, segments, /\|\||&&|\||;|\(|\)|\{|\}/)
            for (s = 1; s <= n; s++) {
                word = command_word(segments[s])
                if (word != "sort" && word != "comm") continue
                if (ASSIGNMENTS ~ /(LC_ALL|LC_COLLATE)=C([[:space:]]|$)/) continue
                if (marker != "") continue
                report("shell " word " must pin LC_ALL=C (or carry a collation-allow: <reason> marker)")
            }
        }
        END { exit bad ? 1 : 0 }
    ' "$file" || rc=1
    # Shipped shell is named *.sh by convention; a shebang file that slips
    # through is still shell this gate has to see.
done < <({ find "$root" -type f -name '*.sh' -print
           grep -rlsE '^#!.*[/ ](ba)?sh' -- "$root" 2>/dev/null | grep -v '\.sh$' || true
         } | LC_ALL=C sort -u)

exit "$rc"
