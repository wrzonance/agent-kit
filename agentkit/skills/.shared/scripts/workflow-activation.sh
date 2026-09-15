#!/usr/bin/env bash
# Installed identity is an input, never proof of session receipt.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
skills=$(cd -- "$here/../.." && pwd -P)
# shellcheck source=lib/skills-content-hash.sh
source "$here/lib/skills-content-hash.sh"
digest=$(skills_content_hash "$skills")
exec python3 "$here/lib/workflow-activation.py" --skills "$skills" --digest "$digest" "$@"
