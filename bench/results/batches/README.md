# Wave-wait comparison points

`20261026T232111Z-codex-82093d0.jsonl` is the unchanged six-row export from the
operator's completed ABBAAB batch: baseline `43e3c42` versus `82093d0` (full
SHAs in each row), three trials per arm, Codex `gpt-6-luna` / high, CLI 0.164.0.
All trials delivered four green draft PRs and passed all four hidden acceptance tasks.

Run `python3 bench/live/compare.py bench/results/batches/20261026T232111Z-codex-82093d0.jsonl`
to reproduce the comparison. SHA-256 of the original export:
`21d0392861522d933d5bed2bea89a3400d084233c5034c71f3f22291d634e320`.

| Median | Baseline | 82093d0 |
|---|---:|---:|
| Total tokens (including cached input) | 2,630,467 | 2,339,248 |
| Root tokens | 430,422 | 464,388 |
| Worker tokens | 2,200,045 | 1,897,416 |
| Elapsed seconds | 339 | 340 |
| Root tool calls | 15 | 18 |
| Recorded wakes | 4 | 5 |

Total tokens fell 11.1% in this batch; three trials per arm do not establish
causality. Root tokens increased 7.9%. Wakes count wait returns plus the initial
human prompt. The candidate's two failed execs are expected pending exit-3 checks.
All candidate roots planned once and settled each ready wave in the check call.

The operator ran the harness from the bench worktree at 82093d0 with local
lifecycle fixes in `batch.sh`, `trial-tui.sh`, and their fixture/tests (progress
messages and ended-root detection). These remain local in that worktree. Keep
that harness unchanged for the next comparison; the arm refs select kit versions.
No prompts or raw session transcripts are included here.

For the next batch compare 82093d0 against the new candidate, then concatenate
that batch-only export with this file into a temporary ledger for a three-ref
table. The old baseline is historical; the repeated 82093d0 arm helps expose
changes between batches. Keep the separate batch comparisons alongside the
combined table rather than treating historical trials as contemporaneous.
