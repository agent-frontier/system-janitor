# Agent track

This is the agent-facing track. The primary consumer of system-janitor is
autonomous LLM agents. Pages in this directory are contract-shaped:
regex-scrapeable, tabular, terse.

If you are a human looking for prose and onboarding, start at
[`../../README.md`](../../README.md) and [`../README.md`](../README.md).

## Pages

| Page | What's here |
|---|---|
| [`machine-modes.md`](./machine-modes.md) | Invocation, exit code, and stdout shape for every `--*-json` mode (`--report`, `--health`, `--health-acknowledge`, `--version`, plus `--only`/`--sections` composition). |
| [`contracts.md`](./contracts.md) | Frozen contracts: exit codes, `status` enum, capability discovery rules, the bytes/kb unit canon, and `SECTION_ALIASES` / `OBSOLETE_SECTIONS`. |
| [`recovery.md`](./recovery.md) | The `--health-acknowledge` recovery workflow: how to move from `degraded` back to `healthy` without rewriting an append-only audit log. |
| [`schemas.md`](./schemas.md) | JSON Schema files in [`schemas/`](../../schemas/), how to validate, forward-compat policy. |
| [`toolkit-roadmap.md`](./toolkit-roadmap.md) | Candidate sibling tools that fit the ethos — selection criteria, 15-tool catalog, Bash-vs-Go deliberation, lean-wedge proposal (`cert-watch.sh`). Menu, not commitment. |

## Cross-references

- [`../audit-trail.md`](../audit-trail.md) — `janitor.jsonl` and
  `last-run.json` on-disk shape (the data these machine modes summarize).
- [`../../schemas/`](../../schemas/) — formal Draft 2020-12 JSON Schemas
  for `--report --json` and `--health --json`.
- [`../../.github/copilot-instructions.md`](../../.github/copilot-instructions.md) —
  design north star and architecture brief for agents working *on* the
  script (not just consuming its output).
- [`../../CHANGELOG.md`](../../CHANGELOG.md) — per-release record of
  agent-visible changes (flags, JSON fields, capabilities, exit codes).
