#!/usr/bin/env python3
"""Classify a trial's gh-shim log into GraphQL and REST calls. Usage: gh-calls.py LOG

gh porcelain (pr/issue/project/repo/run/search) rides GraphQL; `gh api PATH` is REST unless PATH is graphql.
"""
import json
import sys
from collections import Counter

GRAPHQL_PORCELAIN = {"pr", "issue", "project", "repo", "search", "label", "release"}


def kind(args: list[str]) -> str:
    if not args:
        return "other"
    if args[0] == "api":
        rest = [a for a in args[1:] if not a.startswith("-")]
        return "graphql" if rest and rest[0] == "graphql" else "rest"
    if args[0] in GRAPHQL_PORCELAIN:
        return "graphql"
    return "other"


def main(path: str) -> int:
    counts, verbs = Counter(), Counter()
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            _, _, rest = line.rstrip("\n").partition("\t")
            args = rest.split()
            k = kind(args)
            counts[k] += 1
            if k == "graphql":
                verbs[" ".join(args[:2])] += 1
    print(json.dumps({"calls": sum(counts.values()), "graphql": counts["graphql"], "rest": counts["rest"],
                      "other": counts["other"], "graphql_top": dict(verbs.most_common(5))}, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
