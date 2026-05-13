# JSON Schemas

Formal Draft 2020-12 JSON Schemas for machine-mode outputs live in
[`../../schemas/`](../../schemas/). Agents should validate parsed
output against them. Schemas are forward-compatible
(`additionalProperties: true`); new fields land without breaking old
validations.

## Files

| File | Target output | Draft | `additionalProperties` |
|---|---|---|---|
| [`schemas/report.schema.json`](../../schemas/report.schema.json) | `system-janitor --report --json` | 2020-12 | `true` (top level + nested) |
| [`schemas/health.schema.json`](../../schemas/health.schema.json) | `system-janitor --health --json` | 2020-12 | `true` (top level + nested) |

`--version --json` and `--health-acknowledge --json` do not yet have
formal schemas. Their shapes are fixed in
[`machine-modes.md`](./machine-modes.md) and treated as contracts.

## How to validate

Python with the `jsonschema` package:

```bash
python3 - <<'PY'
import json, subprocess, jsonschema
schema = json.load(open("schemas/health.schema.json"))
out = subprocess.check_output(["./system-janitor.sh", "--health", "--json"])
jsonschema.validate(json.loads(out), schema)
print("ok")
PY
```

`tests/smoke.sh` validates both schemas on every run. It uses `jsonschema`
when available and falls back to a hand-rolled checker (required-keys,
enum membership, type checks) when the package isn't installed, so CI
hosts without pip don't skip the contract check.

## Forward-compat policy

- **Additive changes are non-breaking.** New top-level fields, new
  per-entry fields, and new entries in enums that are NOT documented as
  closed (`status_counts` keys, `note` values) land without a version
  bump.
- **Renaming or removing a documented `required` field is breaking.**
  Same for removing a value from a closed enum (`status`, `exit_code`,
  check `name`). Bump version, update CHANGELOG, update the schema in
  the same commit.
- **Capability strings advertise new fields.** When a new field lands in
  `--report --json` or `--health --json` output, append a capability
  string in `do_version()` so agents can feature-detect without
  schema-fetching. See [`contracts.md`](./contracts.md#capability-contract).

## Schema excerpts

`health.schema.json` — the `checks[].name` enum is the frozen set of
seven check names:

```json
"name": {
  "type": "string",
  "enum": [
    "log_dir_exists", "jsonl_present", "jsonl_parses",
    "last_run_parses", "last_run_integrity_ok",
    "last_run_parses_sections", "no_long_idle_streaks"
  ]
}
```

`report.schema.json` — top level requires the rollup keys; see the file
itself for the full shape and per-section structure.
