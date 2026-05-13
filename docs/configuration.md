# Configuration

`system-janitor` works out of the box with no config: the default sections
clean caches that are universally safe to regenerate. You only need to
configure it when you want to opt into a user-path-touching section.

## Precedence

Configuration is loaded in this order (later sources override earlier ones):

1. Built-in defaults
2. Environment variables (`JANITOR_*`)
3. `$XDG_CONFIG_HOME/system-janitor/config` (default: `~/.config/system-janitor/config`)
4. `--config <path>` command-line flag

The config file is **sourced as bash**, so shell expansions (`$HOME`,
`$(cmd)`) and comments work. See
[examples/config.example](../examples/config.example) for a fully-commented
sample.

## Defaults — run automatically when the toolchain is present

These sections require no config. None of them touch user-owned project
files; they only clear caches the toolchain knows how to regenerate.

| Section | What it does |
|---|---|
| `docker_prune` | `docker system prune -af --volumes` — removes only resources not in use |
| `go_build_cache` | `go clean -cache -testcache` |
| `tmp_gobuild_orphans` | Removes `/tmp/go-build*` and `/tmp/gopath` |
| `nuget_http_temp` | `dotnet nuget locals http-cache --clear` and `temp --clear` (preserves `global-packages`) |

## Opt-in — do nothing until you set their config knobs

| Section | Config |
|---|---|
| `workspace_binobj` | `JANITOR_WORKSPACE_DIRS` — colon-separated dirs scanned for `bin/` and `obj/` (.NET build outputs) |
| `extra_cleanup` | `JANITOR_EXTRA_CLEANUP_DIRS` — colon-separated dirs to remove entirely |
| `safety_integrity` | `JANITOR_SAFETY_FLOOR_DIRS` — colon-separated dirs whose inode and total byte size must NOT change during the run |

## Environment variable reference

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
| `JANITOR_LOG_DIR` | `$XDG_STATE_HOME/janitor` (i.e. `~/.local/state/janitor`) | Where logs and `last-run.json` live |

## Safety constraints on configured paths

- `JANITOR_EXTRA_CLEANUP_DIRS` removes the listed directories entirely.
  Only point this at directories you have already decided are disposable
  (build output dirs, package download caches you don't want preserved).
- `JANITOR_SAFETY_FLOOR_DIRS` is the trust anchor. Listed directories are
  inode-and-byte-snapshotted before the run and verified after. Any inode
  change or disappearance fails the run with exit code 2 and logs
  `user.err` to syslog. Use this to declare "these paths are off-limits
  to this tool" — your home directory's `src/` tree, for example.
- See [safety.md](./safety.md) for the complete guarantee list.

## Example: enabling workspace `bin/`/`obj/` cleanup with a safety floor

```bash
# ~/.config/system-janitor/config
JANITOR_WORKSPACE_DIRS="$HOME/work:$HOME/repos"
JANITOR_SAFETY_FLOOR_DIRS="$HOME/Documents:$HOME/.ssh"
```

Now `workspace_binobj` will scan `$HOME/work` and `$HOME/repos` for `bin/`
and `obj/` directories, and the run will hard-fail (exit 2) if anything
under `$HOME/Documents` or `$HOME/.ssh` is disturbed during execution.
