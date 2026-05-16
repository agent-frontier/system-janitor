# agent-toolkit

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Agent-first ops tools for autonomous LLM agents operating Linux servers
without supervision. Every tool shares one contract: capability discovery
via `--version --json`, structured machine-mode output (`--report --json`,
`--health --json`), append-only JSONL audit trail, atomic state writes,
`flock` single-instance, `--dry-run` default on destructive paths, frozen
exit codes. Humans run them from cron; agents drive them as tools.

The toolkit is deliberately Bash + Linux-specific. Agents can `cat` the
source to understand intent during incident response — no opaque binaries,
no build step, no runtime dependencies beyond what every server already
ships (bash 4+, coreutils, `flock`, `python3` for JSON output).

## Tools shipped today

| Tool | Purpose | State |
|---|---|---|
| [`system-janitor.sh`](system-janitor.sh) | Disk/cache/log cleanup with safety floor and audit-grade logging. Universally-safe ops by default (Docker, Go, NuGet, `/tmp/go-build*`); destructive paths gated behind config. | v0.1.0 |
| [`system-updater.sh`](system-updater.sh) | apt package update sweep with holds, security-only mode, and maintenance windows. `--apply` requires root and is explicit (not the default). | v0.1.0 |

Candidates under consideration live in
[`docs/agents/toolkit-roadmap.md`](docs/agents/toolkit-roadmap.md) —
menu, not commitment.

## Quick install

```bash
git clone https://github.com/agent-frontier/agent-toolkit.git ~/agent-toolkit
ln -s ~/agent-toolkit/system-janitor.sh ~/.local/bin/system-janitor
ln -s ~/agent-toolkit/system-updater.sh ~/.local/bin/system-updater
chmod +x ~/agent-toolkit/system-janitor.sh ~/agent-toolkit/system-updater.sh
system-janitor --dry-run
system-updater --dry-run
```

Per-tool install / config / scheduling: see
[docs/install.md](docs/install.md) (janitor) and
[docs/updater-install.md](docs/updater-install.md) (updater).

## Where to go next

- **[docs/](docs/README.md)** — full documentation index, split by audience.
- **Humans** start at [docs/install.md](docs/install.md) →
  [docs/configuration.md](docs/configuration.md) →
  [docs/usage.md](docs/usage.md).
- **Autonomous agents** start at [docs/agents/README.md](docs/agents/README.md)
  for the shared contract, machine-mode specs, exit codes, schemas, and
  recovery workflows.
- **Shared reference**: [docs/audit-trail.md](docs/audit-trail.md) documents
  the JSONL event shape, status enum, and `last-run.json` schema that all
  tools build on.

## Project files

- [CHANGELOG.md](CHANGELOG.md) — per-release record of agent-visible changes
  (flags, JSON fields, capabilities, exit codes).
- [schemas/](schemas/) — formal Draft 2020-12 JSON Schemas for each tool's
  `--report --json` and `--health --json`.
- [examples/](examples/) — fully-commented sample configs for each tool.
- [LICENSE](LICENSE) — Apache 2.0.

## Development

```bash
bash -n system-janitor.sh system-updater.sh   # syntax check
shellcheck system-janitor.sh system-updater.sh  # static analysis
./tests/smoke.sh                              # janitor: 83 assertions
./tests/updater-smoke.sh                      # updater: 42 assertions
```

CI (`.github/workflows/ci.yml`) runs lint + smoke for both tools on every
push and PR. Smoke suites enforce capability completeness — every string
in `--version --json`'s `capabilities[]` has an end-to-end probe. See
[.github/copilot-instructions.md](.github/copilot-instructions.md) for the
contributor contract.

## License

[Apache 2.0](LICENSE).
