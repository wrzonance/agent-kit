# Shell portability for composed recipes

Agent-composed recipes run in the harness shell, which may be zsh. A fenced
block labelled `bash` does not select Bash by itself. Shipped `.sh` helpers are
different: their Bash shebang is the execution boundary, so Bash constructs
inside those files are valid and should not be rewritten for zsh.

## Multi-line recipe boundary

Treat every multi-line Bash recipe as data and pass it to an explicit Bash
process. This form preserves the recipe bytes before `bash -c` parses them:

```bash
bash -c "$(cat <<'BASH_RECIPE'
set -euo pipefail
# recipe body
BASH_RECIPE
)"
```

The nested quoting is the sharp edge. The quoted heredoc delimiter prevents the
harness shell from expanding `$variables`, backticks, or command substitutions;
the double quotes around `$(...)` keep the resulting script one argument. Bash
then performs the recipe's own quoting and expansion. Choose a different
delimiter if the body contains a line that is exactly `BASH_RECIPE`, and never
interpolate untrusted text into the wrapper. A bare `bash -c '...'` is fragile
when the recipe already contains single quotes.

Single-line commands may run directly only when they intentionally use portable
shell syntax. Do not infer portability from a successful Bash run.

## Bash assumptions that change under zsh

| Bash assumption | zsh behavior | Standing fix |
|---|---|---|
| `mapfile` / `readarray` fills an indexed array | These are Bash builtins, not zsh builtins. | Run the containing recipe through the Bash boundary above. |
| An array index starts at `0`, and `${items[@]}` / `${items[*]}` expands with Bash semantics | Native zsh arrays start at `1` and its unbraced and whole-array expansions differ. | Keep array indexing and expansion inside Bash; do not translate fragments piecemeal. |
| `[[ text =~ regex ]]` populates `${BASH_REMATCH[0]}` and capture indices | zsh normally populates `MATCH` and `match`; its `BASH_REMATCH` compatibility behavior is option-dependent. | Run the match and every capture read in the same Bash process. |
| An unquoted scalar expansion is split on `IFS` | zsh does not enable `SH_WORD_SPLIT` by default. | Quote expansions deliberately and use Bash for recipes whose argument construction relies on Bash word-splitting defaults. |

## Quoting and stdin hazards

| Hazard | Standing fix |
|---|---|
| Multi-line `python3 -c "..."` source breaks when shell quoting crosses lines or the source contains quotes. | Write the program to a temporary file with a quoted heredoc, then run `python3` on that file inside the Bash boundary. |
| A pipe and heredoc both feed one command, as in `producer \| python3 <<'PY'`. The heredoc occupies Python's stdin, so the piped data cannot also be its input. | Write the producer output to a file, then run the heredoc-fed program and have it read that file. |

The Bash boundary fixes the harness-shell mismatch; it does not make nested
quoting, unsafe interpolation, or competing stdin sources correct. Reason about
those separately before running the recipe.
