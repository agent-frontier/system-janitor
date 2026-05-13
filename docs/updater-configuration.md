# Configuration — system-updater

`system-updater` runs out of the box with no config: defaults are
`--dry-run`, `apt` backend (auto-detected), no holds, no maintenance
window. You only need to configure it to opt into stricter behavior
(holds, security-only filtering, time-windowed runs).

For the cleanup tool's config, see [configuration.md](./configuration.md).

## Precedence

Configuration is loaded in this order (later sources override earlier ones):

1. Built-in defaults
2. Environment variables (`UPDATER_*`)
3. `$XDG_CONFIG_HOME/system-updater/config` (default: `~/.config/system-updater/config`)
4. `--config <path>` command-line flag (or `UPDATER_CONFIG_FILE` env var)

The config file is **sourced as bash**, so shell expansions (`$HOME`,
`$(cmd)`) and comments work. See
[examples/updater.config.example](../examples/updater.config.example)
for a fully-commented sample.

## Environment variable reference

| Variable | Default | Purpose |
|---|---|---|
| `UPDATER_LOG_DIR` | `$XDG_STATE_HOME/system-updater` (i.e. `~/.local/state/system-updater`) | Where logs, `updater-last-run.json`, `updater.jsonl`, `.health-baseline`, and `updater.lock` live |
| `UPDATER_BACKEND` | `auto` | One of `apt`, `stub`, `auto`. `auto` picks `apt` when available, else `stub`. v0 ships only the `apt` and `stub` backends |
| `UPDATER_HOLD_PACKAGES` | (unset) | Space-separated glob list of package names to never upgrade. Matched packages are reported with status `held` |
| `UPDATER_SECURITY_ONLY` | `no` | When `yes`, restricts upgrades to security-flagged packages. Filtered-out packages are reported with status `filtered_non_security` |
| `UPDATER_MAINTENANCE_WINDOW` | (unset) | `HH:MM-HH:MM` (24-hour, local time). When set, `--apply` outside the window exits `6` with status `out_of_window`. `--dry-run` ignores the window |
| `UPDATER_REQUIRE_SNAPSHOT` | `no` | When `yes`, `--apply` refuses to run unless a snapshot of the system exists. **v0**: snapshot detection is stubbed; setting this to `yes` will exit `2` with status `snapshot_missing` until real snapshot integration lands |
| `UPDATER_REBOOT_POLICY` | `never` | One of `never`, `if-required`. v0 records the post-update reboot signal as status `reboot_required` but **does not** auto-reboot regardless of policy. The action is stubbed pending the v0.2 reboot path |

## Filtering on the CLI

Two flags compose with the env vars above for ad-hoc scoping:

| Flag | Effect |
|---|---|
| `--only <list>` | Comma-separated package globs. Only matching packages are considered for upgrade. Non-matching upgradeable packages are reported with status `excluded`. |
| `--exclude <list>` | Comma-separated package globs to skip. Matched packages are reported with status `excluded`. |

`--only` and `--exclude` compose with `UPDATER_HOLD_PACKAGES`: holds
always win (a held package will never be upgraded even if matched by
`--only`).

## Safety constraints

- **`--apply` requires root.** Invoking `--apply` without `EUID == 0`
  exits `2` (pre-flight). Use `sudo` or another privilege escalator.
- **`--dry-run` is the default.** Real upgrades require an explicit
  `--apply`. Passing both flags exits `3` (precondition).
- **Maintenance window is enforced for `--apply` only.** Dry-runs always
  run so you can preview at any time.
- **`--force` overrides config gates** (currently: maintenance-window
  and security-only). It does not override holds. Use sparingly; the
  audit trail records that `--force` was in effect.

## Example: holds + security-only + maintenance window

```bash
# ~/.config/system-updater/config
UPDATER_HOLD_PACKAGES="linux-image-* nvidia-* docker-ce"
UPDATER_SECURITY_ONLY=yes
UPDATER_MAINTENANCE_WINDOW=02:00-04:00
UPDATER_REBOOT_POLICY=if-required
```

With this config, a cron-driven `--apply` between 02:00 and 04:00 local
time will upgrade only security-flagged, non-held packages and emit a
`reboot_required` status if the kernel or another reboot-flagging
package was upgraded (the actual reboot is stubbed in v0 — see the
roadmap in [CHANGELOG.md](../CHANGELOG.md)).
