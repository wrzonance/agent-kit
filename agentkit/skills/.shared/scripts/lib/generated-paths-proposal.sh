# shellcheck shell=bash
# Candidate contracts only: reuse the detector's exclusions, never write config.
propose_generated_paths() {
    local repo_root=$1 path relative paths=''
    while IFS= read -r -d '' path; do
        relative=${path#"$repo_root"/}
        # Config's comma-delimited relative paths cannot represent arbitrary names.
        [[ $relative =~ ^[A-Za-z0-9_./-]+$ && $relative != *..* ]] || continue
        paths+="${paths:+,}$relative"
    done < <(find "$repo_root" "${PRUNE_EXPR[@]}" -o -type f '(' \
        -name openapi.json -o -name openapi.yaml -o -name openapi.yml \
        -o -name generated.ts -o -name '*.generated.ts' ')' -print0 | LC_ALL=C sort -z)
    [[ -z $paths ]] || printf '# AGENT_GENERATED_PATHS=%s\n\n' "$paths"
    return 0
}
