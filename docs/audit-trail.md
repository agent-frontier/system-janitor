# Audit trail — shared reference

`system-janitor` writes three artifacts under `$JANITOR_LOG_DIR` (default
`~/.local/state/janitor`) on every run. This page documents their
on-disk shape — it is the contract that both the human and agent tracks
build on.

| File | Format | Purpose |
|---|---|---|
| `janitor.log` | text | Human-readable narrative |
| `janitor.jsonl` | JSONL | One event per section per run, plus `run_start`/`run_end`/`safety_integrity` meta events |
| `last-run.json` | JSON | Latest run summary, atomic-overwrite |

Logs rotate at 5 MB with 8 backups kept. `janitor.jsonl` is **append-only**
by design — historical issues are cleared via
[`--health-acknowledge`](./agents/recovery.md), not by editing the log.

For the formal Draft 2020-12 JSON Schemas of `--report --json` and
`--health --json`, see [agents/schemas.md](./agents/schemas.md) and
[../schemas/](../schemas/). For the exit-code and capability contract,
see [agents/contracts.md](./agents/contracts.md).

## JSONL event shape

Each line of `janitor.jsonl` is a single JSON object with this shape:

| Field | Type | Notes |
|---|---|---|
| `run_id` | string | Stable per-run id, format `YYYYMMDDTHHMMSSZ-<8hex>`. Same value across every event in the run. |
| `ts` | string | ISO-8601 timestamp with timezone offset (e.g. `2026-05-12T00:59:37+0000`). |
| `host` | string | Hostname as reported by `uname -n`. |
| `user` | string | `$USER` at the time of the run. |
| `section` | string | Section name (see status enum below for the canonical list of values that emit events). |
| `status` | string | One of the 6 status enum values below. |
| `freed_kb` | integer | KiB freed by this section. Always an integer; `0` is normal. JSONL events emit `_kb` for historical reasons — the canonical unit elsewhere is `_bytes` (= `freed_kb * 1024`). |
| `items` | integer | Count of items (caches, dirs, etc.) acted on. |
| `note` | string | Free-form per-section detail. |

`run_start` and `run_end` are meta events that bracket every run.
`safety_integrity` is the always-on integrity check event. All other
section events appear only when the section actually ran.

## Status enum

`status` takes one of exactly six values:

| Value | Meaning |
|---|---|
| `ok` | Section ran successfully. Default sections stay `ok` even when there was nothing to clean — "no work" is their normal steady state. |
| `idle` | An **opt-in** section (`workspace_binobj`, `extra_cleanup`) ran successfully on a real (non-dry) run but produced no work (`items=0`, `freed_kb=0`). Signals a likely stale config: the operator pointed the section at a path that no longer matches anything. |
| `warn` | Section ran but encountered a non-fatal issue. Detail in `note`. |
| `dry_run` | The run was a `--dry-run` invocation. Item counts and pre-state are still populated; nothing was modified on disk. |
| `violated_missing` | A `JANITOR_SAFETY_FLOOR_DIRS` directory disappeared during the run. Run exits `2`. |
| `violated_inode_changed` | A `JANITOR_SAFETY_FLOOR_DIRS` directory's inode or total byte size changed during the run. Run exits `2`. |

Consecutive `idle` events are aggregated into the
`--report --json` `idle_streaks[]` array (and the human `--report`
"Idle sections" block) so operators can spot stale opt-in config.

## `last-run.json` schema (v0.2)

`last-run.json` is the O(1) "what just happened" lookup for agents that
don't want to reparse the full JSONL. It is written atomically
(write-temp-then-rename) at the end of every run.

```json
{
  "run_id": "20260512T005937Z-3b4b15c6",
  "finished": "2026-05-12T00:59:39+0000",
  "host": "malachor",
  "user": "lafiamafia",
  "freed_kb": 220308,
  "safety_integrity": "ok",
  "start_used_kb": 64483032,
  "end_used_kb": 64262724,
  "dry_run": 1,
  "started_at": "2026-05-12T00:59:37+0000",
  "ended_at": "2026-05-12T00:59:39+0000",
  "sections": [
    {"name": "docker_prune",        "status": "dry_run", "items": 2,  "freed_bytes": 70881280},
    {"name": "go_build_cache",      "status": "dry_run", "items": 0,  "freed_bytes": 0},
    {"name": "tmp_gobuild_orphans", "status": "dry_run", "items": 16, "freed_bytes": 0},
    {"name": "workspace_binobj",    "status": "dry_run", "items": 0,  "freed_bytes": 0},
    {"name": "extra_cleanup",       "status": "dry_run", "items": 0,  "freed_bytes": 0},
    {"name": "nuget_http_temp",     "status": "dry_run", "items": 0,  "freed_bytes": 0},
    {"name": "safety_integrity",    "status": "ok",      "items": 0,  "freed_bytes": 0}
  ]
}
```

### Conventions

- `sections[]` is in **declaration order** (the order the sections ran),
  one entry per non-meta event in the JSONL for this run. `run_start`
  and `run_end` are excluded (they bracket the run); `safety_integrity`
  is included.
- `sections[].status` mirrors the JSONL `status` enum exactly.
- `sections[].freed_bytes` is `freed_kb * 1024` from the JSONL event;
  both are guaranteed integers.
- `--only <list>` shrinks `sections[]` to the filtered set (plus the
  always-on `safety_integrity` entry).
- `dry_run` is `1` for a `--dry-run` invocation, `0` otherwise.

### Backward compatibility (pre-v0.2 files)

Files written before the v0.2 enrichment landed lack the `sections`,
`started_at`, and `ended_at` keys. Agents reading historical files must
treat the absence of `sections` as **unknown**, not **error** —
`--health`'s `last_run_parses_sections` check encodes this policy
(skips with a "schema older than v0.2" detail; never flips degraded).

## Unit canon

**`_bytes` fields are canonical; `_kb` fields are deprecated aliases.**

- `--report --json` exposes both `total_freed_kb` and `total_freed_bytes`
  (and per-section `freed_bytes`, `most_recent_run.freed_bytes`). The
  `_bytes` values are computed directly from per-event bytes (preferring
  an event `freed_bytes` field, falling back to `freed_kb * 1024`) —
  never derived from `total_freed_kb`.
- `last-run.json` `sections[]` uses `freed_bytes` only.
- JSONL events currently emit `freed_kb` (the on-disk format predates
  the canon); consumers should treat `freed_bytes = freed_kb * 1024`
  for JSONL entries.
- New agent code should read `_bytes`. The `_kb` fields remain in the
  schema for back-compat and will not be removed without a major-version
  bump.

## Cross-references

- [agents/machine-modes.md](./agents/machine-modes.md) — full
  `--report --json` and `--health --json` output schemas.
- [agents/contracts.md](./agents/contracts.md) — exit-code contract,
  capability strings, status enum (canonical).
- [agents/schemas.md](./agents/schemas.md) — formal Draft 2020-12 JSON
  Schemas with field-by-field validation rules.
- [safety.md](./safety.md) — how the integrity violation statuses fit
  into the broader safety story.
