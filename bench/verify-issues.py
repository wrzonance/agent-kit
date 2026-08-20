#!/usr/bin/env python3
"""bench/verify-issues.py -- mechanically verify bench/issues/*.md's
conflict/dependency structure against the design the issue body fixed:

  - exactly ten issue files
  - exactly five "conflicting": two sharing src/render.js, three sharing
    src/store.js
  - exactly five "disjoint": no file overlap with each other or with the
    conflicting five
  - the blocked_by graph is acyclic and its longest chain has depth
    exactly 3 (edges), one under the cap of 4

No network, no third-party imports -- stdlib only, so this runs anywhere
Python 3 runs. Exit 0 and a summary line on success; exit 1 and the first
violation on failure.
"""
import glob
import os
import sys

ISSUES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'issues')


def die(message):
    print(f'verify-issues: {message}', file=sys.stderr)
    sys.exit(1)


def parse_frontmatter(path):
    with open(path, encoding='utf-8') as handle:
        lines = handle.read().splitlines()
    if not lines or lines[0].strip() != '---':
        die(f'{path}: missing opening --- frontmatter delimiter')
    fields = {}
    i = 1
    while i < len(lines) and lines[i].strip() != '---':
        line = lines[i]
        if ':' not in line:
            die(f'{path}: malformed frontmatter line: {line!r}')
        key, _, value = line.partition(':')
        fields[key.strip()] = value.strip()
        i += 1
    else:
        if i >= len(lines):
            die(f'{path}: missing closing --- frontmatter delimiter')
    for required in ('id', 'conflict_group', 'files'):
        if required not in fields:
            die(f'{path}: missing required frontmatter key: {required}')
    files = [f.strip() for f in fields['files'].split(',') if f.strip()]
    blocked_by = [b.strip() for b in fields.get('blocked_by', '').split(',') if b.strip()]
    return {
        'id': fields['id'],
        'conflict_group': fields['conflict_group'],
        'files': files,
        'blocked_by': blocked_by,
        'path': path,
    }


def main():
    paths = sorted(glob.glob(os.path.join(ISSUES_DIR, '*.md')))
    if len(paths) != 10:
        die(f'expected exactly 10 issue files, found {len(paths)}: {paths}')

    issues = [parse_frontmatter(p) for p in paths]
    ids = [i['id'] for i in issues]
    if len(set(ids)) != len(ids):
        die(f'issue ids are not unique: {ids}')
    by_id = {i['id']: i for i in issues}

    render_group = [i for i in issues if i['conflict_group'] == 'render']
    store_group = [i for i in issues if i['conflict_group'] == 'store']
    none_group = [i for i in issues if i['conflict_group'] == 'none']

    if len(render_group) != 2:
        die(f'expected exactly 2 issues in conflict_group=render, found {len(render_group)}')
    if len(store_group) != 3:
        die(f'expected exactly 3 issues in conflict_group=store, found {len(store_group)}')
    if len(none_group) != 5:
        die(f'expected exactly 5 issues in conflict_group=none (disjoint), found {len(none_group)}')

    for i in render_group:
        if i['files'] != ['src/render.js']:
            die(f'{i["id"]}: conflict_group=render must touch exactly src/render.js, got {i["files"]}')
    for i in store_group:
        if i['files'] != ['src/store.js']:
            die(f'{i["id"]}: conflict_group=store must touch exactly src/store.js, got {i["files"]}')

    # Disjoint issues: no file overlap with each other, and none with
    # src/render.js or src/store.js.
    seen_files = {}
    for i in none_group:
        for f in i['files']:
            if f in ('src/render.js', 'src/store.js'):
                die(f'{i["id"]}: disjoint issue must not touch {f}')
            if f in seen_files:
                die(f'file {f} is claimed by both {seen_files[f]} and {i["id"]} '
                    f'-- disjoint issues must not overlap')
            seen_files[f] = i['id']

    # blocked_by graph: every target must exist, and the graph must be acyclic.
    for i in issues:
        for target in i['blocked_by']:
            if target not in by_id:
                die(f'{i["id"]}: blocked_by references unknown id {target}')

    def longest_chain(node_id, visiting, memo):
        if node_id in memo:
            return memo[node_id]
        if node_id in visiting:
            die(f'blocked_by graph has a cycle through {node_id}')
        visiting.add(node_id)
        targets = by_id[node_id]['blocked_by']
        depth = 0
        for target in targets:
            depth = max(depth, 1 + longest_chain(target, visiting, memo))
        visiting.discard(node_id)
        memo[node_id] = depth
        return depth

    memo = {}
    longest = max(longest_chain(i['id'], set(), memo) for i in issues)
    CAP = 4
    if longest != 3:
        die(f'expected longest blocked_by chain depth 3 (one under cap {CAP}), got {longest}')
    if longest >= CAP:
        die(f'longest blocked_by chain depth {longest} meets or exceeds the cap {CAP}')

    print(
        f'PASS verify-issues: 10 issues (2 render-conflict, 3 store-conflict, '
        f'5 disjoint), longest blocked_by chain depth {longest} (cap {CAP})'
    )


if __name__ == '__main__':
    main()
