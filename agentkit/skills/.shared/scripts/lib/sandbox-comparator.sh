#!/usr/bin/env bash
# Shared sandbox= restrictiveness comparator (issue #332 F3). agent-preflight.sh
# and compose-worker-prompt.sh each independently decide whether a sandbox=
# measurement got less restrictive -- one inside the process that wrote the
# contract, one on the other side of the create-issue-worktree.sh boundary
# reading it back. Two copies of the same ranking table invited exactly the
# drift a "keep these in lockstep" comment cannot enforce by itself; this file
# is the single definition both sides source. Source, don't execute.

# Restrictiveness rank for one sandbox= token: higher is safer/more
# restrictive. An absent or unrecognised value ranks as maximally
# uninformative (1, the middle value) rather than either extreme.
sandbox_field_rank() {
    local field="$1" value="$2"
    case "$field" in
        active)
            case "$value" in yes) printf '2' ;; no) printf '0' ;; *) printf '1' ;; esac ;;
        home-writable)
            case "$value" in no) printf '2' ;; yes) printf '0' ;; *) printf '1' ;; esac ;;
        # network=disabled is the most restrictive reading (no reachability at
        # all); network=ok the least; network=unresolved (a DNS lookup that
        # failed while the network was nominally allowed) sits in between --
        # it is evidence of a problem, not proof of either extreme.
        network)
            case "$value" in disabled) printf '2' ;; ok) printf '0' ;; *) printf '1' ;; esac ;;
    esac
}

# Whether $2 (a fresh sandbox= measurement) is LESS restrictive than $1 (a
# recorded one) on any single axis -- field-by-field, deliberately not a summed
# score (issue #332 F2): active/home-writable/network are independent, and a sum
# lets one axis's tightening mask another's widening. Prints the first regressed
# field and returns 0 when a widening is found; else prints nothing, returns 1.
# The free-form trailing note= (always the LAST field) is trimmed by bash suffix
# removal before matching, so a "field=" token inside a note cannot out-match
# the real field under the greedy regex.
sandbox_widened() {
    local recorded="$1" fresh="$2" field rec_tok fresh_tok rec_rank fresh_rank
    local recorded_fields="${recorded% note=\"*}"
    local fresh_fields="${fresh% note=\"*}"
    for field in active home-writable network; do
        rec_tok=$(sed -n "s/.*${field}=\\([A-Za-z]*\\).*/\\1/p" <<< "$recorded_fields")
        fresh_tok=$(sed -n "s/.*${field}=\\([A-Za-z]*\\).*/\\1/p" <<< "$fresh_fields")
        rec_rank=$(sandbox_field_rank "$field" "$rec_tok")
        fresh_rank=$(sandbox_field_rank "$field" "$fresh_tok")
        if (( fresh_rank < rec_rank )); then
            printf '%s' "$field"
            return 0
        fi
    done
    return 1
}
