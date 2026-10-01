#!/usr/bin/env python3
"""Compare live-trial rows by arm: median and range per metric, plus delivered work.

Usage: compare.py [LEDGER] [--fixture PREFIX]

Rows group by (fixture, kit, ref[:7], model, effort). A trial that delivered less work must not look cheaper,
so the table puts acceptance passes next to the cost columns, and tokens per passed issue beside the totals.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

DEFAULT = Path(__file__).resolve().parents[1] / "results" / "live.jsonl"
METRICS = [
    ("passed", lambda r: r.get("outcome", {}).get("passed")),
    ("prs green", lambda r: r.get("outcome", {}).get("prs_green")),
    ("root calls", lambda r: r.get("root", {}).get("calls")),
    ("root Mtok", lambda r: mtok(r.get("root", {}).get("tokens", {}).get("total_tokens"))),
    ("system Mtok", lambda r: mtok(r.get("system_tokens"))),
    ("Mtok / pass", lambda r: per_pass(r)),
    ("calls to spawn", lambda r: (r.get("root", {}).get("first_spawn") or {}).get("calls")),
    ("min to spawn", lambda r: minutes((r.get("root", {}).get("first_spawn") or {}).get("wall_s"))),
    ("active min", lambda r: minutes(r.get("root", {}).get("active_s"))),
    ("--help", lambda r: r.get("root", {}).get("help_calls")),
    ("failed exec", lambda r: r.get("root", {}).get("failed_exec")),
    ("kit KB read", lambda r: kb(r.get("root", {}).get("kit_read_bytes"))),
    ("steers", lambda r: r.get("root", {}).get("steers")),
]


def mtok(v):
    return None if v is None else round(v / 1e6, 2)


def minutes(v):
    return None if v is None else round(v / 60, 1)


def kb(v):
    return None if v is None else round(v / 1024)


def per_pass(row):
    passed = row.get("outcome", {}).get("passed")
    total = row.get("system_tokens")
    if not passed or total is None:
        return None
    return round(total / passed / 1e6, 2)


def cell(values):
    values = [v for v in values if v is not None]
    if not values:
        return "-"
    med = statistics.median(values)
    med = round(med, 2) if isinstance(med, float) else med
    if len(values) == 1:
        return f"{med}"
    return f"{med} ({min(values)}–{max(values)})"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ledger", nargs="?", type=Path, default=DEFAULT)
    parser.add_argument("--fixture", default="", help="only rows whose fixture starts with this")
    args = parser.parse_args(argv)
    groups = defaultdict(list)
    for line in args.ledger.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        if not str(row.get("fixture", "")).startswith(args.fixture):
            continue
        key = (row.get("fixture", "?"), row.get("kit", "?"), str(row.get("ref", "?"))[:7],
               row.get("model", "?"), row.get("effort", "?"))
        groups[key].append(row)
    if not groups:
        print("no rows")
        return 1
    header = ["fixture", "kit", "ref", "model", "n"] + [name for name, _ in METRICS]
    print("| " + " | ".join(header) + " |")
    print("|" + "---|" * len(header))
    for key in sorted(groups):
        rows = groups[key]
        fixture, kit, ref, model, effort = key
        cells = [fixture, kit, ref, f"{model}/{effort}", str(len(rows))]
        cells += [cell([fn(r) for r in rows]) for _, fn in METRICS]
        print("| " + " | ".join(cells) + " |")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
