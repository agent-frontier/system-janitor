# system-janitor

Weekly disk-cleanup sweep for this Linux server. Runs unattended via cron.

## Layout

```
~/system-janitor/
├── README.md                  this file
└── system-janitor.sh          main script (idempotent, cron-safe)

~/.local/bin/system-janitor    symlink → system-janitor.sh (for $PATH)
~/.local/state/janitor/        runtime state (logs, lock, summary)
├── janitor.log                human-readable, rotated at 5 MB × 8 backups
├── janitor.jsonl              one JSON event per section (audit trail)
├── last-run.json              latest run summary (atomic-overwrite)
└── janitor.lock               flock mutex (single-instance guard)
```

## What it cleans

| Section | Target |
|---|---|
| `docker_prune` | Unused containers, images, networks, volumes, build cache |
| `go_build_cache` | `~/.cache/go-build` + test cache |
| `tmp_gobuild_orphans` | `/tmp/go-build*` and `/tmp/gopath` (chmod-then-remove) |
| `sandbox_binobj` | All `bin/` and `obj/` under `~/sandbox` (.NET artifacts) |
| `azure_openai_cli_dist` | `~/sandbox/azure-openai-cli/dist` (regenerable AOT output) |
| `nuget_http_temp` | NuGet `http-cache` + `temp` (preserves `global-packages`) |
| `user_cache_copilot` | `~/.cache/copilot` — distinct from `~/.copilot` |

## What it never touches (safety floor)

- `~/.copilot` (any of it: `pkg`, `logs`, `session-state`, `session-store`)
- `~/.nuget/packages` (global packages — too slow to repopulate)
- `~/.dotnet`, `~/.cargo`, `~/go` (toolchains)
- Active venvs (`.venv`) and `node_modules` (lockfile-resolved deps)
- Active Docker containers/images (`docker prune` honors in-use state)
- `/tmp` at large — only the orphaned `go-build*` directories

An integrity check on `~/.copilot` runs at the end of every execution.
Inode + total byte size are compared pre/post; any mismatch exits 2 and
logs `user.err` to syslog.

## Schedule

Cron entry:

```cron
17 3 * * 0 $HOME/.local/bin/system-janitor
```

Sunday 03:17 weekly. Edit with `crontab -e`.

## Manual operations

```bash
# Run now (foreground, logs still captured)
~/.local/bin/system-janitor

# Tail human log
tail -f ~/.local/state/janitor/janitor.log

# Latest run summary
cat ~/.local/state/janitor/last-run.json | python3 -m json.tool

# Total bytes freed across all run_end events
jq -s '[.[] | select(.section=="run_end")] | map(.freed_kb) | add' \
   ~/.local/state/janitor/janitor.jsonl

# Any integrity violations ever?
grep '"violated' ~/.local/state/janitor/janitor.jsonl

# Recent syslog
journalctl -t system-janitor --since '30 days ago'
```

## Exit codes

| Code | Meaning |
|---:|---|
| 0 | success (all sections completed; integrity OK) |
| 1 | another instance running (lock held) |
| 2 | integrity violation (`~/.copilot` disturbed) |
| 3 | precondition failed (e.g., `$HOME` unset) |
