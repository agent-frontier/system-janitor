# Copilot instructions for system-janitor

> First-encounter brief for agents working *on* this script. For deep
> references when consuming the script's machine-mode output, see
> [`docs/agents/`](../docs/agents/README.md):
> [`machine-modes.md`](../docs/agents/machine-modes.md) (invocation +
> stdout shape), [`contracts.md`](../docs/agents/contracts.md) (exit
> codes, status enum, capability contract, unit canon, aliases),
> [`recovery.md`](../docs/agents/recovery.md)
> (`--health-acknowledge` workflow), and
> [`schemas.md`](../docs/agents/schemas.md) (JSON Schema validation).

`system-janitor` is a single-file Bash 4+ disk-cleanup script
(`system-janitor.sh`, ~1700 lines) plus a sample config
(`examples/config.example`), JSON schemas under `schemas/`, and a README.
There is no build system or package manager; `tests/smoke.sh` is the
canonical test harness. The script runs unattended via cron, so changes
must preserve cron-safety, audit-log shape, capability contract, and
exit-code contract.

## Design north star

- The primary consumer is an autonomous LLM agent operating without supervision.
  Human ergonomics are secondary; never sacrifice machine-parseability for human
  aesthetics.
- Every output an agent might read MUST be stable and machine-parseable: JSON
  for structured data, documented exit codes for control flow, no ANSI escapes
  or decorative Unicode in machine-mode outputs. The human-readable
  `janitor.log` is allowed pretty-printing; `janitor.jsonl`, `last-run.json`,
  and any `--*-json` flag are not.
- State files (`last-run.json`, `janitor.jsonl`) MUST be safe to read while a
  run is in progress. This is why `last-run.json` uses write-temp-then-rename
  and `janitor.jsonl` is append-only one-event-per-line. Any new state file
  must follow the same rule.
- Silent failures are forbidden. If a section is configured but produces no
  work for N consecutive runs, an agent must be able to detect that from the
  audit trail. If a new section can fail in a new way, it gets a new `status`
  enum value, not a generic `warn` with a free-text note.
- For any new feature, answer "how does an agent invoke and consume this?"
  before "how does a human use this?". A `--json` (or default-json) machine
  mode is not optional for anything that produces structured output.

## Run / verify

CI runs `bash -n`, `shellcheck` (warning severity), and `tests/smoke.sh` on
every push and PR (`.github/workflows/ci.yml`). An agent can run the same
commands directly — they are idempotent and surface their results via
`last-run.json` and `janitor.jsonl` rather than terminal output. Run them
locally before pushing:

```bash
# 1. Syntax check
bash -n system-janitor.sh

# 2. Static analysis (must pass at -S warning; CI will fail otherwise)
shellcheck system-janitor.sh

# 3. End-to-end smoke test (dry-run + audit-trail invariants, no destructive ops)
./tests/smoke.sh

# Ad-hoc dry-run against a throwaway state dir:
JANITOR_LOG_DIR=/tmp/janitor-test ./system-janitor.sh --dry-run
cat /tmp/janitor-test/last-run.json | python3 -m json.tool
cat /tmp/janitor-test/janitor.jsonl
```

`tests/smoke.sh` is the closest thing to a unit test. It builds a temp config,
runs `--dry-run`, and asserts: exit 0, every documented section appears in
`janitor.jsonl` exactly once, action sections report `status=dry_run`,
`last-run.json` has the documented field set, and the filesystem is unchanged.
**When you add a new section, add its name to `required_sections` and to the
dry-run-status loop in `tests/smoke.sh`** — otherwise the test will fail (or
worse, silently miss the new section).

To exercise a single section in isolation, disable the others via env vars
(e.g. `JANITOR_DOCKER_PRUNE=no JANITOR_GO_CLEAN=no ... ./system-janitor.sh -n`)
or set its own opt-in var (`JANITOR_WORKSPACE_DIRS=/tmp/fake ...`).

## Architecture

The whole script is one pipeline with a fixed shape — keep this shape when
editing:

1. **CLI + config load** — flags parsed, then `$XDG_CONFIG_HOME/system-janitor/config`
   (or `--config <path>`) is `source`d as Bash. Config file values win over the
   built-in defaults applied immediately after.
2. **Lock + log setup** — `flock -n` on `$LOG_DIR/janitor.lock` (exit 1 if held);
   `rotate()` at 5 MB / 8 backups; stdout+stderr redirected to `janitor.log`.
3. **Pre-run snapshot** — inode + `du -sb` of every `JANITOR_SAFETY_FLOOR_DIRS`
   entry stashed in the `SAFETY_BEFORE_INODE` / `SAFETY_BEFORE_SIZE` assoc arrays.
4. **Sections** — each `act_*` function is invoked through `run_section`, which
   measures `df` before/after, counts items via a separate `count_*` expression,
   and emits one JSON event to `janitor.jsonl`.
5. **Integrity check** — re-snapshots the safety-floor dirs and compares.
   Inode change or disappearance flips the run to exit code 2.
6. **Atomic summary** — `last-run.json` is written to `${LATEST}.tmp.$$` then
   `mv`d into place so monitoring tools never see a partial file.

### Adding a new cleanup section

A section is *three* coordinated pieces (the "3-piece section pattern"):

- `act_<name>()` — the action. Must early-return with a `[skip] ...` message
  if its toggle is off or its tool is missing (`command -v X >/dev/null` guard).
  Never `exit` from inside an action; let `run_section` capture the rc.
- `count_<name>()` — echoes a *shell expression string* (not a count). The
  expression is `eval`d and piped to `wc -l` by `run_section`. Echo `""` to
  skip counting.
- A `run_section "<name>" "$(count_<name>)" act_<name>` line in the section
  list near the bottom of the script.

When you add a section you MUST also:

1. Append the name to the `KNOWN_SECTIONS` array (source of truth for `--only`
   validation AND execution order). Current contents (declaration order):
   `docker_prune go_build_cache tmp_gobuild_orphans workspace_binobj
   extra_cleanup nuget_http_temp`.
2. If the section is opt-in (does nothing unless the operator points a
   `JANITOR_*_DIRS` knob at a path), append it to `OPTIN_SECTIONS` too —
   that's what promotes empty real runs from `ok` to `idle` (silent-failure
   detector). Current contents: `workspace_binobj extra_cleanup`.
3. Add the toggle/path env var to the defaults block, `--help` text, the
   README config table, `examples/config.example`, and the
   `required_sections` array in `tests/smoke.sh`. These five user-facing
   places plus the smoke array must stay in sync.
4. If the new section ships a new agent-visible affordance (new flag, JSONL
   status, schema file, report field), see the "Capability contract" below
   — this is a three-part change.

## Conventions specific to this repo

- **Two tiers of behaviour.** Defaults must be universally safe (only touch
  regenerable caches, never user files). Anything that removes user paths
  (`workspace_binobj`, `extra_cleanup`) must be opt-in via a `JANITOR_*` var
  that is empty by default. Do not invert this.
- **Cron-safe environment.** The script sets a fallback `PATH` and augments
  it with `~/.dotnet`, `~/.local/bin`, `~/go/bin`, `/snap/bin` because cron
  inherits a minimal env. Don't assume any other tool is on `PATH`; gate every
  external command with `command -v`.
- **`set -uo pipefail`, not `-e`.** Sections are expected to fail individually
  (missing tools, daemon down, permission denied on `/tmp/go-build*`) without
  aborting the run. Status is captured per-section and surfaced via the JSONL
  `status` field (`ok` / `warn` / `dry_run` / `violated_*`).
- **Dry-run is observable, not silent.** `--dry-run` still computes item
  counts and pre/post `df`, and emits events with `status:"dry_run"`. New
  actions must respect `$DRY_RUN` by routing through `run_section` (which
  handles it) rather than calling destructive commands directly.
- **JSONL schema is a public contract.** Agents downstream of this script
  parse `janitor.jsonl` to decide what to do next, so the schema is frozen by
  contract. The fields
  `run_id, ts, host, user, section, status, freed_kb, items, note` and the
  `status` enum are consumed by the `jq` / `grep` recipes in the README.
  Adding fields is fine; renaming or removing them is a breaking change.
  `emit_event` sanitizes its numeric inputs (`freed_kb`, `items`) via base-10
  arithmetic so garbage like `"00"` or `"abc"` can't break JSON validity, and
  `tests/smoke.sh` asserts every JSONL line parses with `json.loads`.
  The `status` enum is `ok` / `idle` / `warn` / `dry_run` /
  `violated_missing` / `violated_inode_changed`. `idle` is emitted ONLY
  for opt-in sections (`workspace_binobj`, `extra_cleanup` — see the
  `OPTIN_SECTIONS` array in the script) when a real (non-dry) run
  succeeds with `items=0` and `freed_kb=0`. It is the silent-failure
  detector required by the north star: an opt-in section configured
  against a stale path will accumulate `idle` events, which an agent
  detects via `--report --json`'s `idle_streaks`. Default sections stay
  `ok` when they have nothing to do — "nothing to clean" is their
  normal state. When you add a new opt-in section, append its name to
  `OPTIN_SECTIONS` so the idle detector covers it.
- **`--report --json` schema is also a public contract.** The agent-facing
  summary mode emits a single pretty-printed JSON object with top-level keys
  `log_dir, jsonl_path, generated_at, total_events, total_runs, real_runs,
  dry_runs, date_range, total_freed_kb, per_section, most_recent_run,
  data_quality, idle_streaks`. `per_section` is an array sorted by
  `freed_kb_total` descending (deterministic order), `most_recent_run`
  is `null` when no `run_end` event exists, `idle_streaks` is an array
  (sorted by `consecutive_idle_runs` descending) of sections whose
  trailing run of consecutive idle real-run events is `>= 2` — each
  entry has `section`, `consecutive_idle_runs`, and
  `last_productive_run` (`{run_id, ts}` or `null`); a missing JSONL
  still yields a valid object with zero counts and `idle_streaks: []`.
  `--json` without `--report` exits 3. See the README "Audit trail"
  section for the full schema; treat it as frozen. `--report` is
  read-only (no flock, no log-dir mutation) and runs BEFORE
  flock/mkdir/exec-redirect, so it composes safely with a concurrent
  janitor run. **Alias remap runs BEFORE the skip/obsolete filter**
  inside the report Python: historical alias names are folded into
  their canonical section first, *then* meta-sections and
  `OBSOLETE_SECTIONS` are filtered out — otherwise an aliased name
  whose canonical is a meta-section would leak into `per_section`.
  The smoke `schema-aliases` probe pins this ordering; do not reorder.
- **Unit canon — `_bytes` fields are canonical at the report layer** and are
  computed directly from JSONL events (per-event, bytes-aware: prefer the
  event's `freed_bytes` when present, else `freed_kb * 1024`); `_kb` fields
  are deprecated aliases retained for back-compat. Agents should prefer
  `_bytes` when available. Current on-disk shape:
  * `janitor.jsonl` events: `freed_kb` (no `_bytes`). A future schema bump
    may add `freed_bytes` to events; `do_report` already reads it first.
  * `last-run.json` top-level: `freed_kb` (no top-level `_bytes`). The
    `sections[]` array uses `freed_bytes` per entry (declaration-order
    list of `{name, status, items, freed_bytes}`).
  * `--report --json`: carries both shapes for back-compat
    (`total_freed_bytes` + `total_freed_kb`; per-section `freed_bytes` +
    `freed_kb_total`; `most_recent_run.freed_bytes` +
    `most_recent_run.freed_kb`). New agent code should read `_bytes`.
  Do NOT compute `_bytes` as `_kb * 1024` at the top level of the report —
  that propagates rounding; sum per-event bytes instead.
- **Capability discovery — `./system-janitor.sh --version --json` returns
  `name`/`version`/`capabilities[]`.** (Current capability→feature
  mapping: [`docs/agents/machine-modes.md`](../docs/agents/machine-modes.md#capability-discovery).
  Three-part-change rule: [`docs/agents/contracts.md`](../docs/agents/contracts.md#capability-contract).)
  Agents should check `capabilities`
  before invoking optional flags rather than parsing `--help`. The list
  is alphabetically sorted and stable across invocations; new strings
  are append-only (removing one is a breaking change). When adding a
  new agent-visible feature, append its capability string to the array
  in `do_version()` — not doing so silently breaks feature-detection
  for downstream agents.
- **Capability contract — `capabilities[]` is a superset of all advertised
  features, enforced by smoke probes.** The `─── capability completeness ───`
  stage in `tests/smoke.sh` parses `--version --json` and runs an
  end-to-end probe for every claimed capability — claiming a capability
  means the feature actually works (or smoke fails). Adding a new flag,
  schema file, JSONL status, or report field is a THREE-part change:
  (1) implement it, (2) add its string to the `capabilities` list in
  `do_version()`, (3) add a probe in the `capability completeness`
  smoke stage. The smoke contract catches direction-2 regressions
  (claiming a capability that no longer works) and unknown capability
  strings (a probe must exist for every claimed string). It CANNOT
  mechanically catch a feature added without bumping capabilities —
  that direction is enforced by code review. PRs that introduce a new
  agent-visible affordance without touching `do_version()` and the
  smoke stage should be rejected.
- **Exit codes are a public contract.** Agents branch on these to decide
  whether to retry, escalate, or move on, so the mapping must stay stable.
  (See [`docs/agents/contracts.md`](../docs/agents/contracts.md#exit-codes)
  for the canonical table.)
  `0` ok, `1` lock held, `2` integrity violation, `3` precondition failure
  (HOME unset, config syntax error, unknown section name passed to
  `--only` / `--sections`, or `--json` used without one of `--report` /
  `--health` / `--health-acknowledge` / `--version`), `4` `--health`
  degraded (log dir present but one or more health checks failed — agent
  should not blindly trust the audit trail but the tool is still usable),
  `5` `--health` unknown (log dir absent OR `last-run.json` absent —
  system-janitor has never produced a summary on this host; agent should
  treat as "no signal yet", not as failure). Don't introduce new codes
  without updating both the README and `--help`.
- **`--only` is the agent's targeted-cleanup interface.** When an agent
  wants to exercise a subset of sections (e.g. just `docker_prune`, or
  `docker_prune,go_build_cache`), it MUST use `--only <list>` rather than
  setting every other `JANITOR_*=no` knob individually — the env-var
  approach is brittle (six knobs to remember; one new section silently
  breaks it). `--only` filters the candidate set; the existing
  `JANITOR_*` toggles still gate execution within that set (principle
  of least surprise: `--only` narrows, config gates). Execution order
  follows the `KNOWN_SECTIONS` declaration order, NOT user input order,
  so behavior is deterministic regardless of argv ordering. Unknown
  section names exit `3` before the lock is taken. `--sections` is an
  accepted synonym. `run_start`, `run_end`, and `safety_integrity`
  always run (they bracket the run; safety is a contract, not an action).
- **`--health --json` schema is also a public contract.** The probe
  emits a single JSON object on stdout with top-level keys `status`
  (one of `"healthy"`, `"degraded"`, `"unknown"`), `exit_code` (matches
  the process exit code: 0/4/5), `generated_at`, `log_dir`, and
  `checks` (an array; each entry has `name`, `ok`, `detail`). The
  seven check names — `log_dir_exists`, `jsonl_present`,
  `jsonl_parses`, `last_run_parses`, `last_run_integrity_ok`,
  `last_run_parses_sections`, `no_long_idle_streaks` — are frozen.
  Adding new checks is fine; renaming or removing them is a breaking
  change. Output is ANSI-free and contains no Unicode glyphs (the ✓/✗
  glyphs only appear in the human-mode `--health` output). See the
  README "Health probe" section for the full schema.
- **`--health` `jsonl_parses` detail-string wording is a contract.** When
  malformed JSONL lines exist, the `detail` field MUST lead with the
  phrase `"N invalid line(s)"` (e.g. `"3 invalid lines since baseline
  ..."`, `"1 invalid line (line 42: ...)"`). Regex scrapers and external
  monitors key off this prefix; do not reword. The 0-malformed branches
  symmetrically lead with `"0 invalid lines"`.
- **`.health-baseline` is the agent's recovery interface.** (Full
  workflow + what it does NOT fix:
  [`docs/agents/recovery.md`](../docs/agents/recovery.md).) The audit
  log is append-only, so one historical malformed JSONL line would
  otherwise pin `--health` at `degraded` (exit 4) forever — training
  agents to ignore the signal. `--health-acknowledge` writes a single
  integer byte offset to `$JANITOR_LOG_DIR/.health-baseline` (hidden
  file, sibling of `janitor.jsonl` and `last-run.json`, written
  atomically via tmp+rename so concurrent `--health` probes never see
  a torn read). On subsequent `--health` runs, lines whose start byte
  offset is `< baseline` are excluded from the `jsonl_parses` check
  (other checks unaffected; `jsonl_present` still counts every event).
  If `baseline` lands mid-line, the read snaps forward to the next
  newline boundary — no half-parsed lines. `--health-acknowledge`,
  like `--health` / `--report` / `--version`, runs BEFORE flock / mkdir
  / exec-redirect, and pairs with `--json` (keys: `acknowledged`,
  `baseline_bytes`, `excluded_events`). Treat the file format (one
  integer line) and key names as a public contract.
- **Path expansion in config lists.** Colon-separated `JANITOR_*_DIRS` values
  go through `split_paths()`, which expands `~` and `$VAR`s via `eval`. Always
  iterate them with `while IFS= read -r d; do ... done < <(split_paths "$VAR")`
  rather than splitting on `:` inline.
- **Safety-floor semantics.** Inode change *or* disappearance fails the run;
  size change alone is informational (log dirs legitimately grow during the
  run because the script writes to them). Preserve this asymmetry.
- **Atomic writes for monitored files.** Anything an agent or monitoring tool
  may read mid-run (currently just `last-run.json`) must be written to
  `*.tmp.$$` and `mv`d. Do not append-and-truncate.

### Schema history & section aliases

> Canonical table of current aliases/obsolete sections:
> [`docs/agents/contracts.md`](../docs/agents/contracts.md#schema-aliases--obsolete-sections).

- Section names in `janitor.jsonl` are append-only history. When a section is
  renamed or removed in `system-janitor.sh`, old events stay in the log
  forever — the JSONL is never rewritten.
- Known historical aliases (current → historical, or "obsolete"):
  - `safety_integrity` was previously `copilot_integrity` (renamed). Same
    semantics. `--report` merges them under the canonical name.
  - `sandbox_binobj`, `azure_openai_cli_dist`, `user_cache_copilot` are
    obsolete (sections that existed in a prior bespoke fork; no current
    equivalent). `--report` surfaces them under `obsolete_sections` instead
    of dropping them silently.
- When introducing a new rename in the future: add it to the
  `SECTION_ALIASES` mapping in `system-janitor.sh` (consumed by `do_report`),
  and add an entry to the list above. Do NOT silently change a section name
  without recording the alias — that breaks downstream agents that compute
  per-section averages across the full JSONL. Removing a section entirely
  (no current equivalent) goes in `OBSOLETE_SECTIONS` instead. **Any
  change to `SECTION_ALIASES` or `OBSOLETE_SECTIONS` must also update the
  `schema-aliases` smoke probe** in `tests/smoke.sh`, which asserts the
  alias remap is applied before the skip/obsolete filter (real bug we
  caught earlier; do not regress).
- **Machine-mode contracts are formally specified** in
  `schemas/report.schema.json` and `schemas/health.schema.json` (JSON
  Schema Draft 2020-12). (Validation recipe + forward-compat policy:
  [`docs/agents/schemas.md`](../docs/agents/schemas.md).) Agents should validate parsed `--report --json`
  and `--health --json` output against these schemas. Schemas use
  `additionalProperties: true` for forward-compat; new fields land
  without breaking old validations. Renaming or removing documented
  required fields, or removing values from the `status` / check-name
  enums, is a breaking change — update the schema in the same commit.
- **`state/last-run.json` is the O(1) lookup for "what just happened"**.
  Beyond the run-level summary fields (`run_id`, `finished`, `freed_kb`,
  `safety_integrity`, `start_used_kb`, `end_used_kb`, `dry_run`), it
  includes `started_at`, `ended_at`, and a `sections[]` array with per-
  section `{name, status, items, freed_bytes}` in declaration order
  (the order each `run_section` ran). Agents reading this avoid
  reparsing the full JSONL. `safety_integrity` is included as a
  section; `run_start` / `run_end` are not. `sections[]` always
  honors `--only` — filtered sections do not appear. Older
  `last-run.json` files (written before this enrichment) may lack
  `sections`, `started_at`, and `ended_at`; agents reading historical
  files MUST treat the absence of `sections` as **unknown**, not
  **error**. The `--health` check `last_run_parses_sections` encodes
  this policy (skipped + still `ok` when the key is missing).

### Coordination notes for parallel agents

Multiple agents edit this script in parallel rounds. Follow these
conventions to avoid stomping each other's diffs:

- **Delimiter blocks.** Per-flag code is fenced with
  `# ── --flagname flag ──` / `# ── end --flagname flag ──` comment
  banners (see `--health`, `--health-acknowledge`, `--version`,
  `--only`). When adding a new flag, wrap its CLI-parse arm, validation
  block, and `do_<flag>` function in matching banners so the next agent
  can locate and excise it cleanly.
- **`tests/smoke.sh` stage ordering.** New end-to-end probes go at the
  END of `smoke.sh`, after the existing `─── capability completeness ───`
  stage if possible. Do not interleave new probes into mid-file stages
  unless they're tightly coupled to existing assertions — that's how
  merge conflicts happen.
- **Capability list is alphabetically sorted** (enforced by `sorted()`
  in `do_version`, locked in by the smoke `capability completeness`
  stage). Append your new capability string anywhere in the literal
  list — Python sorts at emit time. The smoke stage iterates a
  hard-coded `expected` list; keep that list in sync.
- **Five-place sync for new sections** (repeated for emphasis):
  `KNOWN_SECTIONS`, defaults block, `--help` text, README config table,
  `examples/config.example`, `tests/smoke.sh` `required_sections`. Plus
  `OPTIN_SECTIONS` if opt-in. Plus a `capabilities[]` entry + smoke
  probe if it introduces a new agent-visible affordance.
