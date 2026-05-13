# Machine modes — system-updater

Every machine mode is read-only, runs BEFORE flock / `mkdir
$UPDATER_LOG_DIR` / log redirects, and is safe to invoke concurrently
with an in-progress `--apply`. Output is ANSI-free and
Unicode-glyph-free; the human variants (no `--json`) may use glyphs.

`--json` is only valid with `--report`, `--health`,
`--health-acknowledge`, or `--version`. Used alone it exits `3`.

For the project-wide shared contract (capability rules, unit canon,
common exit codes), see [contracts.md](./contracts.md). For
updater-specific deltas (UPDATER_* env namespace, status enum
extensions, exit codes 6/7), see
[updater-contracts.md](./updater-contracts.md).

## `--report`

Audit-trail rollup over `$UPDATER_LOG_DIR/updater.jsonl`.

- Invocation: `system-updater --report` (text) or `system-updater --report --json`.
- Exit codes: `0` always (missing/empty JSONL still emits a valid object with zero counts; invalid lines surface via `data_quality` without flipping exit).
- Schema: [`schemas/updater-report.schema.json`](../../schemas/updater-report.schema.json).
- Composes with `--only` / `--exclude` (filters `per_package`).

```json
{
  "log_dir": "/home/u/.local/state/system-updater",
  "jsonl_path": "/home/u/.local/state/system-updater/updater.jsonl",
  "generated_at": "2026-05-12T01:00:00+0000",
  "total_runs": 14,
  "real_runs": 2,
  "dry_runs": 12,
  "total_packages_upgraded": 47,
  "total_packages_failed": 0,
  "total_packages_held": 8,
  "date_range": {"first": "2026-04-29T03:23:00+0000", "last": "2026-05-12T00:55:00+0000"},
  "per_package": [
    {"name": "openssl", "runs": 14, "upgraded": 2, "failed": 0, "held": 0,
     "status_counts": {"ok": 2, "dry_run": 12},
     "last_from_version": "3.0.11-1ubuntu2", "last_to_version": "3.0.13-0ubuntu3"}
  ],
  "most_recent_run": {
    "run_id": "20260512T005500Z-9af1c4d2",
    "finished": "2026-05-12T00:55:03+0000",
    "dry_run": 1,
    "packages_upgraded": 0,
    "packages_failed": 0,
    "packages_held": 8,
    "reboot_required": false
  },
  "data_quality": {"invalid_lines": 0, "examples": []},
  "idle_streaks": [
    {"package": "ca-certificates", "consecutive_idle_runs": 14, "last_productive_run": null}
  ]
}
```

Notes:

- `per_package` sorted by `upgraded` desc, then `name` asc.
- `idle_streaks` sorted by `consecutive_idle_runs` desc, threshold `>= 2`.
- `runs` counts real + dry; `upgraded` / `failed` count REAL runs only.
- `most_recent_run` is `null` when no `run_end` event exists.

## `--health`

Read-only trust probe over the audit trail and the apt subsystem. Does
not acquire the lock or create the log dir.

- Invocation: `system-updater --health` or `... --health --json`.
- Exit codes: `0` healthy, `4` degraded, `5` unknown (log dir missing OR `updater-last-run.json` absent).
- Schema: [`schemas/updater-health.schema.json`](../../schemas/updater-health.schema.json).

Checks (frozen names; the schema enum locks them in):

| Name | Passes when |
|---|---|
| `log_dir_exists` | `$UPDATER_LOG_DIR` is a directory |
| `jsonl_present` | `updater.jsonl` exists and non-empty |
| `jsonl_parses` | every non-baseline line parses as JSON |
| `last_run_parses` | `updater-last-run.json` exists and is valid JSON |
| `last_run_packages` | `updater-last-run.json.packages[]` is well-formed |
| `dpkg_unbroken` | `dpkg --audit` reports no half-configured packages (skipped on non-apt hosts; treated as `ok`) |
| `reboot_not_required` | `/var/run/reboot-required` is absent |

```json
{
  "status": "degraded",
  "exit_code": 4,
  "generated_at": "2026-05-12T01:00:00+0000",
  "log_dir": "/home/u/.local/state/system-updater",
  "checks": [
    {"name": "log_dir_exists",       "ok": true,  "detail": "/home/u/.local/state/system-updater"},
    {"name": "jsonl_present",        "ok": true,  "detail": "212 events"},
    {"name": "jsonl_parses",         "ok": true,  "detail": "0 invalid lines"},
    {"name": "last_run_parses",      "ok": true,  "detail": null},
    {"name": "last_run_packages",    "ok": true,  "detail": "47 packages"},
    {"name": "dpkg_unbroken",        "ok": true,  "detail": "no broken packages"},
    {"name": "reboot_not_required",  "ok": false, "detail": "/var/run/reboot-required present"}
  ]
}
```

`jsonl_parses.detail` follows the same regex contract as the janitor:
when malformed lines exist, the field MUST lead with `N invalid line(s)`.
Regex: `^\d+ invalid lines?\b`.

## `--health-acknowledge`

Writes a byte offset to `$UPDATER_LOG_DIR/.health-baseline` (atomic
tmp+rename). Subsequent `--health` probes exclude lines whose start
offset is `< baseline` from `jsonl_parses` only. Mirrors the janitor's
behavior; see [recovery.md](./recovery.md) for the workflow.

- Invocation: `system-updater --health-acknowledge` or `... --health-acknowledge --json`.
- Exit codes: `0` on success, `3` on precondition failure.

```json
{
  "acknowledged": true,
  "baseline_bytes": 12345,
  "excluded_events": 24
}
```

Idempotent.

## `--version`

Capability discovery surface. Read-only; requires no state.

- Invocation: `system-updater --version` or `... --version --json`.
- Exit code: `0` always.

```json
{
  "name": "system-updater",
  "version": "0.1.0",
  "capabilities": [
    "apt-backend", "exclude", "force", "health", "health-acknowledge",
    "health-json", "holds", "maintenance-window", "only",
    "report", "report-json", "security-only", "stub-backend",
    "version", "version-json"
  ]
}
```

`capabilities[]` is alphabetically sorted and append-only. See
[contracts.md](./contracts.md#capability-contract).

Mapping (capability string → feature):

| Capability | Feature |
|---|---|
| `apt-backend` | `UPDATER_BACKEND=apt` (real apt upgrades) |
| `stub-backend` | `UPDATER_BACKEND=stub` (no-op backend for tests / non-apt hosts) |
| `exclude` | `--exclude <list>` flag |
| `force` | `--force` flag (overrides maintenance-window and security-only gates) |
| `health` | `--health` (text) |
| `health-json` | `--health --json` |
| `health-acknowledge` | `--health-acknowledge` (+ `--json`) |
| `holds` | `UPDATER_HOLD_PACKAGES` glob list (`held` status) |
| `maintenance-window` | `UPDATER_MAINTENANCE_WINDOW` (`out_of_window` status, exit 6) |
| `only` | `--only <list>` flag |
| `report` | `--report` (text) |
| `report-json` | `--report --json` |
| `security-only` | `UPDATER_SECURITY_ONLY=yes` (`filtered_non_security` status) |
| `version` | `--version` (text) |
| `version-json` | `--version --json` |

## `--apply`

Not a machine-readable mode, but documented here for completeness — it is
the only flag that makes the tool destructive. Default is `--dry-run`.

- Invocation: `sudo system-updater --apply`.
- Exit codes: `0` success, `1` lock held, `2` pre-flight (not root,
  snapshot stub failure), `3` precondition (`--apply` with `--dry-run`),
  `6` `out_of_window`, `7` package failures during apply.
- Composes with: `--only`, `--exclude`, `--force`, `UPDATER_*` env vars.

## Capability discovery

Feature-detect before invoking optional flags. Do not parse `--help`.

```bash
caps=$(system-updater --version --json | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["capabilities"]))')
echo "$caps" | grep -qx 'maintenance-window' && export UPDATER_MAINTENANCE_WINDOW=02:00-04:00
```
