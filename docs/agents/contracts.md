# Contracts

This file documents shared contracts that apply to all tools in the
system-janitor project (currently `system-janitor.sh` and
`system-updater.sh`). Per-tool deltas live in their respective
`*-contracts.md` files — see [updater-contracts.md](./updater-contracts.md)
for `system-updater`'s extensions.

Frozen surfaces. Renaming or removing anything in this file is a breaking
change that warrants a major version bump and a CHANGELOG entry.

## Exit codes

Agents branch on these to decide retry / escalate / proceed.

| Code | Meaning | Triggers | Agent action |
|---:|---|---|---|
| 0 | success | Normal run, `--health` healthy, `--report`, `--version`, `--health-acknowledge` ok | Proceed. |
| 1 | lock held | `flock -n` on the per-tool lock file failed (another instance running) | Back off; retry later. Do not force. |
| 2 | integrity violation / pre-flight | janitor: a `JANITOR_SAFETY_FLOOR_DIRS` dir had its inode change or disappeared during the run. updater: `--apply` invoked without root, or snapshot stub reports missing | Escalate. Treat audit trail with suspicion until investigated. Logs `user.err` to syslog. |
| 3 | precondition | `$HOME` unset, config syntax error, unknown section in `--only`/`--sections` *(janitor only)*, `--apply` with `--dry-run` *(updater only)*, or `--json` used without `--report`/`--health`/`--health-acknowledge`/`--version` | Fix the invocation. Not retryable as-is. |
| 4 | `--health` degraded | Log dir exists but one or more downstream checks failed (malformed JSONL, integrity violation in last-run snapshot, long idle streak, …) | Tool is usable; trust audit trail conditionally. See [`recovery.md`](./recovery.md) for `--health-acknowledge`. |
| 5 | `--health` unknown | Log dir missing OR last-run snapshot absent — never run here | Not a failure. Treat as "no signal yet". |

**Updater-only codes:** `6` (`out_of_window` — `--apply` outside
`UPDATER_MAINTENANCE_WINDOW`) and `7` (per-package failures during
`--apply`). See [updater-contracts.md](./updater-contracts.md#exit-codes-extensions).

Codes are enforced by the per-tool script (`EXIT_CODE` in
`system-janitor.sh` / `system-updater.sh`) and by the per-tool health
schemas (the `exit_code` enum is `[0, 4, 5]` in
[`schemas/health.schema.json`](../../schemas/health.schema.json) and
[`schemas/updater-health.schema.json`](../../schemas/updater-health.schema.json)).

## Status enum

The `status` field in JSONL events, last-run snapshot entries, and
`--report --json`'s `status_counts` keys.

| Value | Where it appears | Meaning |
|---|---|---|
| `ok` | Any section / package, real run | Operation ran successfully. For default sections, this is the steady state even when there was nothing to clean. |
| `idle` | Opt-in sections only (`workspace_binobj`, `extra_cleanup`) *(janitor only)*, real (non-dry) run; updater per-package idle uses the same value | Operation succeeded but produced no work. Silent-failure detector: a configured opt-in section pointed at a stale path. Surfaced via `--report --json`'s `idle_streaks` when consecutive `>= 2`. |
| `dry_run` | Any section / package, `--dry-run` invocation | Operation would have run; no destructive op performed. |
| `warn` | Any section / package | Non-fatal failure (tool missing post-`command -v` gate, transient permission issue, etc.). Free-text `note` field carries detail. |
| `violated_missing` *(janitor only)* | `safety_integrity` only | A `JANITOR_SAFETY_FLOOR_DIRS` entry disappeared mid-run. Run exits 2. |
| `violated_inode_changed` *(janitor only)* | `safety_integrity` only | A `JANITOR_SAFETY_FLOOR_DIRS` entry's inode changed (i.e., replaced) mid-run. Run exits 2. |

**Updater-only status extensions** (`held`, `excluded`,
`filtered_non_security`, `out_of_window`, `reboot_required`,
`snapshot_missing`, `failed`) are documented in
[updater-contracts.md](./updater-contracts.md#status-enum-extensions).

Source of truth: `OPTIN_SECTIONS=(workspace_binobj extra_cleanup)` in
`system-janitor.sh` *(janitor only)*. Adding an opt-in section requires
appending its name to that array, or the silent-failure detector won't
cover it.

## Capability contract

`capabilities[]` in `--version --json` is the source of truth for
agent feature detection at runtime. The **project-wide registry**
lives at [`capabilities.md`](./capabilities.md): one JSON block
listing every capability string each tool advertises, plus prose
tables for shared and per-tool semantics. Agents that operate
multiple tools should consult the registry to learn which
capability strings carry identical semantics across tools (eight at
the moment: `health`, `health-acknowledge`, `health-json`, `only`,
`report`, `report-json`, `version`, `version-json`) and which are
tool-specific.

Per-tool entry points: janitor's array is also documented in
[`machine-modes.md`](./machine-modes.md#--version), updater's in
[`updater-machine-modes.md`](./updater-machine-modes.md#--version).
Those pages and the registry must agree.

Rules:

1. **Alphabetically sorted.** `do_version()` calls `sorted()` at emit
   time, locked in by the smoke `capability completeness` stage.
2. **Append-only.** Removing a capability string is a breaking change.
3. **Four-part change.** Adding a new agent-visible feature is:
   (1) implement it, (2) append its capability string in `do_version()`,
   (3) add the string to that tool's array in
   [`capabilities.md`](./capabilities.md) (alphabetical slot), (4) add
   an end-to-end probe in the tool's smoke
   `─── capability completeness ───` stage. The smoke stage iterates
   a hard-coded `expected` list — keep that list in sync.
4. **Smoke enforces both directions per tool.** Claimed capabilities
   must work (the probe asserts it); unknown capability strings
   (claimed but no probe) fail the suite. The reverse direction
   (feature added without capability) is enforced by code review.
5. **Cross-tool registry consistency** is enforced by
   [`tests/capabilities-check.sh`](../../tests/capabilities-check.sh).
   It fails if (a) any tool's runtime `capabilities[]` differs from
   its registry array, or (b) a capability string appears in two
   tools' arrays without a corresponding row in the "Shared
   capabilities" table of the registry.
6. **No semantic collisions.** A capability string that appears in
   two tools' arrays MUST mean exactly the same thing in both. If
   semantics would diverge, pick a new string instead.

## Unit canon

`_bytes` fields are canonical. `_kb` fields are deprecated aliases
retained for back-compat. New agent code should read `_bytes`.

| Location | `_kb` shape | `_bytes` shape | Notes |
|---|---|---|---|
| `janitor.jsonl` event | `freed_kb` (integer) | (none yet) | On-disk legacy. A future schema bump may add `freed_bytes`; `do_report` already reads it first when present. |
| `last-run.json` top level | `freed_kb` | (none) | Top-level still `_kb` only. |
| `last-run.json.sections[]` | (none) | `freed_bytes` | Per-entry shape: `{name, status, items, freed_bytes}`. Declaration order. |
| `--report --json` totals | `total_freed_kb` | `total_freed_bytes` | Both present. |
| `--report --json` per-section | `freed_kb_total` | `freed_bytes` | Both present. |
| `--report --json` most-recent | `most_recent_run.freed_kb` | `most_recent_run.freed_bytes` | Both present. |

Conversion: `bytes = kb * 1024` (integer arithmetic). At the report
layer, `_bytes` is computed per-event (prefer event `freed_bytes` if
present, else `freed_kb * 1024`) — **never** as a top-level
`_kb * 1024`, which propagates rounding.

## Schema aliases & obsolete sections *(janitor only)*

Section names in `janitor.jsonl` are append-only history. Renames are
recorded as aliases; removals go to `OBSOLETE_SECTIONS`.

Current `SECTION_ALIASES` (historical → canonical):

| Historical | Canonical |
|---|---|
| `copilot_integrity` | `safety_integrity` |

Current `OBSOLETE_SECTIONS` (no current equivalent; surfaced under
`--report --json`'s `obsolete_sections[]`, not `per_section[]`):

| Name |
|---|
| `sandbox_binobj` |
| `azure_openai_cli_dist` |
| `user_cache_copilot` |

**Ordering invariant:** alias remap runs BEFORE the skip/obsolete filter
inside `do_report`. Otherwise an aliased historical name whose canonical
is a meta-section would leak into `per_section`. The smoke
`schema-aliases` probe pins this ordering — real bug, do not regress.

Source of truth: `declare -A SECTION_ALIASES` and `OBSOLETE_SECTIONS=(...)`
in `system-janitor.sh` (search for the array names). Any change there
must also update the `schema-aliases` smoke probe and this table.
