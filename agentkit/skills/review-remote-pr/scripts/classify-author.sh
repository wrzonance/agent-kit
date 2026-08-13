#!/usr/bin/env bash
# classify-author.sh — fail-closed forge-author classification for review routing.
#
# Input is one JSON author object from GitHub (or null when the author is absent).
# GraphQL supplies __typename; REST supplies type. Both are authoritative only
# when their value is exactly Bot. A terminal [bot] login is the second explicit
# forge signal. Everything else remains human.
set -euo pipefail

readonly PROGNAME=${0##*/}
INPUT_FILE='-'

usage() {
    cat <<'EOF'
Usage: classify-author.sh [--file PATH]

Read one GitHub author JSON object from PATH (or stdin) and print its routing
classification as JSON. Missing and unqueryable authors classify as human.
EOF
}

die() {
    printf '%s: %s\n' "$PROGNAME" "$1" >&2
    exit 1
}

parse_args() {
    while (($#)); do
        case $1 in
            --file)
                [[ $# -ge 2 && -n $2 ]] || die '--file requires a path'
                INPUT_FILE=$2
                shift 2
                ;;
            --file=*)
                INPUT_FILE=${1#*=}
                [[ -n $INPUT_FILE ]] || die '--file requires a path'
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                (($# == 0)) || die 'unexpected trailing argument'
                ;;
            *)
                die "unknown argument: $1 (try --help)"
                ;;
        esac
    done
}

parse_args "$@"
command -v jq >/dev/null 2>&1 || die 'jq not found on PATH; evidence unavailable'

if [[ $INPUT_FILE != '-' ]]; then
    [[ -r $INPUT_FILE ]] || die "cannot read input file: $INPUT_FILE"
fi

jq -c '
  def login: ((.login // "") | ascii_downcase);
  # Exact accounts, never a substring. The known-provider lane is what allows a
  # thread to be replied to and resolved WITHOUT the human confirmation gate, so
  # an unanchored "coderabbit" test handed that lane to any human who registers
  # a login like "mycoderabbit". An account that merely resembles a provider is
  # ambiguous, and every ambiguous author is human.
  def is_coderabbit:
    (login == "coderabbitai") or (login == "coderabbitai[bot]");
  def known_provider:
    is_coderabbit
    or login == "github-code-quality"
    or login == "github-code-quality[bot]";
  def type_is_bot:
    ((.type // "") == "Bot") or ((.__typename // "") == "Bot");
  def login_suffix: (login | test("\\[bot\\]$"));
  . as $author
  | ($author.login // "") as $original_login
  | if known_provider then
    {lane:"known-provider", signal:"known-provider", automated:true,
     provider:(if is_coderabbit then "coderabbit"
               else "github-code-quality" end)}
  elif login_suffix then
    {lane:"generic-automated", signal:"login-suffix", automated:true, provider:null}
  elif type_is_bot then
    {lane:"generic-automated", signal:"type=Bot", automated:true, provider:null}
  else
    {lane:"human", signal:"human", automated:false, provider:null}
  end
  | .login = (if ($original_login == "") then null else $original_login end)
' -- "$INPUT_FILE"
