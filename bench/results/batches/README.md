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

## Worker turns follow-on

`20261027T151340Z-codex-550ff6c.jsonl` preserves the next completed ABBAAB batch:
08c2516 versus 550ff6c (PR #1022), three trials per arm, the same model/effort/CLI
(Codex `gpt-6-luna` / high, CLI 0.164.0), fixture and local harness. All six trials
passed all four hidden tasks and delivered four green PRs; no steers. SHA-256 of the
original export:
`cc881b0bab8b6519a2ab4b4ea6818b0995e0aa78d8e78120f16ec504bde71edf`.

| | 08c2516 median (range) | 550ff6c median (range) |
|---|---:|---:|
| Total tokens including cached input | 1,939,546 (1,867,163–2,339,392) | 1,786,491 (1,356,983–1,835,056) |
| Root tokens | 309,613 (269,877–324,486) | 270,608 (251,042–287,596) |
| Worker tokens | 1,615,060 (1,557,550–2,069,515) | 1,535,449 (1,086,375–1,547,460) |
| Worker tool calls (4 workers) | 67 (65–82) | 65 (47–65) |
| Elapsed seconds | 396 (391–3,939) | 332 (326–402) |
| Root tool calls | 17 (15–18) | 15 (14–16) |
| Recorded wakes | 5 (5–6) | 5 (5–5) |

Medians: total tokens −7.9%, worker tokens −4.9%, root tokens −12.6%, elapsed −16.2%.
Mean tool calls over the twelve workers per arm: 17.8 → 14.8 per worker (−17%).
Total worker tokens per arm: 5.24M → 4.17M (−20%). The candidate's best trial (47 calls,
1.09M worker tokens) sits well below every control trial; its other two trials match the
control's best. Three trials per arm do not establish the size of the saving.

Mechanism, counted in the worker transcripts of this batch (12 workers per arm):
`ak ship` refusals 6 → 0; skill-file reads 0.67 → 0 per worker; `ak setup` 1.0 → 0;
`ak threads` 1.0 → 0; `cat .ak/review.md` after the review 0.33 → 0.58 (unchanged
class; the whole-line output did not remove it). Review findings per PR were similar
in both arms.

Control trial 3 (`20261027T154157Z`) took 3,939 s with 4/4: its root ran a plain
`ak wait` before spawning, that watcher settled wave 1, the root's
`ak wait --check --settle` answered exit 3 `state=settling`, and the root's
`wait_agent` ran its full hour with no child alive before it re-checked. The row
stands for the arm; the path is fixed in #1023 / PR #1024.

Reproduce the delivery, root, and system metrics:
`python3 bench/live/compare.py bench/results/batches/20261027T151340Z-codex-550ff6c.jsonl`.
The command omits elapsed and worker metrics shown above. A four-ref table comes
from concatenating the three saved batch files; keep the
per-batch tables beside it, since the repeated 82093d0 and 08c2516 arms show batch
variation of the same size as the differences between kits.

## Re-spawn names follow-on

`20261027T195115Z-codex-e498a1c.jsonl` preserves the next completed ABBAAB batch:
6ed8f74 (main after #1021, #1022 and #1024 merged) versus e498a1c (PR #1026), three
trials per arm, the same model/effort/CLI (Codex `gpt-6-luna` / high, CLI 0.164.0),
fixture and local harness. All six trials delivered four green PRs; no steers. SHA-256
of the original export:
`224e7eeba0e0d4fef7eeb35e81cc1bfddba7caa1001a5c84a4692f281cc22714`.

| | 6ed8f74 median (range) | e498a1c median (range) |
|---|---:|---:|
| Hidden tasks passed of 4 | 4 (3–4) | 4 (4–4) |
| Total tokens including cached input | 1,447,336 (1,386,437–1,544,463) | 1,406,912 (1,386,204–1,632,530) |
| Root tokens | 288,653 (232,820–306,541) | 309,323 (267,991–325,002) |
| Worker tokens | 1,214,516 (1,079,896–1,255,810) | 1,081,910 (1,076,881–1,364,539) |
| Worker tool calls (4 workers) | 54 (47–54) | 48 (47–60) |
| Elapsed seconds | 275 (268–326) | 275 (275–329) |
| Root tool calls | 16 (14–16) | 17 (15–18) |
| Recorded wakes | 5 (4–5) | 5 (5–6) |

The two arms overlap on every metric: the change renames re-spawned workers and adds
an `ak wait` state for a spawn whose name an ended worker still holds, and this fixture
never parks or replans an issue, so the batch shows no regression rather than the
saving (the hour-long `wait_agent` per replan), which `tests/v2/test-wait.sh` pins.
Control trial `20261027T200916Z` passed 3/4: the worker for one task shipped a green PR
with a clean review that failed its hidden check, on the unchanged control kit.

Reproduce the delivery, root, and system metrics:
`python3 bench/live/compare.py bench/results/batches/20261027T195115Z-codex-e498a1c.jsonl`.
Keep this table beside the earlier ones: both arms here sit below the previous batch's
550ff6c arm on total tokens by 20% with the same kit bytes, which is batch variation.
