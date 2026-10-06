---
name: onboard
description: Set up a repository for ak by writing .agent/config.env from what the repository and its GitHub project already say, then proving the declared commands. Use for "/onboard", "onboard this repo", "set up ak here", or when `ak plan` refuses with "no project board or ready label configured".
---

# onboard

`ak` is `<this skill's directory>/../../bin/ak`, run from the repository root. Pass the operator's flags
(`--project N --owner O`) straight through. `.agent/config.env` is plain `KEY=value` lines; `ak onboard` adds the
keys it discovers and keeps every line already there, so running it again is safe.

1. Run `ak onboard [flags]`. It prints each key it wrote, a `board=` line and a `next=` line.
2. `board=choose` lists the boards the repository is linked to: ask the operator which one, then run the `fix:`
   command it printed with that number. `board=none` is fine for a repository worked by label or by `--issue N`.
3. `commands=none`: find the test command CI runs (the `run:` steps in `.github/workflows/*.yml`, else the
   README) and append `AGENT_CMD_TEST=<command>` to `.agent/config.env`, plus `AGENT_CMD_SETUP=<install command>`
   when it needs one.
4. Run the `next=` command. `verify=pass` proves the declared commands. On `FAIL <name>`, the log it names says
   why: correct that `AGENT_CMD_` line in `.agent/config.env` and run the `next=` command once more.
5. Report the `ak onboard` lines and the verify result, then stop. Committing `.agent/config.env` is the operator's
   call: ak reads it from the checkout, so worktrees need nothing more.
