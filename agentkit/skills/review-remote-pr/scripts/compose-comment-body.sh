#!/usr/bin/env bash
# Compose a PR comment into a private file without interpolating its content.
#
# Body parts are always read from files. Trigger/command comments intentionally
# have no agentic attribution; callers that authored the content can opt in with
# --agent-identity-file, which adds the canonical banner and signature.
set -euo pipefail
umask 077

readonly PROGRAM=${0##*/}
readonly BANNER='This was written agentically; verify its assertions:'

output=''
parts=()
identity_file=''
temp=''
identity=''

usage() {
    printf '%s\n' \
        "usage: $PROGRAM --output FILE --body-file FILE [--body-file FILE ...]" \
        '       [--agent-identity-file FILE]' \
        '' \
        'Composes a comment from owned, file-backed body parts. Without an identity' \
        'file the output is a plain trigger/command comment with no attribution banner.' \
        'With one, the canonical agentic banner and signature are added safely.' >&2
    exit "${1:-2}"
}

die() {
    printf '%s: %s\n' "$PROGRAM" "$*" >&2
    exit 1
}

require_file() {
    local label=$1 path=$2
    [[ -f $path && ! -L $path && -r $path && -O $path ]] ||
        die "$label must be an owned readable regular file: $path"
}

while (($#)); do
    case $1 in
        --) shift; break ;;
        --output)
            (($# >= 2)) || usage
            output=$2
            shift 2
            ;;
        --body-file|--part)
            (($# >= 2)) || usage
            parts+=("$2")
            shift 2
            ;;
        --agent-identity-file)
            (($# >= 2)) || usage
            identity_file=$2
            shift 2
            ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done

[[ -n $output ]] || die '--output is required'
[[ $output != */ ]] || die '--output must name a file'
((${#parts[@]} > 0)) || die 'at least one --body-file is required'
for part in "${parts[@]}"; do
    require_file '--body-file' "$part"
done
if [[ -n $identity_file ]]; then
    require_file '--agent-identity-file' "$identity_file"
    [[ $(wc -l <"$identity_file") -eq 0 ]] ||
        die '--agent-identity-file must contain one line without a newline'
    identity=$(<"$identity_file")
    [[ -n $identity && $identity != *$'\r'* ]] ||
        die '--agent-identity-file must contain one non-empty line'
fi

if [[ -e $output || -L $output ]]; then
    [[ -f $output && ! -L $output && -O $output ]] ||
        die '--output must be an owned regular file or a new path'
fi
output_dir=${output%/*}
[[ $output_dir == "$output" ]] && output_dir='.'
[[ -d $output_dir && ! -L $output_dir && -O $output_dir ]] ||
    die '--output parent must be an owned directory'

last_part=${parts[${#parts[@]}-1]}
last_part_has_newline=0
[[ $(tail -c 1 -- "$last_part" 2>/dev/null | wc -l) -gt 0 ]] && last_part_has_newline=1

temp=$(mktemp "$output_dir/.compose-comment-body.XXXXXXXXXX") ||
    die 'could not create output temporary file'
chmod 600 -- "$temp"
cleanup() {
    [[ -z $temp || ! -e $temp ]] || rm -f -- "$temp"
}
trap cleanup EXIT HUP INT TERM

{
    if [[ -n $identity ]]; then
        printf '%s\n\n' "$BANNER"
    fi
    for part in "${parts[@]}"; do
        cat -- "$part"
    done
    if [[ -n $identity ]]; then
        ((last_part_has_newline)) || printf '\n'
        printf '\n🤖 Co-authored by %s.\n' "$identity"
    fi
} >"$temp"

mv -f -- "$temp" "$output"
temp=''
chmod 600 -- "$output"
printf 'composed output=%s parts=%s attribution=%s\n' \
    "$output" "${#parts[@]}" "$([[ -n $identity ]] && printf yes || printf no)"
