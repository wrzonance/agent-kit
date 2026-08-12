#!/usr/bin/env bash
# Static contract scan for forge routing. The caller can point this at a staged
# helper tree or a fixture; it never contacts GitHub.
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
        {
            line = $0
            # A reasoned marker applies only to the immediately following
            # command. This prevents a broad file-level GraphQL exemption.
            marker = pending_marker
            pending_marker = ""
            if (line ~ /^[[:space:]]*#[[:space:]]*routing-allow:[[:space:]]*/) {
                pending_marker = line
                sub(/^[[:space:]]*#[[:space:]]*routing-allow:[[:space:]]*/, "", pending_marker)
                sub(/[[:space:]]+.*/, "", pending_marker)
                next
            }
            if (line ~ /gh[[:space:]]+api[[:space:]]+graphql/) {
                if (marker != "projects-v2" && marker != "review-threads") {
                    report("GraphQL call requires routing-allow: projects-v2 or routing-allow: review-threads")
                }
            }
            if (line ~ /gh[[:space:]]+(issue|pr|label)[[:space:]]+[^#]*--json([[:space:]]|$)/ ||
                line ~ /gh[[:space:]]+(issue|pr|label)[[:space:]]+[^#]*--jq([[:space:]]|$)/) {
                report("REST-able data must use gh api repos/...; porcelain JSON is forbidden")
            }
        }
        END { exit bad ? 1 : 0 }
    ' "$file" || rc=1
done < <(find "$root" -type f -name '*.sh' -print | sort)

exit "$rc"
