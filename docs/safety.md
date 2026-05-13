# Safety guarantees

`system-janitor` is designed to be safe to schedule on a long-lived host
and forget about. Every guarantee below is enforced by the script, not by
convention.

## Guarantees

- **Single-instance lock via `flock`.** If a previous cron-launched run
  is still in progress, the new invocation exits `1` immediately without
  acquiring the lock. No overlapping runs, ever.

- **Safety-floor integrity check.** Any directory listed in
  `JANITOR_SAFETY_FLOOR_DIRS` is inode-and-byte-snapshotted before the
  run and verified after. Any inode change, total-byte-size change, or
  disappearance causes the run to exit `2` and log `user.err` to syslog.
  This is the mechanism by which you declare "these paths are off-limits
  to this tool" — your home `src/` tree, dotfile dirs, etc.

- **Never deletes outside known paths.** Default sections only invoke
  toolchain-provided cleanup commands (`docker system prune`,
  `go clean -cache`, `dotnet nuget locals`) and remove `/tmp/go-build*`
  orphans. They never touch user-owned project files. The two sections
  that *can* touch user paths — `workspace_binobj` and `extra_cleanup` —
  do nothing until you explicitly point them at directories via config.

- **Atomic `last-run.json`.** The run summary is written to a temp file
  and atomically renamed into place. Monitoring tools, dashboards, or
  agents reading the file will never see partial state, even if the run
  is killed mid-write.

- **First-class `--dry-run` mode.** `--dry-run` runs every section's
  inspection logic, reports what *would* be removed (item counts,
  pre-state), and writes JSONL/`last-run.json` entries with
  `status: "dry_run"` — but modifies nothing on disk. The audit-trail
  shape is identical to a real run, so you can validate config changes
  before turning them loose.

- **Read-only inspection flags.** `--report`, `--health`,
  `--health-acknowledge`, and `--version` never acquire the lock and
  never write to any cleanup target. `--health` and `--report` are even
  safe to run *concurrently* with an in-progress cleanup.

- **Toolchain-aware skipping.** Missing toolchains are silently skipped,
  not errors. The same script runs unchanged on a Go-only host, a
  Docker-only host, or a fully-equipped dev box.

- **Append-only audit trail.** `janitor.jsonl` is never rewritten in
  place; it grows append-only and rotates at 5 MB with 8 backups kept.
  Historical issues are cleared via the
  [`--health-acknowledge` recovery workflow](./agents/recovery.md), not
  by editing the log.

- **Stable machine-mode contract.** Exit codes, JSON field names, and
  capability strings are a frozen public contract documented in
  [agents/contracts.md](./agents/contracts.md). Renaming or removing
  fields is a breaking change requiring a major-version bump.

## How they compose for a typical cron schedule

A weekly cron entry on a host with `JANITOR_SAFETY_FLOOR_DIRS` set to
your important source trees gets you:

1. At most one run executing at a time (`flock`).
2. A hard guarantee that your nominated trees were not disturbed
   (safety floor + exit 2 on violation).
3. A complete audit trail you can reconstruct months later
   (`janitor.jsonl` + `last-run.json` + syslog).
4. A trust probe you can wire into monitoring (`--health` exit codes).
5. A safe way to test config changes (`--dry-run` with identical
   audit-trail shape).
