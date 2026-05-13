# Changelog

All notable changes to `system-janitor` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The primary consumer of this project is autonomous LLM agents, so this changelog
emphasizes machine-readable surface area (flags, JSON fields, schemas, exit
codes, status enums, capability strings) over human-facing UX.

## [Unreleased]

### Added

- `system-updater.sh` — sibling tool for apt package updates, sharing
  the same agent contract as `system-janitor.sh` (dry-run-by-default,
  JSONL audit trail, `--report --json` / `--health --json` machine
  modes, `flock` single-instance lock, capability discovery via
  `--version --json`). v0 ships the `apt` and `stub` backends.
- `system-updater` v0.1.0 capabilities[] (alphabetical, frozen):
  `apt-backend`, `exclude`, `force`, `health`, `health-acknowledge`,
  `health-json`, `holds`, `maintenance-window`, `only`, `report`,
  `report-json`, `security-only`, `stub-backend`, `version`,
  `version-json`.
- `system-updater` exit codes `6` (`out_of_window` — `--apply` outside
  `UPDATER_MAINTENANCE_WINDOW`) and `7` (per-package failures during
  `--apply`). Codes `0`, `1`, `2`, `3`, `4`, `5` are inherited from the
  shared project contract documented in
  [`docs/agents/contracts.md`](docs/agents/contracts.md).
- `system-updater` status enum extensions: `held`, `excluded`,
  `filtered_non_security`, `out_of_window`, `reboot_required`,
  `snapshot_missing`, `failed`. Documented in
  [`docs/agents/updater-contracts.md`](docs/agents/updater-contracts.md).
- [`schemas/updater-report.schema.json`](schemas/updater-report.schema.json)
  and [`schemas/updater-health.schema.json`](schemas/updater-health.schema.json)
  — JSON Schema Draft 2020-12, `additionalProperties: true` for forward
  compatibility.
- [`examples/updater.config.example`](examples/updater.config.example)
  — fully-commented sample `UPDATER_*` config.
- Human-track docs: [`docs/updater-install.md`](docs/updater-install.md),
  [`docs/updater-configuration.md`](docs/updater-configuration.md),
  [`docs/updater-usage.md`](docs/updater-usage.md).
- Agent-track docs:
  [`docs/agents/updater-machine-modes.md`](docs/agents/updater-machine-modes.md),
  [`docs/agents/updater-contracts.md`](docs/agents/updater-contracts.md).
- [`docs/agents/contracts.md`](docs/agents/contracts.md) reframed as
  the project-wide shared contract with per-tool `(janitor only)` /
  `(updater only)` labels where surfaces diverge.

### Fixed

- `schemas/updater-report.schema.json` — reconciled with actual
  `system-updater.sh --report --json` output. The initial schema was
  authored in parallel with the script and drifted on
  `most_recent_run` (script emits nested `totals.{upgraded,failed,
  held,excluded,filtered_non_security}` and a `packages[]` array, not
  flat `packages_upgraded`/etc.), `per_package[]` field names
  (`upgrades`/`fails`/`last_status`/`last_seen`, not
  `upgraded`/`failed`/`status_counts`), and `reboot_required` type
  (integer 0/1, matching the project-wide flag idiom, not boolean).
  `tests/updater-smoke.sh` schema validation upgraded from WARN to
  hard-fail accordingly (smoke now 42 assertions, was 40).

### Roadmap (deferred from system-updater v0)

These are explicitly **not** v0 features. They are tracked here so
agents do not rely on them and so the capability list reflects what
ships when they land.

- Real auto-reboot driven by `UPDATER_REBOOT_POLICY=if-required`
  (currently the policy is recorded; the action is stubbed).
- Real snapshot detection for `UPDATER_REQUIRE_SNAPSHOT=yes`
  (currently the stub always reports missing).
- Pre/post hooks.
- Phased apt update delay.
- `dnf` and `zypper` backends.

## [0.1.0]

First tagged baseline. Captures the agent-oriented contract: machine-readable
report and health probes, JSON schemas, a capability-discovery flag, an
append-only audit trail, and a smoke suite that enforces a per-capability
end-to-end probe.

### Added

- `--report` summarizes the most recent run from the audit trail.
- `--report --json` emits a structured rollup with `run_id`, `started_at`,
  `ended_at`, `total_freed_bytes`, and `per_section[]`. Shape is pinned by
  [`schemas/report.schema.json`](schemas/report.schema.json).
- `--health` runs a liveness audit over the audit trail with seven checks
  (log presence, JSONL parse validity, schema-version sanity, run-id
  continuity, idle-streak detection, freed-bytes monotonicity, and overall
  recency). Exits `0` on green, `4` on warnings, `5` on failure.
- `--health --json` emits the same audit as a structured object pinned by
  [`schemas/health.schema.json`](schemas/health.schema.json).
- `--health-acknowledge` (and `--health-acknowledge --json`) baselines
  historical issues into an append-only JSONL acknowledgement log so
  unrecoverable past records (e.g. legacy invalid JSONL lines) stop tripping
  future health probes without rewriting history.
- `--only NAME[,NAME...]` / `--sections NAME[,NAME...]` for surgical
  invocation of individual sections. Unknown section names exit `3`.
- `--version` prints the human-readable version banner.
- `--version --json` exposes a `capabilities[]` array for feature
  detection. Agents pinning to a feature should match a capability string
  rather than parse `--help`.
- `idle` status value in the section status enum: emitted by opt-in
  sections that completed successfully but had zero items and freed zero
  bytes, distinguishing "did nothing because nothing to do" from `ok`,
  `skipped`, and `error`.
- `last-run.json` schema v0.2 with top-level `run_id`, `started_at`,
  `ended_at`, and a `sections[]` array carrying per-section status, items,
  and freed bytes.
- [`schemas/report.schema.json`](schemas/report.schema.json) and
  [`schemas/health.schema.json`](schemas/health.schema.json) — JSON Schema
  Draft 2020-12, `additionalProperties: true` for forward compatibility.
- [`tests/smoke.sh`](tests/smoke.sh) covering machine-mode invariants,
  schema validation of `--report --json` / `--health --json`, exit-code
  semantics, and a capability-completeness contract that asserts every
  string in `capabilities[]` has an end-to-end probe.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) running
  `bash -n`, `shellcheck`, and the smoke suite on every push and PR.
- [`.github/copilot-instructions.md`](.github/copilot-instructions.md)
  agent guide documenting design conventions, the capability contract,
  and the rules for adding new agent-visible affordances.

### Changed

- `--report --json` now emits canonical byte-denominated fields
  `total_freed_bytes` (top level) and `per_section[].freed_bytes`. The
  prior `_kb` fields are retained as deprecated aliases for one release
  cycle; agents should prefer the byte fields and the documented schema.
- `emit_event` sanitizes numeric fields to base-10 integers before
  serialization. Malformed values are silently coerced to `0` instead of
  being emitted verbatim, which previously could produce invalid JSON
  (e.g. an octal-looking `"items":00`).
- `--health`'s `jsonl_parses` check prefixes its `detail` string with
  `"N invalid line(s)"` so the count is regex-scrapeable by agents that
  don't want to walk the full structured output.
- `--report` resolves section aliases (e.g.
  `copilot_integrity → safety_integrity`) and elides obsolete sections
  (e.g. `sandbox_binobj`) transparently so historical audit-trail entries
  roll up under their current canonical names.
- `--version --json` `capabilities[]` is backfilled to 13 entries
  covering every documented machine-readable affordance; the smoke
  suite's capability-completeness stage probes each one end-to-end.

### Fixed

- JSONL numeric validity: a historical bug allowed `emit_event` to
  serialize integer fields with a leading zero (e.g. `"items":00`),
  which strict JSON parsers reject. New emissions are clean. Legacy
  lines remain in the on-disk log and can be baselined with
  `--health-acknowledge` so they stop tripping `jsonl_parses`.
- `idle_streaks` computation in `--health` now applies
  `SECTION_ALIASES` before filtering `OBSOLETE_SECTIONS`. Previously,
  events recorded under an aliased section name could leak into the
  "active" streak set and produce spurious warnings.

## Versioning

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the agent-facing surface area defining what counts as a breaking change.

**Breaking** (requires a MAJOR bump once past 1.0.0):

- Removing a string from `--version --json` `capabilities[]`.
- Removing or renaming a documented field in `--report --json` or
  `--health --json` (or in the on-disk `last-run.json` / JSONL events).
- Changing the semantic meaning of an exit code (`0`, `3`, `4`, `5`).
- Removing or renaming a flag documented in `--help`.
- Removing a section status enum value (`ok`, `skipped`, `error`, `idle`).

**Non-breaking** (MINOR or PATCH):

- Adding new capability strings to `capabilities[]`.
- Adding new JSON fields to any machine-readable output — the schemas
  carry `additionalProperties: true` precisely so this is safe.
- Adding new flags, new sections, new health checks, or new status enum
  values.
- Changing the wording of human-readable `--help` / banner text.

## Compatibility for agents

Agents pinning to a specific feature should feature-detect by matching
strings in `system-janitor.sh --version --json` `capabilities[]` rather
than parsing `--help` or the version banner. The capability set is the
stable contract; `--help` text is not.

Parsed output (`--report --json`, `--health --json`) should be validated
against the schemas in [`schemas/`](schemas/). Because both schemas set
`additionalProperties: true`, agents written against `0.1.0` will keep
validating against later minor releases that add fields.
