# Install — system-updater

`system-updater` is a sibling tool to `system-janitor`, shipped from the
same repo. It applies apt package updates with the same audit-grade
logging, dry-run-by-default safety stance, and machine-readable agent
contract as the janitor. v0 supports the `apt` backend only.

For the cleanup tool, see [install.md](./install.md).

## Prerequisites

- Linux with `bash` 4+, `flock`, `python3`, and `coreutils`.
- An `apt`-based distribution (Debian, Ubuntu, etc.) for real `--apply`
  runs. The `stub` backend works anywhere and is the default in tests.
- `sudo` (or another privilege-elevation mechanism) for `--apply` —
  package installs require root. `--dry-run` is the default and runs
  unprivileged.

## Install

`system-updater.sh` lives next to `system-janitor.sh` in the cloned repo.
The same checkout serves both tools.

```bash
git clone https://github.com/agent-frontier/system-janitor.git ~/system-janitor
ln -s ~/system-janitor/system-updater.sh ~/.local/bin/system-updater
chmod +x ~/system-janitor/system-updater.sh
```

Make sure `~/.local/bin` is on your `$PATH`. Verify:

```bash
system-updater --version
# → system-updater 0.1.0
```

## Optional: install a config file

Defaults are safe (dry-run, no holds, no maintenance window). You only
need a config file to enable holds, scope updates to security-only, or
restrict to a maintenance window. See
[updater-configuration.md](./updater-configuration.md) for the full
reference.

```bash
mkdir -p ~/.config/system-updater
cp ~/system-janitor/examples/updater.config.example ~/.config/system-updater/config
$EDITOR ~/.config/system-updater/config
```

The file is sourced via `--config <path>` or the `UPDATER_CONFIG_FILE`
environment variable.

## Schedule with cron

The recommended pattern is **dry-run nightly, manual `--apply` on
demand**. The dry-run produces a fresh audit-trail event you can inspect
before deciding to apply. `--apply` requires root and should not run
unattended in v0 (no real auto-reboot, no real snapshot detection — see
the roadmap in [CHANGELOG.md](../CHANGELOG.md)).

```cron
# system-updater — nightly dry-run preview (every day, 02:23)
23 2 * * * $HOME/.local/bin/system-updater --dry-run
```

Apply manually after reviewing the preview:

```bash
sudo system-updater --apply
```

`--apply` without root exits `2` (pre-flight failure). The
`flock`-based single-instance lock refuses to start a second run if one
is already in progress (exit `1`).

## Verify it ran

After the first run, three artifacts appear under
`~/.local/state/system-updater/`:

```bash
# Latest run summary (machine-readable, atomic-overwrite)
cat ~/.local/state/system-updater/updater-last-run.json | python3 -m json.tool

# Audit trail (one JSON event per package per run, plus run_start/run_end)
tail ~/.local/state/system-updater/updater.jsonl

# High-level rollup across all runs
system-updater --report

# One-shot trust probe
system-updater --health && echo "audit trail healthy"
```

See [updater-usage.md](./updater-usage.md) for the full set of manual
operations and [docs/agents/updater-machine-modes.md](./agents/updater-machine-modes.md)
for the JSON output schemas.
