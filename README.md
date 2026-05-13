# system-janitor

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Disk-cleanup sweep with audit-grade logging for long-lived development hosts.

Build caches and container layers grow without bound. Most cleanup scripts are
either too aggressive (wipe things you needed) or too narrow (only clean one
toolchain). `system-janitor` runs the universally-safe operations by default
(Docker, Go, NuGet http/temp caches, `/tmp/go-build*` orphans) and gates
everything that touches user paths behind explicit configuration. It is
designed to run unattended via cron on hosts where Docker, Go, .NET, and
other toolchains accumulate gigabytes of regenerable build artifacts week
over week.

Safety is the headline feature: a `flock` single-instance lock, an optional
inode+byte safety-floor integrity check over directories you nominate,
atomic-rename writes to `last-run.json`, and a first-class `--dry-run` mode.
See [docs/safety.md](docs/safety.md) for the full list of guarantees.

The primary consumer is an autonomous LLM agent. Every machine-mode output
is stable JSON with a documented schema and a frozen exit-code contract;
`--version --json` exposes a `capabilities[]` feature-detection surface so
agents can negotiate features without parsing `--help`. Humans run it from
cron; agents drive it as a tool.

## Quick install

```bash
git clone https://github.com/agent-frontier/system-janitor.git ~/system-janitor
ln -s ~/system-janitor/system-janitor.sh ~/.local/bin/system-janitor
chmod +x ~/system-janitor/system-janitor.sh
system-janitor --dry-run
```

That last command previews a real run without touching anything. For cron
scheduling, optional config, and verification, see
[docs/install.md](docs/install.md).

## Sibling tool: system-updater

This repo also ships [`system-updater.sh`](system-updater.sh) — an
apt-update sibling sharing the same agent contract (dry-run-by-default,
JSONL audit trail, `--report --json` / `--health --json` machine modes,
capability discovery). v0 is apt-only and dry-runs by default;
`--apply` requires root. See
[docs/updater-install.md](docs/updater-install.md).

## Where to go next

- **[docs/](docs/README.md)** — full documentation index, split by audience.
- **Humans** start at [docs/install.md](docs/install.md) →
  [docs/configuration.md](docs/configuration.md) →
  [docs/usage.md](docs/usage.md).
- **Autonomous agents** start at [docs/agents/README.md](docs/agents/README.md)
  for machine-mode specs, exit codes, schemas, and recovery workflows.
- **Shared reference**: [docs/audit-trail.md](docs/audit-trail.md) documents
  the JSONL event shape, status enum, and `last-run.json` schema that both
  tracks build on.

## Project files

- [CHANGELOG.md](CHANGELOG.md) — per-release record of agent-visible changes
  (flags, JSON fields, capabilities, exit codes).
- [schemas/](schemas/) — formal Draft 2020-12 JSON Schemas for `--report --json`
  and `--health --json`.
- [examples/config.example](examples/config.example) — fully-commented sample
  config.
- [LICENSE](LICENSE) — Apache 2.0.

## Development

```bash
bash -n system-janitor.sh        # syntax check
shellcheck system-janitor.sh     # static analysis
./tests/smoke.sh                 # dry-run + audit-trail invariants
```

CI (`.github/workflows/ci.yml`) runs all three on every push and PR. The
smoke suite enforces capability completeness — every string in
`--version --json`'s `capabilities[]` has an end-to-end probe. See
[.github/copilot-instructions.md](.github/copilot-instructions.md) for the
contributor contract.

## License

[Apache 2.0](LICENSE).
