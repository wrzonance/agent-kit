#!/usr/bin/env bash
# Extract hook output schemas from the codex binary into test fixtures.
# Run once; the fixtures are committed. Re-run after a codex upgrade.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
command -v codex > /dev/null 2>&1 || { printf 'codex not installed\n' >&2; exit 3; }
bin=$(readlink -f -- "$(command -v codex)")

python3 - "$bin" "$here/fixtures" <<'PY'
import sys, json, os
binary, outdir = sys.argv[1], sys.argv[2]
data = open(binary, 'rb').read().decode('utf-8', 'replace')
events = ['session-start', 'subagent-start', 'pre-tool-use', 'stop']
for ev in events:
    title = '%s.command.output' % ev
    i = data.find('"title": "%s"' % title)
    if i == -1:
        print('MISSING %s' % title); continue
    s = data.rfind('{\n  "$schema"', 0, i)
    depth, end = 0, None
    for k in range(s, min(len(data), s + 20000)):
        if data[k] == '{': depth += 1
        elif data[k] == '}':
            depth -= 1
            if depth == 0:
                end = k + 1; break
    schema = json.loads(data[s:end])
    path = os.path.join(outdir, 'schema-%s.json' % ev)
    with open(path, 'w') as fh:
        json.dump(schema, fh, indent=2, sort_keys=True)
    print('%s -> %d properties' % (path, len(schema.get('properties', {}))))
PY
