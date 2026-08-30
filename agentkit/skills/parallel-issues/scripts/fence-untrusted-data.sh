#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: fence-untrusted-data.sh < body

Reads untrusted text from stdin and writes it between matching, nonce-bound
issue-data markers. The nonce is generated for this invocation and is never
accepted from the caller.
EOF
}

die() {
    printf 'fence-untrusted-data: %s\n' "$1" >&2
    exit 1
}

case ${1-} in
    '') ;;
    --) shift; [[ $# -eq 0 ]] || die "unexpected argument: $1" ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        die "unexpected argument: $1"
        ;;
esac

umask 077
body_file=$(mktemp "${TMPDIR:-/tmp}/fence-untrusted-data.XXXXXX") ||
    die 'could not create a temporary input file'
trap 'rm -f -- "$body_file"' EXIT
cat >"$body_file" || die 'could not read stdin'

generate_token() {
    local random
    random=$(od -An -N16 -tx1 /dev/urandom | tr -d '[:space:]') || return 1
    [[ $random =~ ^[[:xdigit:]]{32}$ ]] || return 1
    printf 'BND_%s\n' "$(printf '%s' "$random" | tr '[:lower:]' '[:upper:]')"
}

token=
while :; do
    token=$(generate_token) || die 'could not generate a 128-bit boundary token'
    if grep -Fq -- "$token" "$body_file"; then
        continue
    else
        grep_rc=$?
    fi
    [[ $grep_rc -eq 1 ]] || die 'could not check the input for a token collision'
    break
done

printf '<BEGIN UNTRUSTED ISSUE DATA: %s>\n' "$token"
cat -- "$body_file"
if [[ -s $body_file ]]; then
    last_byte=$(tail -c 1 "$body_file" | od -An -tx1 | tr -d '[:space:]')
    [[ $last_byte == 0a ]] || printf '\n'
fi
printf '<END UNTRUSTED ISSUE DATA: %s>\n' "$token"
