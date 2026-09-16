#!/usr/bin/env bash
# Shared command segmentation, sourced by guard-lib.sh.

# The one quote/heredoc lexer. mode=recover (default): a heredoc BODY is dropped
# only when inert -- a quoted-delimiter body to a data sink stays dropped (issue
# #351); an UNQUOTED body's substitutions and any body reachable by a shell
# through an input descriptor are recovered and recursively re-segmented
# (issues #364 and #756).
# mode=drop: every body is dropped (guard_gh_command_segments, issue #661).
# mode=helper: recover bodies, but emit NUL records, join line continuations,
# and discard shell comments so inert text cannot create diagnostic boundaries.
# mode=writes: recover executable bodies, preserving >| and >& operators.
# shellcheck disable=SC2059  # record_format is one of two fixed literals, never input.
guard_mark_reachable_heredocs() {
    local -n __gmrh_effects=$1 __gmrh_descriptors=$2
    local start=$3 end=$4 index source
    for ((index = start; index < end; index++)); do
        __gmrh_effects[index]=0
    done
    for source in "${__gmrh_descriptors[@]}"; do
        [[ $source =~ ^[0-9]+$ ]] && __gmrh_effects[source]=1
    done
}

guard_destructive_command_segments() {
    local input=$1 mode=${2:-recover} line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
    local i length char next third rest k delimiter delimiter_quote terminator_line
    local owner='' heredoc_no_expand=0 heredoc_effective=0 body='' bodyline sub recovered
    local heredoc_index=0 queue_index command_heredoc_start=0 substitution_depth=0
    local target_fd source_fd redirect_word redirect_offset
    local -a heredoc_delimiters=() heredoc_tabstrips=() heredoc_no_expands=()
    local -a heredoc_owners=() heredoc_effectives=()
    local -A descriptor_heredocs=()
    local record_format='%s\n' record_delimiter=$'\n' continued=0 word_start=1
    [[ $mode != helper ]] || { record_format='%s\0'; record_delimiter=''; }

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n $heredoc ]]; then
            terminator_line=$line
            if ((heredoc_tabstrip)); then
                terminator_line=${terminator_line#"${terminator_line%%[!$'\t']*}"}
            fi
            if [[ $terminator_line == "$heredoc" ]]; then
                if [[ $mode == drop ]]; then
                    body=''
                elif ((heredoc_effective)) && guard_heredoc_consumer_is_shell "$owner"; then
                    while IFS= read -r -d "$record_delimiter" recovered; do
                        [[ -n $recovered ]] && printf "$record_format" "$recovered"
                    done < <(guard_destructive_command_segments "$body" "$mode")
                elif ((!heredoc_no_expand)); then
                    while IFS= read -r sub; do
                        while IFS= read -r -d "$record_delimiter" recovered; do
                            [[ -n $recovered ]] && printf "$record_format" "$recovered"
                        done < <(guard_destructive_command_segments "$sub" "$mode")
                    done < <(guard_heredoc_substitutions "$body")
                fi
                body=''
                heredoc_index=$((heredoc_index + 1))
                if ((heredoc_index < ${#heredoc_delimiters[@]})); then
                    heredoc=${heredoc_delimiters[heredoc_index]}
                    heredoc_tabstrip=${heredoc_tabstrips[heredoc_index]}
                    heredoc_no_expand=${heredoc_no_expands[heredoc_index]}
                    owner=${heredoc_owners[heredoc_index]}
                    heredoc_effective=${heredoc_effectives[heredoc_index]}
                    body=''
                    continue
                fi
                heredoc=''
                heredoc_tabstrip=0
                heredoc_no_expand=0
                heredoc_effective=0
                owner=''
                heredoc_delimiters=()
                heredoc_tabstrips=()
                heredoc_no_expands=()
                heredoc_owners=()
                heredoc_effectives=()
                heredoc_index=0
                command_heredoc_start=0
                descriptor_heredocs=()
                # Flush the owner line (through the heredoc opener) as its own
                # segment now, or the next command merges into it and the
                # one-segment-per-command contract breaks.
                if [[ -n $segment ]]; then
                    printf "$record_format" "${segment%$'\n'}"
                    segment=''
                    word_start=1
                fi
                continue
            fi
            bodyline=$line
            if ((heredoc_tabstrip)); then
                bodyline=${bodyline#"${bodyline%%[!$'\t']*}"}
            fi
            [[ $mode == drop ]] || body+="$bodyline"$'\n'
            continue
        fi

        i=0
        length=${#line}
        while ((i < length)); do
            char=${line:i:1}
            next=${line:i+1:1}
            third=${line:i+2:1}

            if [[ $quote == "'" ]]; then
                word_start=0
                segment+=$char
                [[ $char == "'" ]] && quote=''
                ((i++))
                continue
            fi
            if ((escaped)); then
                word_start=0
                segment+=$char
                escaped=0
                ((i++))
                continue
            fi
            if [[ $char == \\ ]]; then
                if [[ $mode == helper && -z $next ]]; then
                    continued=1
                    break
                fi
                word_start=0
                segment+=$char
                escaped=1
                ((i++))
                continue
            fi
            if [[ $quote == '"' ]]; then
                word_start=0
                segment+=$char
                [[ $char == '"' ]] && quote=''
                ((i++))
                continue
            fi

            if [[ $char == '$' && $next == '(' ]]; then
                substitution_depth=$((substitution_depth + 1))
                segment+="$char("
                i=$((i + 2))
                continue
            fi
            if ((substitution_depth)); then
                case $char in
                    '(') substitution_depth=$((substitution_depth + 1));;
                    ')') substitution_depth=$((substitution_depth - 1));;
                    '<')
                        segment+=$char
                        ((i++))
                        continue
                        ;;
                esac
            fi
            if [[ ( $char == '<' || $char == '>' ) && $next == '(' ]]; then
                substitution_depth=$((substitution_depth + 1))
                segment+="$char("
                i=$((i + 2))
                continue
            fi

            if [[ $mode == writes && $char == '>' && ( $next == '|' || $next == '&' ) ]]; then
                segment+=">$next"
                i=$((i + 2))
                continue
            fi
            case $char in
                '#')
                    if [[ $mode == helper ]] && ((word_start)); then
                        break
                    fi
                    word_start=0
                    segment+=$char
                    ((i++))
                    ;;
                "'"|'"')
                    word_start=0
                    quote=$char
                    segment+=$char
                    ((i++))
                    ;;
                ';'|'|'|'&')
                    printf "$record_format" "$segment"
                    segment=''
                    word_start=1
                    if ((substitution_depth == 0)); then
                        guard_mark_reachable_heredocs heredoc_effectives descriptor_heredocs \
                            "$command_heredoc_start" "${#heredoc_delimiters[@]}"
                        descriptor_heredocs=()
                        command_heredoc_start=${#heredoc_delimiters[@]}
                    fi
                    ((i++))
                    ;;
                '<')
                    word_start=0
                    target_fd=0
                    if [[ $segment =~ (^|[[:space:]])([0-9]+)$ ]]; then
                        target_fd=$((10#${BASH_REMATCH[2]}))
                    fi
                    if [[ $next == '<' && $third != '<' ]]; then
                        owner=$segment
                        segment+='<<'
                        i=$((i + 2))
                        rest=${line:i}
                        heredoc_tabstrip=0
                        [[ ${rest:0:1} == '-' ]] && { rest=${rest:1}; heredoc_tabstrip=1; }
                        rest="${rest#"${rest%%[![:space:]]*}"}"
                        delimiter_quote=${rest:0:1}
                        if [[ $delimiter_quote == "'" || $delimiter_quote == '"' ]]; then
                            rest=${rest:1}
                            k=0
                            while ((k < ${#rest})) && [[ ${rest:k:1} != "$delimiter_quote" ]]; do
                                ((k++))
                            done
                            delimiter=${rest:0:k}
                            heredoc_no_expand=1
                        else
                            delimiter=${rest%%[[:space:];|&]*}
                            # An unquoted delimiter such as `<<\EOF` disables
                            # heredoc-body expansion the same way a quoted one
                            # does; bash strips the backslash for the purpose
                            # of matching the terminator, so the stored
                            # delimiter must too, or the real terminator line
                            # (bare "EOF") never matches "\EOF".
                            heredoc_no_expand=0
                            [[ $delimiter_quote == \\ ]] && heredoc_no_expand=1
                            delimiter=${delimiter//\\/}
                        fi
                        if [[ -n $delimiter ]]; then
                            queue_index=${#heredoc_delimiters[@]}
                            heredoc_delimiters[queue_index]=$delimiter
                            heredoc_tabstrips[queue_index]=$heredoc_tabstrip
                            heredoc_no_expands[queue_index]=$heredoc_no_expand
                            heredoc_owners[queue_index]=$owner
                            heredoc_effectives[queue_index]=0
                            descriptor_heredocs[$target_fd]=$queue_index
                        fi
                    elif [[ $next == '<' && $third == '<' ]]; then
                        unset 'descriptor_heredocs[$target_fd]'
                        segment+='<<<'
                        i=$((i + 3))
                    elif [[ $next == '&' ]]; then
                        rest=${line:i+2}
                        rest="${rest#"${rest%%[![:space:]]*}"}"
                        redirect_word=${rest%%[[:space:];|&<>]*}
                        if [[ $redirect_word =~ ^[0-9]+$ ]]; then
                            source_fd=$((10#$redirect_word))
                            if [[ ${descriptor_heredocs[$source_fd]+present} ]]; then
                                descriptor_heredocs[$target_fd]=${descriptor_heredocs[$source_fd]}
                            else
                                unset 'descriptor_heredocs[$target_fd]'
                            fi
                        elif [[ $redirect_word == '-' ]]; then
                            unset 'descriptor_heredocs[$target_fd]'
                        fi
                        segment+='<&'
                        i=$((i + 2))
                    else
                        redirect_offset=1
                        [[ $next != '>' ]] || redirect_offset=2
                        rest=${line:i+redirect_offset}
                        rest="${rest#"${rest%%[![:space:]]*}"}"
                        redirect_word=${rest%%[[:space:];|&<>]*}
                        source_fd=''
                        if [[ $redirect_word == '/dev/stdin' ]]; then
                            source_fd=0
                        elif [[ $redirect_word =~ ^/dev/fd/([0-9]+)$ ]] ||
                            [[ $redirect_word =~ ^/proc/self/fd/([0-9]+)$ ]]; then
                            source_fd=$((10#${BASH_REMATCH[1]}))
                        fi
                        if [[ -n $source_fd ]]; then
                            if [[ ${descriptor_heredocs[$source_fd]+present} ]]; then
                                descriptor_heredocs[$target_fd]=${descriptor_heredocs[$source_fd]}
                            else
                                unset 'descriptor_heredocs[$target_fd]'
                            fi
                        elif [[ $redirect_word =~ ^[-A-Za-z0-9_./,:+]+$ ]]; then
                            unset 'descriptor_heredocs[$target_fd]'
                        fi
                        segment+=${line:i:redirect_offset}
                        i=$((i + redirect_offset))
                    fi
                    ;;
                *)
                    word_start=0
                    [[ $char != [[:space:]] ]] || word_start=1
                    segment+=$char
                    ((i++))
                    ;;
            esac
        done

        if ((continued)); then
            continued=0
            continue
        fi
        if ((substitution_depth == 0)); then
            guard_mark_reachable_heredocs heredoc_effectives descriptor_heredocs \
                "$command_heredoc_start" "${#heredoc_delimiters[@]}"
        fi
        if ((${#heredoc_delimiters[@]} > 0)) && [[ -z $heredoc ]]; then
            heredoc_index=0
            heredoc=${heredoc_delimiters[0]}
            heredoc_tabstrip=${heredoc_tabstrips[0]}
            heredoc_no_expand=${heredoc_no_expands[0]}
            owner=${heredoc_owners[0]}
            heredoc_effective=${heredoc_effectives[0]}
            body=''
        fi
        if [[ -z $heredoc && -z $quote ]]; then
            printf "$record_format" "$segment"
            segment=''
            word_start=1
            command_heredoc_start=${#heredoc_delimiters[@]}
            descriptor_heredocs=()
        else
            segment+=$'\n'
        fi
    done <<< "$input"
    # A final continuation can leave a complete command pending at EOF.
    # Keep unfinished quotes/heredocs and the legacy modes' output unchanged.
    if [[ $mode == helper && -n $segment && -z $quote && -z $heredoc ]]; then
        printf '%s\0' "$segment"
    fi
}

# Helper diagnostics recognize only the existing literal command-prefix shapes.
# Do not scan inside a segment: its quoted/escaped separators are argument data.
# NUL framing keeps quoted newlines inside the same segment, too.
guard_has_bare_helper_command() {
    local segment helper_re="^[[:space:]]*((sudo|env)[[:space:]]+)*((bash|sh)[[:space:]]+)?($HELPERS)\.sh([[:space:]]|$)"
    while IFS= read -r -d '' segment; do
        [[ $segment =~ $helper_re ]] && return 0
    done < <(guard_destructive_command_segments "$1" helper)
    return 1
}
