# Recovery: `--health-acknowledge`

The audit log is append-only. Without a recovery mechanism, a single
historical malformed JSONL line would pin `--health` at `degraded`
forever — training agents to ignore the signal. `--health-acknowledge`
is the recovery interface.

## Scenario

`--health --json` returns `status: "degraded"`, `exit_code: 4`, and the
`jsonl_parses` check reports `ok: false` with detail leading
`N invalid line(s)`. The N events were written by some past run (perhaps
a crashed write, a power loss, or an older script version) and cannot be
removed without rewriting the audit log.

## Workflow

### 1. Triage

```bash
system-janitor --health --json
```

```json
{
  "status": "degraded",
  "exit_code": 4,
  "checks": [
    {"name": "jsonl_parses", "ok": false, "detail": "1 invalid line (line 24: ...)"}
  ]
}
```

Identify which check failed. **Only `jsonl_parses` is recoverable via
`--health-acknowledge`.** If the failed check is `last_run_parses`,
`last_run_integrity_ok`, or `no_long_idle_streaks`, see "What this does
NOT fix" below.

### 2. Acknowledge

```bash
system-janitor --health-acknowledge --json
```

```json
{
  "acknowledged": true,
  "baseline_bytes": 12345,
  "excluded_events": 24
}
```

This writes a single integer line to `$JANITOR_LOG_DIR/.health-baseline`
(hidden file, sibling of `janitor.jsonl` / `last-run.json`). Write is
atomic (tmp+rename); concurrent `--health` probes never see a torn read.

### 3. Verify

```bash
system-janitor --health --json
```

```json
{
  "status": "healthy",
  "exit_code": 0,
  "checks": [
    {"name": "jsonl_parses", "ok": true, "detail": "0 invalid lines since baseline"}
  ]
}
```

Exit code is now `0`. If a NEW malformed line is appended after the
baseline, `--health` returns `degraded` again — only new issues count.

## Semantics

- **Scope:** baseline filters `jsonl_parses` only. `jsonl_present` still
  counts every event (the file is unchanged; the events still exist).
- **Snap-to-newline:** if the baseline byte offset lands mid-line (e.g.
  because the file was truncated and re-extended), the read snaps
  forward to the next newline boundary. No half-parsed lines.
- **Idempotent:** running it twice on an unchanged file leaves
  `baseline_bytes` the same. Running it after new events advances the
  baseline to the new EOF.
- **Read-only-ish:** like `--health` / `--report` / `--version`, it runs
  BEFORE flock / `mkdir $LOG_DIR` / the exec-redirect, so it does not
  block a concurrent cleanup. It is the only "read-only-ish" mode that
  writes a file — and only one (`$LOG_DIR/.health-baseline`), atomically.
- **File format:** one ASCII-decimal integer, possibly trailing newline.
  Treat the format and the three JSON keys (`acknowledged`,
  `baseline_bytes`, `excluded_events`) as a public contract.

## What this does NOT fix

`--health-acknowledge` is for historical noise in append-only JSONL. It
deliberately does NOT silence ongoing real issues:

| Failing check | Recoverable by `--health-acknowledge`? | Why / what to do |
|---|---|---|
| `jsonl_parses` | Yes | Historical malformed lines; baseline excludes them. |
| `log_dir_exists` | No | Exit 5 (unknown), not 4 (degraded). Run the tool once to create the dir. |
| `jsonl_present` | No | Same as above. Run once. |
| `last_run_parses` | No | `last-run.json` is overwritten atomically every run. If it's corrupt, that's an ongoing bug — fix the writer, don't paper over. |
| `last_run_integrity_ok` | No | A real safety-floor violation. Investigate; do not acknowledge. |
| `last_run_parses_sections` | No | Schema regression. Fix the writer. |
| `no_long_idle_streaks` | No | An opt-in section is configured against a stale path. Fix the config (`JANITOR_WORKSPACE_DIRS`, `JANITOR_EXTRA_CLEANUP_DIRS`) or remove it. |

If you are an agent and `--health-acknowledge` would mask any of the
"No" rows above, do not invoke it. Surface the failing check instead.
