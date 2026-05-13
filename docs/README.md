# system-janitor documentation

This repo hosts two sibling tools sharing the same agent contract:
`system-janitor` (disk cleanup) and `system-updater` (apt updates).
Both are cron-driven, dry-run-by-default, and emit the same shape of
audit-grade machine-readable output. The docs are split into two tracks
per tool: a friendly human track for operators who install and configure
them, and a precise agent track for autonomous LLM agents that drive
them as tools. The two tracks share one reference doc —
[audit-trail.md](./audit-trail.md) — which documents the on-disk
audit-log contract the janitor track builds on. (The updater's
on-disk shape is documented in
[agents/updater-contracts.md](./agents/updater-contracts.md).)

## For humans — system-janitor

| Doc | What's in it |
|---|---|
| [install.md](./install.md) | Install steps, default paths, cron scheduling, verifying it ran |
| [configuration.md](./configuration.md) | Environment variables, config file precedence, defaults vs. opt-in |
| [usage.md](./usage.md) | Manual operations: `--dry-run`, `--only`, `--report`, `--health`, log tailing |
| [safety.md](./safety.md) | Safety guarantees — why this is safe to cron on a long-lived host |

## For humans — system-updater

| Doc | What's in it |
|---|---|
| [updater-install.md](./updater-install.md) | Install steps, cron scheduling (dry-run nightly), `--apply` requires root |
| [updater-configuration.md](./updater-configuration.md) | `UPDATER_*` environment variables, holds, security-only, maintenance window |
| [updater-usage.md](./updater-usage.md) | Manual operations: dry-run preview, `--apply`, `--report`, `--health`, common workflows |

## For autonomous agents

| Doc | What's in it |
|---|---|
| [agents/README.md](./agents/README.md) | Agent-track entry point and orientation |
| [agents/contracts.md](./agents/contracts.md) | **Project-wide** shared contracts: exit codes, status enum, capability rules, unit canon |
| [agents/machine-modes.md](./agents/machine-modes.md) | janitor: `--report --json`, `--health --json`, `--version --json`, `--health-acknowledge` |
| [agents/updater-machine-modes.md](./agents/updater-machine-modes.md) | updater: `--report --json`, `--health --json`, `--version --json`, `--health-acknowledge`, `--apply` |
| [agents/updater-contracts.md](./agents/updater-contracts.md) | updater-only deltas: `UPDATER_*` namespace, status extensions, exit codes 6/7, capabilities[] |
| [agents/recovery.md](./agents/recovery.md) | `--health-acknowledge` workflow for clearing historical issues (applies to both tools) |
| [agents/schemas.md](./agents/schemas.md) | Formal JSON Schema reference |

## Shared reference

| Doc | What's in it |
|---|---|
| [audit-trail.md](./audit-trail.md) | JSONL event shape, status enum, `last-run.json` v0.2 schema — the on-disk contract both tracks build on |

## Cross-references

- [../README.md](../README.md) — project overview and quick install
- [../CHANGELOG.md](../CHANGELOG.md) — per-release record of agent-visible changes
- [../schemas/](../schemas/) — formal Draft 2020-12 JSON Schemas (janitor + updater)
- [../examples/config.example](../examples/config.example) — commented sample janitor config
- [../examples/updater.config.example](../examples/updater.config.example) — commented sample updater config
- [../LICENSE](../LICENSE) — Apache 2.0
