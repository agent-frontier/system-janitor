# Updater contracts (deltas)

This page documents how `system-updater.sh` deviates from the
project-wide shared contracts in [contracts.md](./contracts.md). Read
that page first; everything not listed here is identical.

## Environment variable namespace

The updater uses the `UPDATER_*` namespace, parallel to the janitor's
`JANITOR_*`. The two namespaces never overlap. See
[../updater-configuration.md](../updater-configuration.md) for the full
variable reference.

## Exit codes (extensions)

The updater inherits exit codes `0`, `1`, `3`, `4`, `5` from the shared
contract with the same semantics. It adds two updater-only codes and
narrows `2`'s trigger set.

| Code | Meaning | Triggers (updater) | Agent action |
|---:|---|---|---|
| 2 | pre-flight | `--apply` invoked without `EUID == 0`; `UPDATER_REQUIRE_SNAPSHOT=yes` and the snapshot stub reports missing | Fix the invocation (sudo, snapshot). Not retryable as-is. |
| 6 | out of window | `--apply` invoked outside `UPDATER_MAINTENANCE_WINDOW` without `--force` | Wait until the window opens, or pass `--force`. |
| 7 | package failures during `--apply` | One or more packages failed to upgrade (apt non-zero, dpkg error). The audit trail records each failed package with status `failed` | Inspect `updater-last-run.json` and the JSONL for per-package detail. May retry after dependency / disk-space fixes. |

Codes `6` and `7` are **updater-only** — janitor never emits them. They
are validated by [`schemas/updater-report.schema.json`](../../schemas/updater-report.schema.json)
and [`schemas/updater-health.schema.json`](../../schemas/updater-health.schema.json).

## Status enum (extensions)

The updater inherits `ok`, `warn`, `dry_run`, `idle` from the shared
status enum with the same semantics. It adds the following
updater-only values, used in JSONL events
(`updater.jsonl`), `updater-last-run.json.packages[].status`, and
`--report --json`'s `per_package[].status_counts` keys.

| Value | Where it appears | Meaning |
|---|---|---|
| `held` | per-package events | Package matched `UPDATER_HOLD_PACKAGES`; not upgraded. |
| `excluded` | per-package events | Package matched `--exclude`, or did not match `--only`. |
| `filtered_non_security` | per-package events | `UPDATER_SECURITY_ONLY=yes` and the package's available upgrade is not security-flagged. |
| `out_of_window` | `run_end` only | `--apply` aborted because the call landed outside `UPDATER_MAINTENANCE_WINDOW`. Run exits `6`. |
| `reboot_required` | `run_end` only | At least one upgraded package set `/var/run/reboot-required`. v0 records the signal but does not auto-reboot regardless of `UPDATER_REBOOT_POLICY`. |
| `snapshot_missing` | `run_end` only | `UPDATER_REQUIRE_SNAPSHOT=yes` and the snapshot stub reports no snapshot. Run exits `2`. v0: snapshot detection is stubbed. |
| `failed` | per-package events | Package upgrade failed during `--apply`. Run exits `7` if at least one package has this status. |

The janitor-only `violated_missing` and `violated_inode_changed`
statuses do not appear in updater output.

## Capabilities (v0)

The updater's `--version --json` `capabilities[]` is a separate list
from the janitor's. The two tools advertise their own capabilities;
agents must not assume any overlap.

```json
[
  "apt-backend", "exclude", "force", "health", "health-acknowledge",
  "health-json", "holds", "maintenance-window", "only",
  "report", "report-json", "security-only", "stub-backend",
  "version", "version-json"
]
```

Alphabetically sorted, append-only. See
[contracts.md](./contracts.md#capability-contract) for the rules and
[updater-machine-modes.md](./updater-machine-modes.md#capability-discovery)
for the capability → feature mapping.

## State files

| File | Purpose |
|---|---|
| `$UPDATER_LOG_DIR/updater.jsonl` | Append-only audit trail (one event per package per run, plus `run_start` / `run_end` / `dispatcher` / `integrity` meta events) |
| `$UPDATER_LOG_DIR/updater-last-run.json` | Atomic-overwrite latest-run snapshot |
| `$UPDATER_LOG_DIR/.health-baseline` | Byte offset baseline for `--health-acknowledge` |
| `$UPDATER_LOG_DIR/updater.lock` | `flock` single-instance lock |

`$UPDATER_LOG_DIR` defaults to `${XDG_STATE_HOME:-$HOME/.local/state}/system-updater`.

## JSONL event fields

Each line in `updater.jsonl` is a single JSON object:

| Field | Type | Notes |
|---|---|---|
| `ts` | string | ISO-8601 with timezone offset |
| `host` | string | `uname -n` |
| `user` | string | `$USER` |
| `run_id` | string | Stable per-run id, format `YYYYMMDDTHHMMSSZ-<8hex>` |
| `stage` | string | One of `run_start`, `package`, `run_end`, `integrity`, `dispatcher` |
| `package` | string | Package name (empty for non-`package` stages) |
| `from_version` | string | Installed version before upgrade (empty for non-`package` stages) |
| `to_version` | string | Candidate version after upgrade (empty for non-`package` stages) |
| `status` | string | One of the status enum values (shared + updater extensions) |
| `duration_ms` | integer | Wall-clock duration of the per-package or per-run operation |
| `dry_run` | integer | `1` for `--dry-run`, `0` for `--apply` |
| `source_repo` | string | apt source / origin (e.g. `Ubuntu:24.04/noble-updates`) |
| `security` | integer | `1` if the available upgrade is security-flagged, else `0` |

`run_start` and `run_end` bracket every run. `integrity` carries the
snapshot-stub result. `dispatcher` is reserved for the v0.2 reboot path
and currently emitted only as a no-op record when
`UPDATER_REBOOT_POLICY != never` and a reboot is required.

## v0 deferred (roadmap, not features)

The following are explicitly **not** v0 features and must not be
relied on by agents:

- Real auto-reboot driven by `UPDATER_REBOOT_POLICY=if-required`
  (currently the policy is recorded; the action is stubbed).
- Real snapshot detection for `UPDATER_REQUIRE_SNAPSHOT=yes`
  (currently always reports missing).
- Pre/post hooks.
- Phased apt update delay.
- `dnf` and `zypper` backends.

These are tracked in [`../../CHANGELOG.md`](../../CHANGELOG.md). When
they land, they will appear as new capability strings.
