# system-janitor

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Disk-cleanup sweep with audit-grade logging for long-lived development
hosts. Runs unattended via cron. Designed for hosts where Docker, Go,
.NET, and other toolchains accumulate gigabytes of regenerable build
artifacts week over week.

## Why

Build caches and container layers grow without bound. Most cleanup
scripts are either too aggressive (wipe things you needed) or too
narrow (only clean one toolchain). `system-janitor` runs the
universally-safe operations by default and gates everything that
touches user paths behind explicit configuration.

## Defaults (no config required)

These sections run automatically when the relevant tooling is present.
None of them touch user-owned project files.

| Section | What it does |
|---|---|
| `docker_prune` | `docker system prune -af --volumes` — removes only resources not in use |
| `go_build_cache` | `go clean -cache -testcache` |
| `tmp_gobuild_orphans` | Removes `/tmp/go-build*` and `/tmp/gopath` |
| `nuget_http_temp` | `dotnet nuget locals http-cache --clear` and `temp --clear` (preserves `global-packages`) |

## Opt-in (configure as needed)

These sections do nothing until you set their config knobs.

| Section | Config |
|---|---|
| `workspace_binobj` | `JANITOR_WORKSPACE_DIRS` — colon-separated dirs scanned for `bin/` and `obj/` (`.NET` build outputs) |
| `extra_cleanup` | `JANITOR_EXTRA_CLEANUP_DIRS` — colon-separated dirs to remove entirely |
| `safety_integrity` | `JANITOR_SAFETY_FLOOR_DIRS` — colon-separated dirs whose inode and total byte size must NOT change during the run |

## Install

```bash
git clone https://github.com/agent-frontier/system-janitor.git ~/system-janitor
ln -s ~/system-janitor/system-janitor.sh ~/.local/bin/system-janitor
chmod +x ~/system-janitor/system-janitor.sh
```

(Optional) Copy the example config:

```bash
mkdir -p ~/.config/system-janitor
cp ~/system-janitor/examples/config.example ~/.config/system-janitor/config
$EDITOR ~/.config/system-janitor/config
```

## Schedule

Add to your crontab (`crontab -e`):

```cron
# system-janitor — weekly disk cleanup (Sunday 03:17)
17 3 * * 0 $HOME/.local/bin/system-janitor
```

## Manual operations

```bash
# Preview what would happen
system-janitor --dry-run

# Run now
system-janitor

# Tail human log
tail -f ~/.local/state/janitor/janitor.log

# Latest run summary (machine-readable)
cat ~/.local/state/janitor/last-run.json | python3 -m json.tool

# Total bytes freed across all runs
jq -s '[.[] | select(.section=="run_end")] | map(.freed_kb) | add' \
   ~/.local/state/janitor/janitor.jsonl

# Any integrity violations ever?
grep '"violated' ~/.local/state/janitor/janitor.jsonl

# Recent syslog
journalctl -t system-janitor --since '30 days ago'
```

## Configuration reference

Loaded from (in order of precedence):

1. `--config <path>` command-line flag
2. `$XDG_CONFIG_HOME/system-janitor/config` (default: `~/.config/system-janitor/config`)
3. Environment variables (`JANITOR_*`)
4. Built-in defaults

The config file is sourced as bash, so you can use shell expansions
(`$HOME`, etc.) and comments.

| Variable | Default | Purpose |
|---|---|---|
| `JANITOR_WORKSPACE_DIRS` | (unset) | Colon-separated dirs to scan for `bin/`/`obj/` |
| `JANITOR_EXTRA_CLEANUP_DIRS` | (unset) | Colon-separated dirs to remove entirely |
| `JANITOR_SAFETY_FLOOR_DIRS` | (unset) | Colon-separated dirs whose inode+size must not change |
| `JANITOR_DOCKER_PRUNE` | `yes` | Run `docker system prune` |
| `JANITOR_DOCKER_VOLUMES` | `yes` | Pass `--volumes` to docker prune |
| `JANITOR_GO_CLEAN` | `yes` | Run `go clean -cache -testcache` |
| `JANITOR_TMP_GOBUILD_ORPHANS` | `yes` | Remove `/tmp/go-build*` and `/tmp/gopath` |
| `JANITOR_NUGET_CLEAN` | `yes` | Clear NuGet http-cache and temp |
| `JANITOR_LOG_DIR` | `$XDG_STATE_HOME/janitor` | Where logs live |

See [`examples/config.example`](examples/config.example) for a fully
commented sample.

## Audit trail

Every run produces:

| File | Format | Purpose |
|---|---|---|
| `~/.local/state/janitor/janitor.log` | text | Human-readable narrative |
| `~/.local/state/janitor/janitor.jsonl` | JSONL | One event per section, one event for run_start / run_end / safety_integrity |
| `~/.local/state/janitor/last-run.json` | JSON | Latest run summary (atomic-overwrite) |

JSONL fields per event: `run_id`, `ts`, `host`, `user`, `section`,
`status`, `freed_kb`, `items`, `note`.

Status values: `ok`, `warn`, `dry_run`, `violated_missing`,
`violated_inode_changed`.

Logs rotate at 5 MB with 8 backups kept.

## Safety guarantees

- **Single-instance lock** via `flock` — overlapping cron runs exit 1
- **Safety-floor integrity check** — any directory listed in
  `JANITOR_SAFETY_FLOOR_DIRS` has its inode and total byte size
  compared before and after the run. Any inode change or disappearance
  causes the run to exit 2 and log `user.err` to syslog.
- **Atomic `last-run.json`** — write-then-rename, monitoring tools
  never see partial state
- **`--dry-run`** mode — log what would happen without modifying anything

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | success |
| 1 | another instance running (lock held) |
| 2 | integrity violation (a configured safety-floor dir was disturbed) |
| 3 | precondition failed (e.g., `$HOME` unset, config syntax error) |

## License

[Apache 2.0](LICENSE).
