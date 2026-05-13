# Machine modes

Every machine mode is read-only, runs BEFORE flock / `mkdir $LOG_DIR` /
the `exec >>"$LOG"` redirect, and is safe to invoke concurrently with a
cleanup run. Output is ANSI-free and Unicode-glyph-free; the human
variants (no `--json`) may use glyphs.

`--json` is only valid with `--report`, `--health`, `--health-acknowledge`,
or `--version`. Used alone it exits `3`.

## `--report`

Audit-trail rollup over `$JANITOR_LOG_DIR/janitor.jsonl`.

- Invocation: `system-janitor --report` (text) or `system-janitor --report --json`.
- Exit codes: `0` always (missing/empty JSONL still emits a valid object with zero counts; invalid lines surface via `data_quality` without flipping exit).
- Schema: [`schemas/report.schema.json`](../../schemas/report.schema.json).
- Composes with `--only` (filters `per_section`).

```json
{
  "log_dir": "/home/u/.local/state/janitor",
  "jsonl_path": "/home/u/.local/state/janitor/janitor.jsonl",
  "generated_at": "2026-05-11T21:25:00+0000",
  "total_events": 64,
  "total_runs": 7,
  "real_runs": 5,
  "dry_runs": 2,
  "date_range": {"first": "...", "last": "..."},
  "total_freed_kb": 48655944,
  "total_freed_bytes": 49823686656,
  "per_section": [
    {"name": "go_build_cache", "runs": 7, "freed_kb_total": 45774836,
     "freed_bytes": 46873432064, "items_total": 0,
     "status_counts": {"ok": 5, "dry_run": 2}}
  ],
  "obsolete_sections": [],
  "most_recent_run": {
    "run_id": "...", "finished": "...", "freed_kb": 20329960,
    "freed_bytes": 20817879040, "safety_integrity": "ok", "dry_run": 0
  },
  "data_quality": {"invalid_lines": 1, "examples": [{"line": 24, "error": "..."}]},
  "idle_streaks": [
    {"section": "workspace_binobj", "consecutive_idle_runs": 3,
     "last_productive_run": null}
  ]
}
```

Notes:

- `per_section` sorted by `freed_kb_total` desc. `idle_streaks` sorted by `consecutive_idle_runs` desc, threshold `>= 2`.
- `freed_kb_total` / `items_total` count REAL runs only. `runs` counts real + dry.
- `_bytes` fields are canonical (see [`contracts.md`](./contracts.md#unit-canon)). Alias remap (`SECTION_ALIASES`) runs BEFORE the obsolete/meta filter.
- `most_recent_run` is `null` when no `run_end` event exists.

## `--health`

Read-only trust probe over the audit trail. Does not acquire the lock or create the log dir.

- Invocation: `system-janitor --health` or `... --health --json`.
- Exit codes: `0` healthy, `4` degraded, `5` unknown (log dir missing OR `last-run.json` absent).
- Schema: [`schemas/health.schema.json`](../../schemas/health.schema.json).

Checks (frozen names; the schema enum locks them in):

| Name | Passes when |
|---|---|
| `log_dir_exists` | `$JANITOR_LOG_DIR` is a directory |
| `jsonl_present` | `janitor.jsonl` exists and non-empty |
| `jsonl_parses` | every non-baseline line parses as JSON |
| `last_run_parses` | `last-run.json` exists and is valid JSON |
| `last_run_integrity_ok` | `last-run.json` has `safety_integrity == "ok"` |
| `last_run_parses_sections` | `last-run.json.sections[]` well-formed (skipped + `ok` on pre-v0.2 files) |
| `no_long_idle_streaks` | no section has `consecutive_idle_runs >= 5` |

```json
{
  "status": "degraded",
  "exit_code": 4,
  "generated_at": "2026-05-11T23:55:00+0000",
  "log_dir": "/home/u/.local/state/janitor",
  "checks": [
    {"name": "log_dir_exists",        "ok": true,  "detail": "/home/u/.local/state/janitor"},
    {"name": "jsonl_present",         "ok": true,  "detail": "64 events"},
    {"name": "jsonl_parses",          "ok": false, "detail": "1 invalid line (line 24: ...)"},
    {"name": "last_run_parses",       "ok": true,  "detail": null},
    {"name": "last_run_integrity_ok", "ok": true,  "detail": "safety_integrity=ok, 7 sections"},
    {"name": "last_run_parses_sections", "ok": true, "detail": "7 sections well-formed"},
    {"name": "no_long_idle_streaks",  "ok": true,  "detail": "max consecutive_idle=4 (nuget_http_temp)"}
  ]
}
```

`jsonl_parses.detail` string contract: when malformed lines exist, the
field MUST lead with `N invalid line(s)`. Regex: `^\d+ invalid lines?\b`.
Zero-malformed branches lead with `0 invalid lines`. Do not reword.

## `--health-acknowledge`

Writes a byte offset to `$JANITOR_LOG_DIR/.health-baseline` (atomic
tmp+rename). Subsequent `--health` probes exclude lines whose start
offset is `< baseline` from `jsonl_parses` only. See
[`recovery.md`](./recovery.md) for the full workflow.

- Invocation: `system-janitor --health-acknowledge` or `... --health-acknowledge --json`.
- Exit codes: `0` on success, `3` on precondition failure (HOME unset, etc.).
- Schema: no formal JSON Schema yet (TODO); shape is fixed below.

```json
{
  "acknowledged": true,
  "baseline_bytes": 12345,
  "excluded_events": 24
}
```

Idempotent. Running it twice on an unchanged file leaves `baseline_bytes`
the same; running it after new events advances baseline to new EOF.

## `--version`

Capability discovery surface. Read-only; requires no state (not even `HOME`).

- Invocation: `system-janitor --version` or `... --version --json`.
- Exit code: `0` always.
- Schema: no formal JSON Schema yet (TODO); shape is fixed below.

```json
{
  "name": "system-janitor",
  "version": "0.1.0",
  "capabilities": [
    "health", "health-acknowledge", "health-json", "idle-status",
    "json-schemas", "last-run-sections", "only", "report",
    "report-bytes", "report-json", "schema-aliases", "version",
    "version-json"
  ]
}
```

`capabilities[]` is alphabetically sorted and append-only. See
[`contracts.md`](./contracts.md#capability-contract).

## `--only` / `--sections`

Filter for sections to run. Synonyms.

- Invocation: `system-janitor --only docker_prune,go_build_cache`.
- Composes with: every machine mode above (filters `per_section` in `--report`, filters which sections execute in a normal run, filters `sections[]` in `last-run.json`).
- Execution order follows `KNOWN_SECTIONS` declaration order, NOT argv order. Behavior is deterministic regardless of how the user lists names.
- Unknown section names exit `3` BEFORE the lock is taken.
- `run_start`, `run_end`, and `safety_integrity` always run — they bracket the run; safety is a contract, not an action.
- `JANITOR_*=no` toggles still gate execution within the filtered set ("`--only` narrows, config gates").

## Capability discovery

Feature-detect before invoking optional flags. Do not parse `--help`.

```bash
caps=$(system-janitor --version --json | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["capabilities"]))')
echo "$caps" | grep -qx 'health-acknowledge' && system-janitor --health-acknowledge --json
```

Mapping (capability string → feature):

| Capability | Feature |
|---|---|
| `health` | `--health` (text) |
| `health-json` | `--health --json` |
| `health-acknowledge` | `--health-acknowledge` (+ `--json`) |
| `report` | `--report` (text) |
| `report-json` | `--report --json` |
| `report-bytes` | `_bytes` fields present in report output |
| `idle-status` | `idle` status enum value emitted for stale opt-in sections |
| `last-run-sections` | `last-run.json.sections[]` present |
| `json-schemas` | `schemas/*.schema.json` ship with the repo |
| `schema-aliases` | `SECTION_ALIASES` remap applied before obsolete filter |
| `only` | `--only` / `--sections` flag |
| `version` | `--version` (text) |
| `version-json` | `--version --json` |
