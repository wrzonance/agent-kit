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

## Worker context follow-on

`20261027T030637Z-codex-08c2516.jsonl` preserves the next completed ABBAAB batch:
82093d0 versus 08c2516, three trials per arm, the same model/effort/CLI and local
harness. All six trials passed all four hidden tasks and delivered four green PRs;
there were no timeouts or operator steers. SHA-256 of the original export:
`f28a33b62f02eaff2a240011c712110d47e0091e11e62767a4734ace9cfd3ca4`.

| Median | Original baseline (earlier batch) | 82093d0 (earlier) | 82093d0 (rerun) | 08c2516 |
|---|---:|---:|---:|---:|
| Total tokens including cached input | 2,630,467 | 2,339,248 | 2,154,792 | 2,195,775 |
| Root tokens | 430,422 | 464,388 | 495,510 | 290,808 |
| Worker tokens | 2,200,045 | 1,897,416 | 1,659,282 | 1,889,122 |
| Elapsed seconds | 339 | 340 | 390 | 331 |
| Root tool calls | 15 | 18 | 18 | 16 |
| Recorded wakes | 4 | 5 | 5 | 5 |

Within the new batch, median root tokens fell 41.3%, runtime fell 15.1%, and
root calls fell 11.1%. Median worker tokens rose 13.9%, leaving total tokens
1.9% higher. The latest total-token range is 1.80M–2.84M; three trials per arm
are insufficient to establish an additional total-token improvement.

Relative to the saved original baseline, the latest median total is 16.5% lower,
root tokens 32.4% lower, and runtime 2.4% lower. That is a historical comparison,
not a contemporaneous control. The repeated 82093d0 arm exposes batch variation.
Medians for root, worker and total are calculated independently.

Reproduce the direct comparison:

```bash
python3 bench/live/compare.py bench/results/batches/20261027T030637Z-codex-08c2516.jsonl
```

For a three-ref table, concatenate the two saved JSONL files into a temporary
ledger and run `compare.py` on it. Keep the separate batch comparisons alongside
that pooled table. These measurements cover Codex; Claude live savings remain
unmeasured. No model, scorer or acceptance changes were made between these batches.
