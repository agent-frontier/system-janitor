# Capability registry

> Source of truth for the `capabilities[]` array each tool returns from
> `--version --json`. The registry is the union of every capability
> string the project has frozen, scoped per tool. Adding a capability
> means: implement it in the script, append the string to its
> alphabetical slot in `--version --json`, **and** update this file.
> The smoke `tests/capabilities-check.sh` fails if these three drift.

The JSON block immediately below is the machine-readable source. Prose
tables below summarize for humans. Both must move together.

```json
{
  "system-janitor": [
    "health",
    "health-acknowledge",
    "health-json",
    "idle-status",
    "json-schemas",
    "last-run-sections",
    "only",
    "report",
    "report-bytes",
    "report-json",
    "schema-aliases",
    "version",
    "version-json"
  ],
  "system-updater": [
    "apt-backend",
    "exclude",
    "force",
    "health",
    "health-acknowledge",
    "health-json",
    "holds",
    "maintenance-window",
    "only",
    "report",
    "report-json",
    "security-only",
    "stub-backend",
    "version",
    "version-json"
  ]
}
```

Each tool's array is alphabetical and frozen — capabilities are
append-only between minor versions. A capability is only allowed to
*disappear* across a major bump, and that bump must remove the
corresponding implementation and smoke probe in the same commit.

## Shared capabilities (identical semantics across tools)

These eight capability strings appear in both tools' arrays and mean
the same thing in both. Agents probing `--version --json` can rely on
identical contracts; any divergence is a bug.

| Capability | Semantics |
|---|---|
| `health` | `--health` flag produces a human-readable health summary; exit `0` healthy, exit `5` degraded/unhealthy. |
| `health-acknowledge` | `--health-acknowledge` writes a byte-offset baseline into `.health-baseline` so prior JSONL lines are excluded from `jsonl_parses` and similar checks. Atomic tmp+rename. |
| `health-json` | `--health --json` emits a stable shape: `{generated_at, status, log_dir, checks[]}` where each check is `{name, status, detail}`. |
| `only` | `--only <list>` filters the run scope (sections for janitor, packages for updater); non-matching items are omitted from JSONL and the report. |
| `report` | `--report` reads the JSONL audit trail and prints a human-readable summary of prior runs. |
| `report-json` | `--report --json` emits a machine-readable summary validated by the tool's `schemas/<tool>-report.schema.json`. |
| `version` | `--version` prints `<tool-name> <semver>` on stdout; exit `0`. |
| `version-json` | `--version --json` emits `{name, version, capabilities[]}` where `capabilities[]` is the array this file describes. |

## `system-janitor`-only capabilities

| Capability | Semantics |
|---|---|
| `idle-status` | Sections that ran but found nothing to clean emit JSONL events with `status: "idle"` instead of being silently skipped, so agents can prove the section *ran* vs *was unconfigured*. |
| `json-schemas` | Formal Draft 2020-12 JSON Schemas exist for `--report --json` and `--health --json` under `schemas/`. |
| `last-run-sections` | `last-run.json` includes a `sections[]` array with per-section `{name, status, freed_bytes, ...}`. |
| `report-bytes` | `--report --json` and `last-run.json` use `freed_bytes` (integer) as the canonical aggregation unit; JSONL events still emit legacy `freed_kb` per the unit canon in `docs/agents/contracts.md`. |
| `schema-aliases` | The script recognizes `SECTION_ALIASES` for renamed sections and `OBSOLETE_SECTIONS` for removed ones, so config files and historical JSONL replay forward-compatibly. |

## `system-updater`-only capabilities

| Capability | Semantics |
|---|---|
| `apt-backend` | The script supports `apt`/`apt-get` as a real package-manager backend; gated behind `--apply` plus root. |
| `exclude` | `--exclude <list>` removes packages from the candidate set after upgrade enumeration. Mutually independent from `--only`. |
| `force` | `--force` overrides maintenance-window refusal (exit `6` without it). Does not override holds, root requirement, or `--apply` requirement. |
| `holds` | The script reads `UPDATER_HOLDS` (glob list) and emits a JSONL event per held package; held packages are never upgraded even with `--apply`. |
| `maintenance-window` | `UPDATER_WINDOW_*` env vars (or config) gate `--apply` to a wall-clock window; outside it the run refuses with exit `6` unless `--force`. |
| `security-only` | `--security-only` (or `UPDATER_SECURITY_ONLY=1`) restricts upgrades to packages whose source repo matches `*-security`. |
| `stub-backend` | `UPDATER_BACKEND=stub` selects a hermetic in-memory backend with 3 fixture packages (pkg-clean, pkg-security, pkg-held). Used by `tests/updater-smoke.sh`. |

## Collisions

There are currently **no capability strings whose meaning diverges
across tools.** Every string that appears in two arrays means the same
thing in both. New capabilities introduced for one tool must either
(a) reuse a shared string with identical semantics, or (b) pick a new
string that does not collide. The check in
`tests/capabilities-check.sh` enforces this by failing if any shared
string is present in both arrays without a row in the "Shared
capabilities" table above.

## How a new tool joins the registry

1. Implement the capability in the script. Add it in alphabetical
   position to the array hardcoded in the script's `--version --json`
   output.
2. Add the tool's array (or new capability) to the JSON block at the
   top of this file. Alphabetical, append-only.
3. If the capability is shared with an existing tool and means the
   same thing, ensure the "Shared capabilities" table has the row.
   If it means something different, pick a new string instead.
4. Add an end-to-end probe in the tool's smoke suite that exercises
   the capability and asserts the behavior. The capability-completeness
   convention is "every string in `capabilities[]` has a real probe".
5. Run `tests/capabilities-check.sh` and the per-tool smoke. Both must
   pass before the PR can merge.

## Cross-references

- [`contracts.md`](./contracts.md) — capability discovery rules and the
  alphabetical-append-only freezing convention.
- [`machine-modes.md`](./machine-modes.md) — `--version --json` output
  shape these capabilities describe.
- [`toolkit-roadmap.md`](./toolkit-roadmap.md) — candidate sibling tools
  that will extend this registry.
- [`../../tests/capabilities-check.sh`](../../tests/capabilities-check.sh)
  — the smoke that enforces registry-script-smoke consistency.
