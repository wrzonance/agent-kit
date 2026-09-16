#!/usr/bin/env bash
# Identify a completed shell read of the workflow body delivered to this
# session. Returns 0 only for the active receipt's exact SKILL.md path.

guard_active_skill_reread() {
    local state_root=$1 session=$2 command_line=$3
    local activation_dir activation_id activation_record activation_tracked
    local active_workflow active_status active_source active_root active_skills active_skill segment
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
        [[ $segment == *"$active_skill"* ]] || continue
        grep -qE '(^|[[:space:];&|])(cat|head|tail|sed|awk|grep|rg|less|more)([[:space:]]|$)' \
            <<< "$segment" && return 0
    done < <(guard_destructive_command_segments "$command_line")
    return 1
}
