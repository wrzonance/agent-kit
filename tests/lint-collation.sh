#!/usr/bin/env bash
# Static collation scan (issue #846). Shell `sort` and `comm` order by the
# CALLER's locale, so an unpinned call makes a helper emit different bytes on a
# UTF-8 desktop than on a C.UTF-8 runner -- and `comm` silently misreports when
# its two inputs were ordered under different collations. Evidence, fingerprints
# and set comparisons have to be byte-stable across machines, so every shell
# `sort`/`comm` in the shipped tree pins `LC_ALL=C` on the command itself.
#
# jq's own `sort`/`sort_by` is codepoint-ordered and locale-independent, so
# quoted jq programs are skipped.
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
        # Drop single-quoted regions, tracking the state across lines: jq
        # programs live in them, and their `| sort` is not a shell call. What
        # remains is the shell code on that line, including the tail after a
        # quoted program closes -- which is exactly where a piped `| sort` sits.
        # Double-quoted spans are kept as code (they hold shell expansions) but
        # an apostrophe inside one -- "doesn\x27t" -- must not open a quote, or
        # every later line in the file is misread.
        function shell_code(line,   out, i, ch) {
            out = ""
            for (i = 1; i <= length(line); i++) {
                ch = substr(line, i, 1)
                if (ch == "\\" && (in_dquote || !in_squote)) {
                    if (!in_squote) { i++; continue }
                }
                # A trailing comment is not code, and an apostrophe in one
                # ("the worker\x27s tree") would otherwise open a quote and
                # desync every line after it.
                if (ch == "#" && !in_squote && !in_dquote &&
                    (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) break
                if (ch == "\x22" && !in_squote) { in_dquote = !in_dquote; continue }
                if (ch == "\x27" && !in_dquote) { in_squote = !in_squote; continue }
                if (!in_squote) out = out ch
            }
            return out
        }
        {
            # A reasoned marker applies only to the immediately following
            # command, so no file-level exemption is possible.
            marker = pending_marker
            pending_marker = ""
            if ($0 ~ /^[[:space:]]*#[[:space:]]*collation-allow:[[:space:]]*/) {
                pending_marker = "yes"
                next
            }
            # Heredoc bodies are recipe prose, not executed shell, and their
            # apostrophes would desync the quote state for the rest of the file.
            if (heredoc != "") {
                body = $0
                sub(/^[[:space:]]+/, "", body)
                if (body == heredoc) heredoc = ""
                next
            }
            if (in_squote == 0 && $0 ~ /^[[:space:]]*#/) next

            # Detect the opener on the RAW line: scrubbing removes the quoted
            # delimiter of `cat << \x27EOF\x27` along with the quotes.
            opens_heredoc = (in_squote == 0 && in_dquote == 0 &&
                match($0, /<<-?[[:space:]]*[\x27\x22]?[A-Za-z_][A-Za-z0-9_]*[\x27\x22]?/))
            if (opens_heredoc) {
                next_heredoc = substr($0, RSTART, RLENGTH)
                sub(/^<<-?[[:space:]]*/, "", next_heredoc)
                gsub(/[\x27\x22]/, "", next_heredoc)
            }

            code = shell_code($0)
            if (opens_heredoc) heredoc = next_heredoc

            # A shell sort/comm follows a pipe, a process substitution, a
            # command separator, or begins the command.
            if (code ~ /(\||\(|&&|;|^)[[:space:]]*(sort|comm)([[:space:]]|$)/) {
                if (code !~ /LC_ALL=[^[:space:]]+[[:space:]]+(sort|comm)([[:space:]]|$)/ && marker == "") {
                    report("shell sort/comm must pin LC_ALL=C (or carry a collation-allow: marker)")
                }
            }
        }
        END { exit bad ? 1 : 0 }
    ' "$file" || rc=1
done < <(find "$root" -type f -name '*.sh' -print | LC_ALL=C sort)

exit "$rc"
