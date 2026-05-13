# Usage — system-updater

Day-to-day operations for humans. For the full machine-readable
interface (JSON output schemas, exit-code contract, capability strings),
see the [agent track](./agents/updater-machine-modes.md) and
[updater-contracts.md](./agents/updater-contracts.md).

## Preview a run (the default)

```bash
# Dry-run is the default — modifies nothing
system-updater
system-updater --dry-run    # equivalent, explicit
```

The dry-run lists every package that would be upgraded, the
`from_version → to_version` transition, and any packages that would be
held, excluded, or filtered out. It writes a `dry_run`-status entry per
package to the JSONL audit trail and an `updater-last-run.json`
snapshot — the audit-trail shape is identical to a real run.

## Apply updates

```bash
sudo system-updater --apply
```

`--apply`:

- Requires root (exits `2` otherwise).
- Honors `UPDATER_MAINTENANCE_WINDOW` if set (exits `6` outside the
  window unless `--force` is passed).
- Refuses to run alongside `--dry-run` (exits `3`).
- Acquires the `flock` single-instance lock; a second concurrent run
  exits `1`.

## Targeted runs with `--only` / `--exclude`

```bash
# Only consider these package globs
sudo system-updater --apply --only 'curl,openssl,libssl*'

# Apply everything except this glob
sudo system-updater --apply --exclude 'linux-image-*'
```

Globs are matched against package names. Packages excluded by either
flag (or by `UPDATER_HOLD_PACKAGES`) are still recorded in the audit
trail with status `excluded` or `held` respectively, so you can see
what *would* have been upgraded under a different scope.

## Summarize history with `--report`

`--report` rolls up the JSONL audit trail into a per-package summary
(total runs, packages upgraded, packages failed, packages held, idle
streaks, most recent run). Read-only; safe to run any time.

```bash
system-updater --report
system-updater --report --json   # for agents and pipelines
```

The JSON shape is documented in
[agents/updater-machine-modes.md](./agents/updater-machine-modes.md#--report---json)
and pinned by
[`schemas/updater-report.schema.json`](../schemas/updater-report.schema.json).

## Trust probe with `--health`

`--health` is a read-only check over `$UPDATER_LOG_DIR`. Exits with a
code summarizing trust in the audit trail and the apt subsystem.

```bash
system-updater --health
echo $?
# 0 healthy   — every check passes
# 4 degraded  — log dir exists, one or more checks failed
# 5 unknown   — log dir missing or updater-last-run.json absent
```

Checks include `dpkg_unbroken` (no half-configured packages from a
previous interrupted run) and `reboot_not_required` (the
`/var/run/reboot-required` flag is absent). See
[agents/updater-machine-modes.md](./agents/updater-machine-modes.md#--health---json).

To clear historical issues without rewriting the append-only log, use
`--health-acknowledge` — same workflow as the janitor, see
[agents/recovery.md](./agents/recovery.md).

## Common workflows

**Nightly preview, weekly apply:**

```cron
23 2 * * *   $HOME/.local/bin/system-updater --dry-run
# review the report each morning, then on Sunday:
17 3 * * 0   /usr/bin/sudo $HOME/.local/bin/system-updater --apply
```

**Security-only patches with a kernel hold:**

```bash
export UPDATER_SECURITY_ONLY=yes
export UPDATER_HOLD_PACKAGES="linux-image-*"
sudo system-updater --apply
```

**Force apply outside the maintenance window** (audited as forced):

```bash
sudo system-updater --apply --force
```

## Inspect the audit trail

```bash
# Latest run summary
cat ~/.local/state/system-updater/updater-last-run.json | python3 -m json.tool

# Per-package event stream
tail ~/.local/state/system-updater/updater.jsonl

# Recent syslog records
journalctl -t system-updater --since '30 days ago'
```

The on-disk JSONL event shape and status enum are documented in
[agents/updater-contracts.md](./agents/updater-contracts.md). The shared
project-wide contract (exit codes, capability rules) is in
[agents/contracts.md](./agents/contracts.md).
