#!/usr/bin/env bash
# Shared command segmentation, sourced by guard-lib.sh.

# The one quote/heredoc lexer. mode=recover (default): a heredoc BODY is dropped
# only when inert -- a quoted-delimiter body to a data sink stays dropped (issue
# #351); an UNQUOTED body's substitutions and any body handed to a shell are
# recovered and recursively re-segmented (issue #364). mode=drop: every body is
# dropped (guard_gh_command_segments, issue #661).
# mode=helper: recover bodies, but emit NUL records, join line continuations,
# and discard shell comments so inert text cannot create diagnostic boundaries.
# shellcheck disable=SC2059  # record_format is one of two fixed literals, never input.
guard_destructive_command_segments() {
    local input=$1 mode=${2:-recover} line segment='' quote='' escaped=0 heredoc='' heredoc_tabstrip=0
    local i length char next third rest k delimiter delimiter_quote terminator_line
    local owner='' heredoc_no_expand=0 body='' bodyline sub recovered
    local record_format='%s\n' record_delimiter=$'\n' continued=0 word_start=1
    [[ $mode != helper ]] || { record_format='%s\0'; record_delimiter=''; }

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ -n $heredoc ]]; then
            terminator_line=$line
            if ((heredoc_tabstrip)); then
                terminator_line=${terminator_line#"${terminator_line%%[!$'\t']*}"}
            fi
            if [[ $terminator_line == "$heredoc" ]]; then
                heredoc=''
                heredoc_tabstrip=0
                if [[ $mode == drop ]] || { ((heredoc_no_expand)) && ! guard_heredoc_consumer_is_shell "$owner"; }; then
                    body=''
                elif guard_heredoc_consumer_is_shell "$owner"; then
                    while IFS= read -r -d "$record_delimiter" recovered; do
                        [[ -n $recovered ]] && printf "$record_format" "$recovered"
                    done < <(guard_destructive_command_segments "$body" "$mode")
                    body=''
                else
                    while IFS= read -r sub; do
                        while IFS= read -r -d "$record_delimiter" recovered; do
                            [[ -n $recovered ]] && printf "$record_format" "$recovered"
                        done < <(guard_destructive_command_segments "$sub" "$mode")
                    done < <(guard_heredoc_substitutions "$body")
                    body=''
                fi
                owner=''
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
                    ((i++))
                    ;;
                '<')
                    word_start=0
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
                        [[ -n $delimiter ]] && heredoc=$delimiter
                        body=''
                    else
                        segment+=$char
                        ((i++))
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
        if [[ -z $heredoc && -z $quote ]]; then
            printf "$record_format" "$segment"
            segment=''
            word_start=1
        else
            segment+=$'\n'
        fi
    done <<< "$input"
}

# Helper diagnostics recognize only the existing literal command-prefix shapes.
# Do not scan inside a segment: its quoted/escaped separators are argument data.
# NUL framing keeps quoted newlines inside the same segment, too.
guard_has_bare_helper_command() {
    local segment helper_re="^[[:space:]]*((sudo|bash|sh|env)[[:space:]]+)*($HELPERS)\.sh([[:space:]]|$)"
    while IFS= read -r -d '' segment; do
        [[ $segment =~ $helper_re ]] && return 0
    done < <(guard_destructive_command_segments "$1" helper)
    return 1
}
