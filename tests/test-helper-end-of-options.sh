#!/usr/bin/env bash
# Suite: every executable skill helper accepts a trailing POSIX `--` marker.
set -uo pipefail

TEST_NAME='helper end-of-options'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/cwd" "$tmp/gh-config"

# Helpers that reach GitHub must stop at the parser boundary without making a
# live request. Presence of this stub lets those helpers complete their own
# environment checks and report the missing/failed dependency after consuming
# `--`; the test only cares that the marker itself is not rejected.
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x -- "$tmp/bin/gh"

marker_rejection() {
    grep -Eiq '(unknown|unexpected)[[:space:]]+(argument|option|subcommand).*--' <<< "$1"
}

mapfile -t helpers < <(find "$root/agentkit/skills" -type f -name '*.sh' -perm -111 | sort)
assert_eq 64 "${#helpers[@]}" 'the contract covers every executable shipped helper'

for helper in "${helpers[@]}"; do
    args=(--)
    case "$helper" in
        */apply-ledger.sh) args=(init --) ;;
        */bump-version.sh) args=(invalid --) ;;
        */consent-record.sh) args=(payload --) ;;
        */cross-write-check.sh) args=(snapshot --) ;;
        */finding-ledger.sh) args=(add --) ;;
        */gh-body.sh) args=(pr create --) ;;
        */post-receipt.sh) args=(precheck --) ;;
        */review-ledger.sh) args=(read --) ;;
        */session-ledger.sh) args=(append --) ;;
    esac
    output=''
    rc=0
    output=$(cd -- "$tmp/cwd" && PATH="$tmp/bin:$PATH" \
        AGENTKIT_NET_PROBE=fail GH_CONFIG_DIR="$tmp/gh-config" \
        timeout 5 "$helper" "${args[@]}" </dev/null 2>&1) || rc=$?
    if marker_rejection "$output"; then
        _fail "$(basename -- "$helper") accepts a trailing -- marker" \
            "rc: $rc" "marker rejection: ${output:0:400}"
    else
        _pass "$(basename -- "$helper") accepts a trailing -- marker (rc=$rc)"
    fi
done

finish
