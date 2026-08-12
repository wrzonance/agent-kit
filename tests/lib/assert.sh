# shellcheck shell=bash
# Assertion helpers for the skill-tree test suites.
# Source this, set TEST_NAME first, call finish last.
# Deliberately no `set -e`: a failed assertion records and continues.

TESTS_RUN=0
TESTS_FAILED=0

_pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok   %s\n' "$1"
}

_fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL %s\n' "$1"
    shift
    printf '       %s\n' "$@"
}

assert_eq() {
    local want=$1 got=$2 msg=$3
    if [[ $want == "$got" ]]; then
        _pass "$msg"
    else
        _fail "$msg" "want: $want" "got:  $got"
    fi
}

assert_contains() {
    local haystack=$1 needle=$2 msg=$3
    if [[ $haystack == *"$needle"* ]]; then
        _pass "$msg"
    else
        _fail "$msg" "missing: $needle" "in:      ${haystack:0:400}"
    fi
}

assert_not_contains() {
    local haystack=$1 needle=$2 msg=$3
    if [[ $haystack != *"$needle"* ]]; then
        _pass "$msg"
    else
        _fail "$msg" "unexpected: $needle" "in:         ${haystack:0:400}"
    fi
}

# Scan executable skill recipes only: shell scripts are scanned as-is, while
# Markdown contributes only explicitly executable fenced blocks. This keeps
# prose prohibitions and output examples from looking like commands. Findings
# are emitted as path:line:description records; an empty result is clean.
scan_skill_recipes() {
    local path markdown
    for path in "$@"; do
        [[ -f $path ]] || continue
        markdown=0
        [[ $path == *.md ]] && markdown=1
        [[ $markdown == 1 || -x $path ]] || continue
        awk -v recipe="$path" -v markdown="$markdown" '
            function scan_segment(segment, number, words, count, position, command) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", segment)
                if (segment == "" || segment ~ /^#/) return
                sub(/^(if|then|do|while)[[:space:]]+(![[:space:]]+)?/, "", segment)
                count = split(segment, words, /[[:space:]]+/)
                position = 1
                while (position <= count && words[position] ~ /^[[:alnum:]_]+=[^[:space:]]*$/) position++
                if (position <= count && (words[position] == "!" || words[position] == "command" || words[position] == "builtin")) position++
                if (position > count) return
                command = words[position]
                sub(/^.*\//, "", command)
                if (command == "sleep")
                    print recipe ":" number ": sleep command"
                if (command == "gh" && words[position + 1] == "pr" && words[position + 2] == "ready")
                    print recipe ":" number ": gh pr ready command"
                if (command == "gh" && segment ~ /@coderabbitai[[:space:]]+(review|full[[:space:]]+review|pause|resume|resolve)([^[:alnum:]_]|$)/)
                    print recipe ":" number ": provider review trigger"
                if (segment ~ /(^|[[:space:]])--no-[[:space:]]*verify([[:space:]]|$)/)
                    print recipe ":" number ": hook bypass"
                if (segment ~ /(^|[[:space:]])git([[:space:]]|$)/ && segment ~ /core\.hooksPath/)
                    print recipe ":" number ": hook execution config bypass"
                if (segment ~ /(^|[[:space:]])git([[:space:]]|$)/ && segment ~ /config[[:space:]]+alias\./)
                    print recipe ":" number ": git alias bypass"
            }
            function scan_line(line, number, segments, count, position) {
                count = split(line, segments, /[;&|]+/)
                for (position = 1; position <= count; position++) scan_segment(segments[position], number)
            }
            markdown && /^```(bash|sh|shell|zsh)[[:space:]]*$/ { fenced = 1; next }
            markdown && fenced && /^```[[:space:]]*$/ { fenced = 0; next }
            (!markdown || fenced) { scan_line($0, NR) }
        ' "$path"
    done
}

# assert_rc WANT_RC MSG -- COMMAND [ARGS...]
assert_rc() {
    local want=$1 msg=$2
    shift 3 # drop want, msg, and the literal --
    local got=0
    "$@" > /dev/null 2>&1 || got=$?
    assert_eq "$want" "$got" "$msg"
}

# Walk a hook's output against its schema and print one line per violation.
# Kept as one jq program rather than a ladder of shell branches because the
# schemas nest: hookSpecificOutput is a $ref into definitions, and it carries
# its own additionalProperties/required/const rules that a top-level-only check
# would never see.
# The single quotes are load-bearing: $schema, $obj, $key and $path are jq
# variables, and bash expanding them would empty the program.
# shellcheck disable=SC2016
_HOOK_SCHEMA_JQ='
def resolve($node):
    if ($node | type) == "object" and ($node | has("allOf"))
    then ($schema.definitions[$node.allOf[0]["$ref"] | ltrimstr("#/definitions/")] // {})
    else $node
    end;

def violations($obj; $spec; $path):
    # Compared against false directly, never via //: jq treats false as absent,
    # so `.additionalProperties // true` would read false as true and this check
    # would silently never fire. Absent means null, which correctly means "extra
    # properties are allowed" and skips the check.
    (if $spec.additionalProperties == false
     then ($obj | keys_unsorted[]) as $key
        | select(($spec.properties // {}) | has($key) | not)
        | "\($path)\($key) is not in the schema"
     else empty
     end),
    (($spec.required // [])[] as $req
     | select($obj | has($req) | not)
     | "\($path)\($req) is required but missing"),
    (($obj | keys_unsorted[]) as $key
     | select(($spec.properties // {}) | has($key))
     | $obj[$key] as $value
     | select($value != null)
     | resolve($spec.properties[$key]) as $prop
     | (if ($prop | has("enum")) and ($prop.enum | index($value)) == null
        then "\($path)\($key) = \($value | tojson) is not one of \($prop.enum | join(", "))"
        else empty
        end),
       (if ($prop | has("const")) and $value != $prop.const
        then "\($path)\($key) = \($value | tojson), expected \($prop.const | tojson)"
        else empty
        end),
       (if ($prop | has("properties")) and ($value | type) == "object"
        then violations($value; $prop; "\($path)\($key).")
        else empty
        end));

violations(.; $schema; "")
'

# assert_hook_output JSON EVENT MSG
# Validates a hook's stdout against the schema extracted from the codex binary:
# valid JSON, no property outside the schema, every required field present, and
# only known enum and const values -- nested objects included, since a hook
# adapted from its neighbour otherwise announces the wrong hookEventName and
# nothing notices.
assert_hook_output() {
    local json=$1 event=$2 msg=$3
    local tests_dir schema_file violations

    tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
    schema_file="$tests_dir/fixtures/schema-$event.json"

    if ! jq -e . <<< "$json" > /dev/null 2>&1; then
        _fail "$msg" "not valid JSON" "got: ${json:0:200}"
        return
    fi
    if [[ ! -r $schema_file ]]; then
        _fail "$msg" "missing schema fixture: $schema_file"
        return
    fi
    # A checker that cannot run is a failure, not a pass.
    if ! violations=$(jq -r --argjson schema "$(cat -- "$schema_file")" \
        "$_HOOK_SCHEMA_JQ" <<< "$json" 2>&1); then
        _fail "$msg" "schema check failed to run" "${violations:0:200}"
        return
    fi
    if [[ -n $violations ]]; then
        _fail "$msg" "does not match schema-$event.json:" "$violations"
        return
    fi
    _pass "$msg"
}

finish() {
    printf '%s: %d assertions, %d failed\n' "${TEST_NAME:-suite}" "$TESTS_RUN" "$TESTS_FAILED"
    [[ $TESTS_FAILED -eq 0 ]]
}
