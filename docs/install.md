# Install

`system-janitor` is a single bash script with no runtime dependencies beyond
the toolchains it cleans (Docker, Go, .NET) — and it skips any toolchain that
isn't installed, so the same script works on a Go-only host or a
Docker-only host without configuration.

## Prerequisites

- Linux or macOS with `bash` 4+, `flock`, `python3` (for JSON emit), and
  `coreutils`
- The toolchains you want cleaned, on `$PATH` (`docker`, `go`, `dotnet`).
  Missing toolchains are silently skipped — they are not errors.

## Install

```bash
git clone https://github.com/agent-frontier/agent-toolkit.git ~/agent-toolkit
ln -s ~/agent-toolkit/system-janitor.sh ~/.local/bin/system-janitor
chmod +x ~/agent-toolkit/system-janitor.sh
```

Make sure `~/.local/bin` is on your `$PATH`. Verify:

```bash
system-janitor --version
# → system-janitor 0.1.0
```

## Optional: install a config file

The default sections (Docker prune, Go cache clean, `/tmp/go-build*`
orphans, NuGet http/temp cache) run without any config. You only need a
config file if you want to enable an opt-in section like `workspace_binobj`
or `safety_integrity`. See [configuration.md](./configuration.md) for the
full reference.

```bash
mkdir -p ~/.config/system-janitor
cp ~/agent-toolkit/examples/config.example ~/.config/system-janitor/config
$EDITOR ~/.config/system-janitor/config
```

## Schedule with cron

Add a weekly entry with `crontab -e`:

```cron
# system-janitor — weekly disk cleanup (Sunday 03:17)
17 3 * * 0 $HOME/.local/bin/system-janitor
```

Pick an odd minute (e.g. `:17`) rather than `:00` to avoid colliding with
every other cron job on the host. The `flock`-based single-instance lock
will refuse to start a second run if one is still in progress — see
[safety.md](./safety.md).

## Verify it ran

After the first scheduled run (or after running `system-janitor` manually
once), three artifacts appear under `~/.local/state/janitor/`:

```bash
# Latest run summary (machine-readable, atomic-overwrite)
cat ~/.local/state/janitor/last-run.json | python3 -m json.tool

# Human narrative log (tail to watch live)
tail -f ~/.local/state/janitor/janitor.log

# Audit trail (one JSON event per section per run)
tail ~/.local/state/janitor/janitor.jsonl

# Recent syslog records
journalctl -t system-janitor --since '30 days ago'
```

For a high-level summary across all past runs:

```bash
system-janitor --report
```

For a one-shot trust probe over the audit trail (useful as a cron-adjacent
health check):

```bash
system-janitor --health && echo "audit trail healthy"
```

See [usage.md](./usage.md) for the full set of manual operations.
