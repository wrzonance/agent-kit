#!/usr/bin/env bash
# The one Claude hook: while this session's `ak wait` is running, hold sub-agent notices so the root wakes once,
# on the wait's own exit notice. Reads the hook JSON with parameter matching only; any doubt prints nothing (fail open).
set -uo pipefail

input=$(cat) || exit 0
# Only an agent task notice qualifies; every other prompt costs these two string checks.
[[ $input == *'"prompt":"<task-notification>'* && $input == *'<summary>Agent \"'* ]] || exit 0

field() { local v=${input#*\""$1"\":\"}; printf '%s' "${v%%\"*}"; }
session=$(field session_id)
cwd=$(field cwd)
[[ -n $cwd ]] || exit 0

common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || exit 0
marker="$(dirname -- "$common")/.ak/wave.open"
[[ -f $marker ]] || exit 0

pid='' start='' msession='' mcwd=''
while IFS= read -r line; do
    case $line in
        pid=*) pid=${line#pid=} ;;
        start=*) start=${line#start=} ;;
        session=*) msession=${line#session=} ;;
        cwd=*) mcwd=${line#cwd=} ;;
    esac
done <"$marker"

[[ $pid =~ ^[0-9]+$ && -n $start ]] || exit 0
kill -0 "$pid" 2>/dev/null || exit 0
if [[ -r /proc/$pid/stat ]]; then
    stat=$(<"/proc/$pid/stat")
    stat=${stat##*) }
    read -ra fields <<<"$stat"
    now=${fields[19]:-}
else
    now=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//')
fi
[[ $now == "$start" ]] || exit 0

if [[ -n $msession ]]; then
    [[ $msession == "$session" ]] || exit 0
else
    [[ $mcwd == "$cwd" ]] || exit 0
fi
printf '%s\n' '{"decision":"block","reason":"ak wait is open for this wave; its exit notice is the one wake."}'
