#!/usr/bin/env bash
# Identify a completed shell read of the workflow body delivered to this
# session. Returns 0 only for the active receipt's exact SKILL.md path.

guard_active_skill_reread() {
    local state_root=$1 session=$2 command_line=$3
    local activation_dir activation_id activation_record activation_tracked
    local active_workflow active_status active_source active_root active_skills active_skill segment
    local verb token candidate canonical positional pattern_supplied pending_role start attached_role attached_value
    local -a words
    [[ -n $state_root && -n $session ]] || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    activation_dir="$state_root/.agent/activation"
    activation_id=$(printf '%s' "$session" | sha256sum | awk '{print $1}')
    activation_record="$activation_dir/$activation_id.json"
    [[ -d $activation_dir && ! -L $activation_dir && -O $activation_dir &&
       -f $activation_record && ! -L $activation_record && -O $activation_record ]] || return 1
    activation_tracked=0
    git -C "$state_root" ls-files --error-unmatch -- ".agent/activation/$activation_id.json" \
        >/dev/null 2>&1 || activation_tracked=$?
    [[ $activation_tracked == 1 ]] || return 1
    active_workflow=$(jq -r '.workflow // empty' "$activation_record" 2>/dev/null) || return 1
    active_status=$(jq -r '.status // empty' "$activation_record" 2>/dev/null) || return 1
    active_source=$(jq -r '.receiptSource // empty' "$activation_record" 2>/dev/null) || return 1
    active_root=$(jq -r '.repoRoot // empty' "$activation_record" 2>/dev/null) || return 1
    active_skills=$(jq -r '.skillsRoot // empty' "$activation_record" 2>/dev/null) || return 1
    [[ $active_workflow =~ ^[a-z][a-z0-9-]*$ && $active_status == active &&
       $active_source == session-acknowledgement && $active_root == "$state_root" &&
       $active_skills == /* ]] || return 1
    active_skill="$active_skills/$active_workflow/SKILL.md"
    [[ -f $active_skill && ! -L $active_skill ]] || return 1
    while IFS= read -r segment; do
        mapfile -t words < <(guard_tokenize_words "$segment")
        ((${#words[@]})) || continue
        start=$(guard_skip_command_prefix words 0) || continue
        ((start < ${#words[@]})) || continue
        verb=${words[start]#\(}; verb=${verb##*/}
        case $verb in cat|head|tail|sed|awk|grep|rg|less|more|nl) ;; *) continue;; esac
        positional=0; pattern_supplied=0; pending_role=
        for token in "${words[@]:start+1}"; do
            if [[ -n $pending_role ]]; then
                case $pending_role in
                    file)
                        case $token in /*) candidate=$token ;; *) candidate="$state_root/$token" ;; esac
                        canonical=$(guard_scope_canonical "$candidate") || canonical=
                        [[ $canonical == "$active_skill" ]] && return 0
                        pattern_supplied=1 ;;
                    expression) pattern_supplied=1 ;;
                    assignment|value) ;;
                esac
                pending_role=
                continue
            fi
            attached_role=
            attached_value=
            case $verb:$token in
                sed:-e?*|grep:-e?*|rg:-e?*)
                    attached_role='expression'; attached_value=${token#-e} ;;
                sed:--expression=*|grep:--regexp=*|rg:--regexp=*)
                    attached_role='expression'; attached_value=${token#*=} ;;
                sed:-f?*|awk:-f?*|grep:-f?*|rg:-f?*)
                    attached_role='file'; attached_value=${token#-f} ;;
                sed:--file=*|awk:--file=*|grep:--file=*|rg:--file=*)
                    attached_role='file'; attached_value=${token#*=} ;;
            esac
            if [[ -n $attached_role && -n $attached_value ]]; then
                if [[ $attached_role == file ]]; then
                    case $attached_value in
                        /*) candidate=$attached_value ;;
                        *) candidate="$state_root/$attached_value" ;;
                    esac
                    canonical=$(guard_scope_canonical "$candidate") || canonical=
                    [[ $canonical == "$active_skill" ]] && return 0
                fi
                pattern_supplied=1
                continue
            fi
            case $verb:$token in
                sed:-e|sed:--expression|grep:-e|grep:--regexp|rg:-e|rg:--regexp)
                    pending_role='expression'; continue ;;
                sed:-f|sed:--file|awk:-f|awk:--file|grep:-f|grep:--file|rg:-f|rg:--file)
                    pending_role='file'; continue ;;
                awk:-v) pending_role='assignment'; continue ;;
                head:-n|head:--lines|head:-c|head:--bytes|tail:-n|tail:--lines|tail:-c|tail:--bytes)
                    pending_role='value'; continue ;;
            esac
            [[ $token != -* ]] || continue
            if [[ $verb == sed || $verb == awk || $verb == grep || $verb == rg ]] &&
                ((pattern_supplied == 0 && positional++ == 0)); then
                pattern_supplied=1
                continue
            fi
            case $token in /*) candidate=$token ;; *) candidate="$state_root/$token" ;; esac
            canonical=$(guard_scope_canonical "$candidate") || continue
            [[ $canonical == "$active_skill" ]] && return 0
        done
    done < <(guard_destructive_command_segments "$command_line")
    return 1
}
