#!/usr/bin/env bash
# bench/build-gold.sh -- build/run bench/gold/tally standalone and run its
# public smoke suite (epic #152, issue #325).
#
# "Build" for a dependency-free ES-module SPA means: every source file
# parses as valid JS (`node --check`), and the app's HTML entry point
# references only files that exist. "Run" means every test/*.smoke.mjs
# under the gold tree exits 0. No network, no bundler, no npm install --
# see bench/README's "Freezing" section: bench/gold/** is part of the
# frozen fixture set.
set -euo pipefail

program=${0##*/}

die() {
    printf '%s: %s\n' "$program" "$1" >&2
    exit 1
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || die 'could not resolve script directory'
gold="$script_dir/gold/tally"

[[ -d $gold ]] || die "gold tree not found: $gold"
command -v node > /dev/null 2>&1 || die 'node is required and was not found on PATH'

printf 'build-gold: checking syntax of every source file under %s/src\n' "$gold"
shopt -s nullglob
src_files=("$gold"/src/*.js)
shopt -u nullglob
[[ ${#src_files[@]} -gt 0 ]] || die "no source files found under $gold/src"
for f in "${src_files[@]}"; do
    node --check "$f" || die "syntax check failed: $f"
done

[[ -f $gold/index.html ]] || die "missing entry point: $gold/index.html"
grep -q '<script type="module" src="./src/main.js">' "$gold/index.html" ||
    die "$gold/index.html does not reference ./src/main.js as its module entry point"
grep -q 'href="./style.css"' "$gold/index.html" ||
    die "$gold/index.html does not link ./style.css (tally-06)"
[[ -f $gold/style.css ]] || die "missing $gold/style.css (tally-06)"

printf 'build-gold: OK -- %d source file(s) parse cleanly, entry point wiring present\n' "${#src_files[@]}"

printf 'build-gold: running the public smoke suite (test/*.smoke.mjs)\n'
shopt -s nullglob
smoke_files=("$gold"/test/*.mjs)
shopt -u nullglob
[[ ${#smoke_files[@]} -gt 0 ]] || die "no smoke test files found under $gold/test"

ran=0
for f in "${smoke_files[@]}"; do
    printf -- '-- %s\n' "${f#"$gold"/}"
    node "$f" || die "smoke test failed: $f"
    ran=$((ran + 1))
done

printf 'build-gold: PASS -- gold tree builds and %d smoke suite(s) passed\n' "$ran"
