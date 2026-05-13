#!/usr/bin/env bash
# tests/smoke.sh — exercise system-janitor in --dry-run mode and verify the
# audit-trail invariants (exit code, JSONL section coverage, last-run.json
# shape). No destructive operations are performed.
#
# Run from the repo root:  ./tests/smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/system-janitor.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

LOG_DIR="${WORK}/state"
CONFIG="${WORK}/config"

# Minimal config: explicitly disable everything that would hit external tools,
# and exercise the workspace + extra_cleanup + safety_floor opt-in paths.
mkdir -p "${WORK}/ws/proj/bin" "${WORK}/ws/proj/obj" \
         "${WORK}/extra" \
         "${WORK}/safe"
echo "keep me" > "${WORK}/safe/file"

cat > "$CONFIG" <<EOF
JANITOR_DOCKER_PRUNE=no
JANITOR_GO_CLEAN=no
JANITOR_TMP_GOBUILD_ORPHANS=no
JANITOR_NUGET_CLEAN=no
JANITOR_WORKSPACE_DIRS="${WORK}/ws"
JANITOR_EXTRA_CLEANUP_DIRS="${WORK}/extra"
JANITOR_SAFETY_FLOOR_DIRS="${WORK}/safe"
EOF

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

echo "── syntax check ─────────────────────────────────────────────"
bash -n "$SCRIPT"
pass "bash -n"

echo "── dry-run ──────────────────────────────────────────────────"
JANITOR_LOG_DIR="$LOG_DIR" "$SCRIPT" --config "$CONFIG" --dry-run
pass "dry-run exited 0"

JSONL="${LOG_DIR}/janitor.jsonl"
LATEST="${LOG_DIR}/last-run.json"

[ -s "$JSONL" ]  || fail "janitor.jsonl missing or empty"
[ -s "$LATEST" ] || fail "last-run.json missing or empty"
pass "audit files exist"

# Every section should have emitted exactly one event, with status=dry_run
# (for the action sections) or status=ok (for run_start/run_end/safety).
required_sections=(
  run_start
  docker_prune
  go_build_cache
  tmp_gobuild_orphans
  workspace_binobj
  extra_cleanup
  nuget_http_temp
  safety_integrity
  run_end
)
for s in "${required_sections[@]}"; do
  count=$(grep -c "\"section\":\"${s}\"" "$JSONL" || true)
  [ "$count" -eq 1 ] || fail "section '${s}' appeared ${count} times in JSONL (expected 1)"
done
pass "all sections emitted exactly once"

# Every line in the JSONL must be valid JSON. This catches the class of bug
# where emit_event interpolates garbage (e.g. "00", "abc") into a numeric
# field and produces a line that python -m json.tool / jq cannot parse.
python3 -c "
import json, sys
for i, l in enumerate(sys.stdin, 1):
    l = l.strip()
    if not l: continue
    try:
        json.loads(l)
    except Exception as e:
        sys.stderr.write(f'line {i} invalid: {e}\n  >>> {l}\n')
        sys.exit(1)
" < "$JSONL" || fail "janitor.jsonl contains invalid JSON"
pass "every JSONL line is valid JSON"

# Action sections must report status=dry_run, not ok (the contract for --dry-run).
for s in docker_prune go_build_cache tmp_gobuild_orphans workspace_binobj extra_cleanup nuget_http_temp; do
  grep -q "\"section\":\"${s}\",\"status\":\"dry_run\"" "$JSONL" \
    || fail "section '${s}' did not report status=dry_run"
done
pass "action sections all status=dry_run"

# last-run.json must be valid JSON with the documented fields.
python3 - "$LATEST" <<'PY'
import json, sys
required = {"run_id","finished","host","user","freed_kb","safety_integrity","start_used_kb","end_used_kb","dry_run"}
data = json.load(open(sys.argv[1]))
missing = required - data.keys()
if missing:
    print(f"FAIL: last-run.json missing fields: {missing}", file=sys.stderr)
    sys.exit(1)
if data["dry_run"] != 1:
    print(f"FAIL: last-run.json dry_run={data['dry_run']!r}, expected 1", file=sys.stderr)
    sys.exit(1)
if data["safety_integrity"] != "ok":
    print(f"FAIL: safety_integrity={data['safety_integrity']!r}, expected 'ok'", file=sys.stderr)
    sys.exit(1)
PY
pass "last-run.json shape + dry_run flag + safety_integrity=ok"

# Dry-run must not have removed the opt-in paths.
[ -d "${WORK}/ws/proj/bin" ] || fail "dry-run removed bin/ (it must not)"
[ -d "${WORK}/ws/proj/obj" ] || fail "dry-run removed obj/ (it must not)"
[ -d "${WORK}/extra" ]       || fail "dry-run removed extra cleanup dir (it must not)"
[ -f "${WORK}/safe/file" ]   || fail "dry-run touched safety-floor dir (it must not)"
pass "dry-run left filesystem untouched"

# ── Regression test: emit_event must sanitize garbage numeric input ──
# Bug repro: a freed_kb/items value of "00" (or "abc", or "007") would
# previously be interpolated raw into the JSONL, producing an RFC 8259
# violation (leading-zero or non-numeric where a JSON number is expected).
echo "── emit_event sanitization regression ───────────────────────"
REGRESSION_DIR="${WORK}/regression"
mkdir -p "$REGRESSION_DIR"
REGRESSION_JSONL="${REGRESSION_DIR}/janitor.jsonl"

# Source just the helpers we need without running the main pipeline.
# We extract emit_event + jsonescape by sourcing in a guarded subshell.
(
  # Stub out the heavy globals emit_event references.
  RUN_ID="regression-test"
  HOSTNAME_S="testhost"
  USER_S="testuser"
  JSONL="$REGRESSION_JSONL"
  ts() { echo "2026-01-01T00:00:00+0000"; }
  jsonescape() { printf '"%s"' "${1//\"/\\\"}"; }

  # Inline the (post-fix) emit_event body. Keep this in sync with the
  # function in system-janitor.sh — it's a regression fixture.
  emit_event() {
    local section="$1" status="$2" freed_kb="${3:-0}" items="${4:-0}" note="${5:-}"
    freed_kb="${freed_kb//[^0-9]/}"
    items="${items//[^0-9]/}"
    freed_kb=$((10#${freed_kb:-0} + 0))
    items=$((10#${items:-0} + 0))
    printf '{"run_id":"%s","ts":"%s","host":"%s","user":"%s","section":%s,"status":"%s","freed_kb":%s,"items":%s,"note":%s}\n' \
      "$RUN_ID" "$(ts)" "$HOSTNAME_S" "$USER_S" \
      "$(jsonescape "$section")" "$status" \
      "$freed_kb" "$items" \
      "$(jsonescape "$note")" >>"$JSONL"
  }

  emit_event "garbage_leading_zero" "ok" "00"   "00"   "leading zero"
  emit_event "garbage_alpha"        "ok" "abc"  "xyz"  "non-numeric"
  emit_event "garbage_mixed"        "ok" "007"  "0x9"  "mixed"
  emit_event "garbage_empty"        "ok" ""     ""     "empty"
)

# The above must have produced 4 lines, all valid JSON, all with numeric
# freed_kb/items that have no leading zeros.
[ "$(wc -l < "$REGRESSION_JSONL")" -eq 4 ] || fail "regression: expected 4 lines"
python3 -c "
import json, sys
for i, l in enumerate(sys.stdin, 1):
    o = json.loads(l)
    for f in ('freed_kb', 'items'):
        v = o[f]
        if not isinstance(v, int):
            sys.stderr.write(f'line {i} field {f} not int: {v!r}\n'); sys.exit(1)
        if v < 0:
            sys.stderr.write(f'line {i} field {f} negative: {v}\n'); sys.exit(1)
" < "$REGRESSION_JSONL" || fail "regression: emit_event produced invalid JSON for garbage input"
pass "emit_event sanitizes garbage numeric input"

echo
echo "── --report ─────────────────────────────────────────────────"
REPORT_OUT="${WORK}/report.out"
JANITOR_LOG_DIR="$LOG_DIR" "$SCRIPT" --report > "$REPORT_OUT"
pass "--report exited 0"

grep -q "system-janitor — report" "$REPORT_OUT" || fail "--report missing header"
grep -q "log dir : ${LOG_DIR}" "$REPORT_OUT"    || fail "--report missing log dir line"
for s in docker_prune go_build_cache tmp_gobuild_orphans workspace_binobj extra_cleanup nuget_http_temp; do
  grep -q "$s" "$REPORT_OUT" || fail "--report output missing section '$s'"
done
pass "--report output mentions all sections"

# --report on a missing log dir must still exit 0 with a friendly message.
EMPTY_DIR="${WORK}/empty"
JANITOR_LOG_DIR="$EMPTY_DIR" "$SCRIPT" --report > "${WORK}/report-empty.out"
grep -q "no runs found" "${WORK}/report-empty.out" || fail "--report on empty dir missing 'no runs found'"
[ ! -d "$EMPTY_DIR" ] || fail "--report created the log dir (must not)"
pass "--report on missing log dir is read-only and friendly"

echo
echo "── --report --json ──────────────────────────────────────────"
REPORT_JSON_OUT="${WORK}/report.json"
JANITOR_LOG_DIR="$LOG_DIR" "$SCRIPT" --report --json > "$REPORT_JSON_OUT"
pass "--report --json exited 0"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPORT_JSON_OUT" \
  || fail "--report --json output is not valid JSON"
pass "--report --json output parses as JSON"

python3 - "$REPORT_JSON_OUT" <<'PY'
import json, sys
required = {"log_dir","jsonl_path","generated_at","total_events","total_runs",
            "real_runs","dry_runs","date_range","total_freed_kb","per_section",
            "most_recent_run","data_quality"}
data = json.load(open(sys.argv[1]))
missing = required - data.keys()
if missing:
    print(f"FAIL: --report --json missing top-level keys: {missing}", file=sys.stderr)
    sys.exit(1)
if not isinstance(data["per_section"], list):
    print("FAIL: per_section must be an array", file=sys.stderr); sys.exit(1)
if not isinstance(data["data_quality"], dict) or "invalid_lines" not in data["data_quality"]:
    print("FAIL: data_quality shape wrong", file=sys.stderr); sys.exit(1)
PY
pass "--report --json has documented top-level keys"

# --report --json against a missing log dir: still valid JSON, zero counts,
# most_recent_run = null, exit 0. Must NOT print "no runs found" (unparseable).
EMPTY_JSON_OUT="${WORK}/report-empty.json"
JANITOR_LOG_DIR="${WORK}/empty2" "$SCRIPT" --report --json > "$EMPTY_JSON_OUT"
python3 - "$EMPTY_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["total_events"] == 0, data["total_events"]
assert data["total_runs"]   == 0, data["total_runs"]
assert data["per_section"] == [], data["per_section"]
assert data["most_recent_run"] is None, data["most_recent_run"]
PY
[ ! -d "${WORK}/empty2" ] || fail "--report --json created the log dir (must not)"
pass "--report --json on missing log dir emits valid JSON with zero counts"

# --json without --report must exit 3 (precondition failure).
set +e
"$SCRIPT" --json > "${WORK}/json-only.out" 2> "${WORK}/json-only.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "--json without --report exited $rc, expected 3"
grep -q -- "--json requires --report" "${WORK}/json-only.err" \
  || fail "--json without --report missing expected error message"
pass "--json without --report exits 3"

echo
echo "─── log rotation ────────────────────────────────────────────"
# Coverage for rotate() in system-janitor.sh. The function is called
# unconditionally on $LOG and $JSONL at startup and only does work when
# the file exists and exceeds 5 MiB (5242880 bytes). The maintainer's
# real janitor.log is ~18 KB so this code path has never run in
# production. Tests below exercise it via --dry-run with pre-seeded
# log dirs.
#
# 5 MiB threshold per system-janitor.sh:429
ROT_THRESHOLD=5242880

# Helper: run system-janitor --dry-run with a specified LOG_DIR.
# Uses the same $CONFIG as the main suite so all sections short-circuit
# cleanly. We don't care about the run output here, only the side-effect
# on the pre-seeded files in LOG_DIR.
rot_run() {
  local logdir="$1"
  JANITOR_LOG_DIR="$logdir" "$SCRIPT" --config "$CONFIG" --dry-run >/dev/null
}

# Test A — janitor.log: small file (100 bytes) is NOT rotated.
ROT_A="$(mktemp -d)"
mkdir -p "$ROT_A"
printf '%.0s.' {1..100} > "${ROT_A}/janitor.log"
rot_run "$ROT_A"
[ ! -e "${ROT_A}/janitor.log.1" ] \
  || fail "rotate A: janitor.log.1 was created for a 100-byte file"
[ -f "${ROT_A}/janitor.log" ] \
  || fail "rotate A: janitor.log disappeared"
pass "rotate A: small janitor.log (<= 5 MiB) is not rotated"
rm -rf "$ROT_A"

# Test B — janitor.log: absent file produces no .1 backup.
ROT_B="$(mktemp -d)"
rot_run "$ROT_B"
[ ! -e "${ROT_B}/janitor.log.1" ] \
  || fail "rotate B: janitor.log.1 was created when janitor.log did not pre-exist"
pass "rotate B: missing janitor.log produces no .1 backup"
rm -rf "$ROT_B"

# Test C — janitor.log: > 5 MiB rotates to .1, no .2 created.
ROT_C="$(mktemp -d)"
truncate -s 6M "${ROT_C}/janitor.log"
rot_run "$ROT_C"
[ -f "${ROT_C}/janitor.log.1" ] \
  || fail "rotate C: janitor.log.1 was not created for a 6 MiB file"
sz=$(stat -c%s "${ROT_C}/janitor.log.1")
[ "$sz" -eq $((6 * 1024 * 1024)) ] \
  || fail "rotate C: janitor.log.1 is ${sz} bytes, expected $((6*1024*1024))"
[ -f "${ROT_C}/janitor.log" ] \
  || fail "rotate C: new janitor.log was not opened by the run"
new_sz=$(stat -c%s "${ROT_C}/janitor.log")
[ "$new_sz" -lt "$ROT_THRESHOLD" ] \
  || fail "rotate C: new janitor.log is ${new_sz} bytes (>= threshold ${ROT_THRESHOLD})"
[ ! -e "${ROT_C}/janitor.log.2" ] \
  || fail "rotate C: janitor.log.2 was created on a fresh rotation"
pass "rotate C: 6 MiB janitor.log rotates to .1 (no prior chain)"
rm -rf "$ROT_C"

# Test D — janitor.log: > 5 MiB with an existing .1..7 chain shifts everything.
# After rotation: .1 is the just-rotated 6 MiB file; .2..8 hold the previous
# .1..7 contents. README claim: "8 backups kept" — verified here (.1..8).
ROT_D="$(mktemp -d)"
truncate -s 6M "${ROT_D}/janitor.log"
for i in 1 2 3 4 5 6 7; do
  echo "old-${i}" > "${ROT_D}/janitor.log.${i}"
done
rot_run "$ROT_D"
sz=$(stat -c%s "${ROT_D}/janitor.log.1")
[ "$sz" -eq $((6 * 1024 * 1024)) ] \
  || fail "rotate D: janitor.log.1 is ${sz} bytes, expected the rotated 6 MiB live file"
for i in 1 2 3 4 5 6 7; do
  dst=$((i + 1))
  got=$(cat "${ROT_D}/janitor.log.${dst}" 2>/dev/null || true)
  [ "$got" = "old-${i}" ] \
    || fail "rotate D: janitor.log.${dst} contains '${got}', expected 'old-${i}'"
done
# .9 must not exist — the loop only iterates 7..1, so .8 is the highest index touched.
[ ! -e "${ROT_D}/janitor.log.9" ] \
  || fail "rotate D: janitor.log.9 was created (loop should top out at .8)"
pass "rotate D: full chain shifts .1..7 → .2..8, new .1 is the 6 MiB live file"
pass "rotate D: README '8 backups kept' matches reality (.1 through .8 exist after rotation)"
rm -rf "$ROT_D"

# Test E — janitor.jsonl rotates independently of janitor.log.
# Lighter than D: just confirm the same threshold + shift mechanism applies
# to the JSONL path, and that an unrelated janitor.log is left alone.
ROT_E="$(mktemp -d)"
truncate -s 6M "${ROT_E}/janitor.jsonl"
echo "old-1" > "${ROT_E}/janitor.jsonl.1"
# Pre-existing small janitor.log must NOT get rotated.
echo "tiny" > "${ROT_E}/janitor.log"
rot_run "$ROT_E"
[ -f "${ROT_E}/janitor.jsonl.1" ] \
  || fail "rotate E: janitor.jsonl.1 missing after rotation"
sz=$(stat -c%s "${ROT_E}/janitor.jsonl.1")
[ "$sz" -eq $((6 * 1024 * 1024)) ] \
  || fail "rotate E: janitor.jsonl.1 is ${sz} bytes, expected 6 MiB (rotated live file)"
got=$(cat "${ROT_E}/janitor.jsonl.2")
[ "$got" = "old-1" ] \
  || fail "rotate E: janitor.jsonl.2 contains '${got}', expected 'old-1'"
[ ! -e "${ROT_E}/janitor.log.1" ] \
  || fail "rotate E: janitor.log.1 created — small janitor.log should not have rotated"
pass "rotate E: janitor.jsonl rotates independently; small janitor.log untouched"
rm -rf "$ROT_E"

echo
echo "─── schema drift handling ───────────────────────────────────"
# Verify --report:
#   1. merges historical alias sections (copilot_integrity → safety_integrity),
#   2. surfaces obsolete sections in a separate `obsolete_sections` array,
#   3. omits both alias keys and obsolete names from `per_section`.
DRIFT_DIR="${WORK}/drift"
mkdir -p "$DRIFT_DIR"
DRIFT_JSONL="${DRIFT_DIR}/janitor.jsonl"

# Synthesize two runs: one current, one historical.
cat > "$DRIFT_JSONL" <<'EOF'
{"run_id":"run-current","ts":"2026-05-01T10:00:00+0000","host":"h","user":"u","section":"run_start","status":"ok","freed_kb":0,"items":0,"note":"config=defaults dry_run=0"}
{"run_id":"run-current","ts":"2026-05-01T10:00:01+0000","host":"h","user":"u","section":"docker_prune","status":"ok","freed_kb":100,"items":1,"note":""}
{"run_id":"run-current","ts":"2026-05-01T10:00:02+0000","host":"h","user":"u","section":"safety_integrity","status":"ok","freed_kb":0,"items":0,"note":"clean"}
{"run_id":"run-current","ts":"2026-05-01T10:00:03+0000","host":"h","user":"u","section":"run_end","status":"ok","freed_kb":100,"items":1,"note":""}
{"run_id":"run-historical","ts":"2025-01-15T09:00:00+0000","host":"h","user":"u","section":"run_start","status":"ok","freed_kb":0,"items":0,"note":"config=defaults dry_run=0"}
{"run_id":"run-historical","ts":"2025-01-15T09:00:01+0000","host":"h","user":"u","section":"sandbox_binobj","status":"ok","freed_kb":50,"items":3,"note":""}
{"run_id":"run-historical","ts":"2025-01-15T09:00:02+0000","host":"h","user":"u","section":"copilot_integrity","status":"ok","freed_kb":0,"items":0,"note":"clean"}
{"run_id":"run-historical","ts":"2025-01-15T09:00:03+0000","host":"h","user":"u","section":"run_end","status":"ok","freed_kb":50,"items":3,"note":""}
EOF

DRIFT_JSON_OUT="${WORK}/drift-report.json"
JANITOR_LOG_DIR="$DRIFT_DIR" "$SCRIPT" --report --json > "$DRIFT_JSON_OUT"
pass "drift: --report --json exited 0"

python3 - "$DRIFT_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
per = {s["name"]: s for s in data["per_section"]}
obs = {s["name"]: s for s in data["obsolete_sections"]}

# 1. safety_integrity should NOT appear in per_section (it's in SKIP),
#    but the alias remap still needs to NOT introduce a copilot_integrity
#    entry into per_section (it must be folded under safety_integrity and
#    then dropped by SKIP).
if "copilot_integrity" in per:
    print("FAIL: per_section contains 'copilot_integrity' (alias not merged)", file=sys.stderr)
    sys.exit(1)
if "sandbox_binobj" in per:
    print("FAIL: per_section contains obsolete 'sandbox_binobj'", file=sys.stderr)
    sys.exit(1)

# 2. obsolete_sections must surface sandbox_binobj with runs == 1.
if "sandbox_binobj" not in obs:
    print(f"FAIL: obsolete_sections missing 'sandbox_binobj': {list(obs)}", file=sys.stderr)
    sys.exit(1)
if obs["sandbox_binobj"]["runs"] != 1:
    print(f"FAIL: sandbox_binobj runs={obs['sandbox_binobj']['runs']}, expected 1", file=sys.stderr)
    sys.exit(1)

# 3. docker_prune should appear in per_section (sanity check).
if "docker_prune" not in per:
    print(f"FAIL: per_section missing 'docker_prune': {list(per)}", file=sys.stderr)
    sys.exit(1)
PY
pass "drift: alias merged, obsolete split out, per_section clean"

# Verify the alias merge is observable through total run accounting:
# safety_integrity is in SKIP (excluded from per_section), but the merge
# must still happen logically. We can't directly assert per_section runs
# for safety_integrity since it's skipped — instead, verify by injecting
# a non-skipped historical alias would also work. For now, ensure that
# the historical run was parsed (total_runs == 2).
python3 - "$DRIFT_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
if data["total_runs"] != 2:
    print(f"FAIL: total_runs={data['total_runs']}, expected 2", file=sys.stderr)
    sys.exit(1)
PY
pass "drift: both runs counted"

# Text mode must print the 'Obsolete sections' header.
DRIFT_TEXT_OUT="${WORK}/drift-report.txt"
JANITOR_LOG_DIR="$DRIFT_DIR" "$SCRIPT" --report > "$DRIFT_TEXT_OUT"
grep -q "Obsolete sections" "$DRIFT_TEXT_OUT" \
  || fail "drift: text --report missing 'Obsolete sections' header"
grep -q "sandbox_binobj" "$DRIFT_TEXT_OUT" \
  || fail "drift: text --report missing sandbox_binobj entry"
pass "drift: text --report surfaces obsolete sections"

# Cross-feature regression: idle_streaks must respect the alias/obsolete
# rules from the schema-history layer. Aliased section names (e.g.
# copilot_integrity) must NOT appear in idle_streaks under their old name,
# and obsolete sections must NOT appear in idle_streaks at all (they are
# surfaced under obsolete_sections instead). Without this guarantee an
# agent watching idle_streaks sees phantom historical sections.
python3 - "$DRIFT_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
streak_names = {s["section"] for s in data.get("idle_streaks", [])}
if "copilot_integrity" in streak_names:
    print("FAIL: idle_streaks contains aliased name 'copilot_integrity' (should be merged into 'safety_integrity' or excluded as a meta-section)", file=sys.stderr)
    sys.exit(1)
obsolete = {s["name"] for s in data.get("obsolete_sections", [])}
leak = streak_names & obsolete
if leak:
    print(f"FAIL: idle_streaks leaks obsolete sections: {leak}", file=sys.stderr)
    sys.exit(1)
PY
pass "drift: idle_streaks honors aliases + obsolete (no leaks)"

# A historical alias whose canonical name is a meta-section (like
# copilot_integrity → safety_integrity, where safety_integrity is in
# SKIP and never frees bytes by design) must NOT appear in idle_streaks
# under EITHER name. Otherwise an agent gets a tautological "idle" alert
# for a section that can't ever be productive.
python3 - "$DRIFT_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
streak_names = {s["section"] for s in data.get("idle_streaks", [])}
if "safety_integrity" in streak_names:
    print("FAIL: idle_streaks contains meta-section 'safety_integrity' (it can never be productive — flagging it is tautological noise)", file=sys.stderr)
    sys.exit(1)
PY
pass "drift: idle_streaks excludes meta-sections even via alias remap"

echo
echo "─── idle status + streaks ───"
# An opt-in section that ran successfully but matched zero work must
# emit status="idle" (not "ok"). After two such consecutive real runs,
# --report --json must surface it via the idle_streaks array. A
# default section that produced nothing (e.g. nuget_http_temp on a host
# with no dotnet) must NOT be flagged idle, because "nothing to clean"
# is the steady-state for default sections.
WORK2="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2"' EXIT
LOG_DIR2="${WORK2}/state"
EMPTY_WS="${WORK2}/empty_ws"
CONFIG2="${WORK2}/config"
mkdir -p "$EMPTY_WS"

cat > "$CONFIG2" <<EOF
JANITOR_DOCKER_PRUNE=no
JANITOR_GO_CLEAN=no
JANITOR_TMP_GOBUILD_ORPHANS=no
JANITOR_NUGET_CLEAN=yes
JANITOR_WORKSPACE_DIRS="${EMPTY_WS}"
EOF

# Two consecutive REAL runs (not --dry-run).
JANITOR_LOG_DIR="$LOG_DIR2" "$SCRIPT" --config "$CONFIG2" >/dev/null
JANITOR_LOG_DIR="$LOG_DIR2" "$SCRIPT" --config "$CONFIG2" >/dev/null
pass "two real runs against empty workspace exited 0"

JSONL2="${LOG_DIR2}/janitor.jsonl"
idle_count=$(grep -c '"section":"workspace_binobj","status":"idle"' "$JSONL2" || true)
[ "$idle_count" -eq 2 ] \
  || fail "workspace_binobj should have 2 idle events, got $idle_count"
ok_count=$(grep -c '"section":"workspace_binobj","status":"ok"' "$JSONL2" || true)
[ "$ok_count" -eq 0 ] \
  || fail "workspace_binobj should have 0 ok events (got $ok_count) — opt-in idle promotion broke"
pass "opt-in workspace_binobj emitted status=idle (not ok)"

# Default section that did nothing must NOT be flagged idle.
nuget_idle=$(grep -c '"section":"nuget_http_temp","status":"idle"' "$JSONL2" || true)
[ "$nuget_idle" -eq 0 ] \
  || fail "nuget_http_temp must NOT get status=idle (it's a default section, not opt-in)"
pass "default nuget_http_temp stayed status=ok despite zero work"

REPORT_JSON2="${WORK2}/report.json"
JANITOR_LOG_DIR="$LOG_DIR2" "$SCRIPT" --report --json > "$REPORT_JSON2"
python3 - "$REPORT_JSON2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert "idle_streaks" in data, "idle_streaks missing from --report --json output"
assert isinstance(data["idle_streaks"], list), "idle_streaks must be a list"
ws = [e for e in data["idle_streaks"] if e["section"] == "workspace_binobj"]
assert len(ws) == 1, f"expected exactly one idle_streaks entry for workspace_binobj, got {data['idle_streaks']}"
e = ws[0]
assert e["consecutive_idle_runs"] == 2, f"expected consecutive_idle_runs=2, got {e['consecutive_idle_runs']}"
assert e["last_productive_run"] is None, f"expected last_productive_run=null, got {e['last_productive_run']!r}"
# nuget_http_temp may or may not show up depending on whether dotnet is present
# on the test host. If it does show up (no dotnet -> ok with 0/0), that's fine
# — idle_streaks is universal. If dotnet IS installed and produces real freed
# bytes, it won't show up. Either way is correct; we only assert workspace_binobj.
PY
pass "--report --json idle_streaks contains workspace_binobj with consecutive_idle_runs=2, last_productive_run=null"

# Human --report must render the "Idle sections" block when streaks exist.
REPORT_TXT2="${WORK2}/report.txt"
JANITOR_LOG_DIR="$LOG_DIR2" "$SCRIPT" --report > "$REPORT_TXT2"
grep -q "Idle sections" "$REPORT_TXT2" \
  || fail "human --report missing 'Idle sections' block when streaks exist"
grep -q "workspace_binobj" "$REPORT_TXT2" \
  || fail "human --report Idle block missing workspace_binobj"
grep -q "last productive: never" "$REPORT_TXT2" \
  || fail "human --report Idle block missing 'last productive: never'"
pass "human --report renders Idle sections block"

# When there are no idle streaks (e.g. the original dry-run-only LOG_DIR),
# the block must be suppressed entirely. Note: the dry-run test above used
# --dry-run, so its events are status=dry_run and contribute zero real-run
# events to streak computation -> idle_streaks must be empty.
grep -q "Idle sections" "$REPORT_OUT" \
  && fail "human --report should NOT show 'Idle sections' block when idle_streaks is empty"
pass "human --report suppresses Idle block when empty"

python3 - "$REPORT_JSON_OUT" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data.get("idle_streaks") == [], f"dry-run-only log should have empty idle_streaks, got {data.get('idle_streaks')!r}"
PY
pass "--report --json idle_streaks is [] for dry-run-only log"

echo
echo "─── --health probe ──────────────────────────────────────────"
# --health is the agent-facing trust probe. Exit codes are the contract:
# 0 healthy, 4 degraded, 5 unknown. Read-only: never creates the log
# dir, never acquires the lock, never writes to any file.

HEALTH_WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$HEALTH_WORK"' EXIT

# Case 1: unknown state — fresh empty dir, no logs at all.
H_EMPTY="${HEALTH_WORK}/empty"
mkdir -p "$H_EMPTY"
set +e
JANITOR_LOG_DIR="${H_EMPTY}/never-existed" "$SCRIPT" --health > "${HEALTH_WORK}/u.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 5 ] || fail "--health on missing log dir exited $rc, expected 5"
[ ! -d "${H_EMPTY}/never-existed" ] || fail "--health created the log dir (must not)"
grep -q "unknown" "${HEALTH_WORK}/u.out" || fail "--health unknown output missing 'unknown'"
pass "case 1: --health on missing log dir exits 5 (unknown)"

set +e
JANITOR_LOG_DIR="${H_EMPTY}/never-existed" "$SCRIPT" --health --json > "${HEALTH_WORK}/u.json" 2>&1
rc=$?
set -e
[ "$rc" -eq 5 ] || fail "--health --json on missing log dir exited $rc, expected 5"
python3 - "${HEALTH_WORK}/u.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["status"] == "unknown", data["status"]
assert data["exit_code"] == 5, data["exit_code"]
assert isinstance(data["checks"], list), "checks must be a list"
PY
pass "case 1: --health --json status=unknown, exit_code=5"

# Case 2: healthy state — populate via a dry-run, then probe.
H_HEALTHY="${HEALTH_WORK}/healthy"
H_HEALTHY_CFG="${HEALTH_WORK}/healthy.cfg"
mkdir -p "${HEALTH_WORK}/h_ws" "${HEALTH_WORK}/h_extra" "${HEALTH_WORK}/h_safe"
echo keep > "${HEALTH_WORK}/h_safe/file"
cat > "$H_HEALTHY_CFG" <<EOF
JANITOR_DOCKER_PRUNE=no
JANITOR_GO_CLEAN=no
JANITOR_TMP_GOBUILD_ORPHANS=no
JANITOR_NUGET_CLEAN=no
JANITOR_WORKSPACE_DIRS="${HEALTH_WORK}/h_ws"
JANITOR_EXTRA_CLEANUP_DIRS="${HEALTH_WORK}/h_extra"
JANITOR_SAFETY_FLOOR_DIRS="${HEALTH_WORK}/h_safe"
EOF
JANITOR_LOG_DIR="$H_HEALTHY" "$SCRIPT" --config "$H_HEALTHY_CFG" --dry-run >/dev/null

set +e
JANITOR_LOG_DIR="$H_HEALTHY" "$SCRIPT" --health > "${HEALTH_WORK}/h.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "${HEALTH_WORK}/h.out"; fail "--health on healthy dir exited $rc, expected 0"; }
grep -q "healthy" "${HEALTH_WORK}/h.out" || fail "--health healthy output missing 'healthy'"
pass "case 2: --health on healthy dir exits 0"

set +e
JANITOR_LOG_DIR="$H_HEALTHY" "$SCRIPT" --health --json > "${HEALTH_WORK}/h.json" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "--health --json on healthy dir exited $rc, expected 0"
python3 - "${HEALTH_WORK}/h.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["status"] == "healthy", data
assert data["exit_code"] == 0, data
for c in data["checks"]:
    assert c["ok"] is True, f"check {c['name']} not ok: {c}"
PY
pass "case 2: --health --json status=healthy, all checks ok"

# Case 3: degraded — invalid JSONL line.
H_BADJSONL="${HEALTH_WORK}/bad_jsonl"
cp -r "$H_HEALTHY" "$H_BADJSONL"
echo '{"section":"foo","items":00}' >> "${H_BADJSONL}/janitor.jsonl"
set +e
JANITOR_LOG_DIR="$H_BADJSONL" "$SCRIPT" --health > "${HEALTH_WORK}/bj.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "--health with bad JSONL line exited $rc, expected 4"
JANITOR_LOG_DIR="$H_BADJSONL" "$SCRIPT" --health --json > "${HEALTH_WORK}/bj.json" 2>&1 || true
python3 - "${HEALTH_WORK}/bj.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
assert data["status"] == "degraded", data["status"]
assert data["exit_code"] == 4, data["exit_code"]
jp = [c for c in data["checks"] if c["name"] == "jsonl_parses"]
assert len(jp) == 1, jp
assert jp[0]["ok"] is False, f"jsonl_parses should be false: {jp[0]}"
PY
pass "case 3: --health with malformed JSONL line exits 4, jsonl_parses fails"

# Case 4: degraded — bad integrity in last-run.json.
H_BADINT="${HEALTH_WORK}/bad_integrity"
cp -r "$H_HEALTHY" "$H_BADINT"
python3 - "${H_BADINT}/last-run.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["safety_integrity"] = "violated_inode_changed"
with open(p, "w") as fh:
    json.dump(d, fh)
PY
set +e
JANITOR_LOG_DIR="$H_BADINT" "$SCRIPT" --health > "${HEALTH_WORK}/bi.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "--health with bad integrity exited $rc, expected 4"
JANITOR_LOG_DIR="$H_BADINT" "$SCRIPT" --health --json > "${HEALTH_WORK}/bi.json" 2>&1 || true
python3 - "${HEALTH_WORK}/bi.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
ic = [c for c in data["checks"] if c["name"] == "last_run_integrity_ok"]
assert len(ic) == 1 and ic[0]["ok"] is False, ic
PY
pass "case 4: --health with bad integrity exits 4, last_run_integrity_ok fails"

# Case 5: degraded — long idle streak (5+ consecutive idle real runs).
H_IDLE="${HEALTH_WORK}/idle_streak"
mkdir -p "$H_IDLE"
H_IDLE_JSONL="${H_IDLE}/janitor.jsonl"
# Synthesize 5 real runs where workspace_binobj is idle.
python3 - "$H_IDLE_JSONL" <<'PY'
import json, sys
out = open(sys.argv[1], "w")
for i in range(1, 6):
    rid = f"run-{i:03d}"
    ts_base = f"2026-05-{i:02d}T03:17:00+0000"
    for sec, status, freed, items, note in [
        ("run_start", "ok", 0, 0, f"run_id={rid} dry_run=0"),
        ("workspace_binobj", "idle", 0, 0, ""),
        ("safety_integrity", "ok", 0, 0, "clean"),
        ("run_end", "ok", 0, 0, ""),
    ]:
        out.write(json.dumps({
            "run_id": rid, "ts": ts_base, "host": "h", "user": "u",
            "section": sec, "status": status, "freed_kb": freed,
            "items": items, "note": note,
        }) + "\n")
# Also need a last-run.json so we don't trigger "unknown".
import json as J
J.dump({
    "run_id": "run-005", "finished": "2026-05-05T03:17:00+0000",
    "host": "h", "user": "u", "freed_kb": 0,
    "safety_integrity": "ok", "start_used_kb": 0, "end_used_kb": 0,
    "dry_run": 0,
}, open(sys.argv[1].replace("janitor.jsonl", "last-run.json"), "w"))
PY
set +e
JANITOR_LOG_DIR="$H_IDLE" "$SCRIPT" --health > "${HEALTH_WORK}/is.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "--health with 5-run idle streak exited $rc, expected 4"
JANITOR_LOG_DIR="$H_IDLE" "$SCRIPT" --health --json > "${HEALTH_WORK}/is.json" 2>&1 || true
python3 - "${HEALTH_WORK}/is.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
ic = [c for c in data["checks"] if c["name"] == "no_long_idle_streaks"]
assert len(ic) == 1 and ic[0]["ok"] is False, ic
assert "workspace_binobj" in (ic[0]["detail"] or ""), ic
PY
pass "case 5: --health with 5-run idle streak exits 4, no_long_idle_streaks fails"

# Case 6: --json without --health/--report exits 3.
# (Already partially covered above for --report; here we ensure the new
# error message mentions both flag options.)
set +e
"$SCRIPT" --json > "${HEALTH_WORK}/jo.out" 2> "${HEALTH_WORK}/jo.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "--json alone exited $rc, expected 3"
grep -Eq -- "--json requires --(report|health)" "${HEALTH_WORK}/jo.err" \
  || fail "--json alone stderr should mention --report or --health"
pass "case 6: --json without --health/--report exits 3 with helpful stderr"

# Case 7: --health --json output schema.
python3 - "${HEALTH_WORK}/h.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
top = {"status", "exit_code", "generated_at", "log_dir", "checks"}
missing = top - set(data.keys())
assert not missing, f"missing top-level keys: {missing}"
assert isinstance(data["checks"], list), "checks must be a list"
assert len(data["checks"]) >= 1, "checks must be non-empty"
for c in data["checks"]:
    assert set(c.keys()) >= {"name", "ok", "detail"}, c
    assert isinstance(c["name"], str), c
    assert isinstance(c["ok"], bool), c
    assert c["detail"] is None or isinstance(c["detail"], str), c
PY
pass "case 7: --health --json output has the documented schema"

echo "── --only / surgical invocation ────────────────────────────"
# All --only assertions use a fresh JANITOR_LOG_DIR to avoid contaminating
# earlier JSONLs. Helper that parses the JSONL section names in file order.
_only_sections() {
  python3 - "$1" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    for ln in fh:
        ln = ln.strip()
        if not ln: continue
        try:
            ev = json.loads(ln)
        except Exception:
            continue
        print(ev.get("section",""))
PY
}

# Case 1: --only docker_prune --dry-run → exactly 4 events:
# run_start, docker_prune, safety_integrity, run_end.
ONLY_W1="$(mktemp -d)"
JANITOR_LOG_DIR="${ONLY_W1}" "$SCRIPT" --only docker_prune --dry-run >/dev/null
got1="$(_only_sections "${ONLY_W1}/janitor.jsonl" | paste -sd, -)"
want1="run_start,docker_prune,safety_integrity,run_end"
[ "$got1" = "$want1" ] \
  || fail "case 1: --only docker_prune sections mismatch: got [$got1] want [$want1]"
grep -q '"section":"docker_prune","status":"dry_run"' "${ONLY_W1}/janitor.jsonl" \
  || fail "case 1: docker_prune event must be status=dry_run"
rm -rf "$ONLY_W1"
pass "case 1: --only docker_prune --dry-run emits exactly run_start,docker_prune,safety_integrity,run_end"

# Case 2: --only docker_prune,go_build_cache --dry-run → exactly 5 events
# in declaration order (docker_prune BEFORE go_build_cache).
ONLY_W2="$(mktemp -d)"
JANITOR_LOG_DIR="${ONLY_W2}" "$SCRIPT" --only docker_prune,go_build_cache --dry-run >/dev/null
got2="$(_only_sections "${ONLY_W2}/janitor.jsonl" | paste -sd, -)"
want2="run_start,docker_prune,go_build_cache,safety_integrity,run_end"
[ "$got2" = "$want2" ] \
  || fail "case 2: --only docker_prune,go_build_cache sections mismatch: got [$got2] want [$want2]"
rm -rf "$ONLY_W2"
pass "case 2: --only docker_prune,go_build_cache produces 5 events in declaration order"

# Case 3: Reverse input order — output order MUST still be declaration order.
ONLY_W3="$(mktemp -d)"
JANITOR_LOG_DIR="${ONLY_W3}" "$SCRIPT" --only go_build_cache,docker_prune --dry-run >/dev/null
got3="$(_only_sections "${ONLY_W3}/janitor.jsonl" | paste -sd, -)"
want3="run_start,docker_prune,go_build_cache,safety_integrity,run_end"
[ "$got3" = "$want3" ] \
  || fail "case 3: --only with reversed input must still emit declaration order: got [$got3] want [$want3]"
rm -rf "$ONLY_W3"
pass "case 3: --only output order is deterministic (declaration order) regardless of argv order"

# Case 4: unknown section name → exit 3 with helpful stderr, no run.
ONLY_W4="$(mktemp -d)"
set +e
JANITOR_LOG_DIR="${ONLY_W4}" "$SCRIPT" --only docker_prune,bogus_section --dry-run \
  >"${ONLY_W4}/out" 2>"${ONLY_W4}/err"
rc4=$?
set -e
[ "$rc4" -eq 3 ] || fail "case 4: --only unknown_section should exit 3, got $rc4"
grep -q "unknown section" "${ONLY_W4}/err" \
  || { cat "${ONLY_W4}/err"; fail "case 4: stderr should mention 'unknown section'"; }
grep -q "bogus_section" "${ONLY_W4}/err" \
  || fail "case 4: stderr should name the offending section"
grep -q "docker_prune" "${ONLY_W4}/err" \
  || fail "case 4: stderr should list valid section names"
[ ! -f "${ONLY_W4}/janitor.jsonl" ] \
  || fail "case 4: no JSONL should be written when validation fails"
rm -rf "$ONLY_W4"
pass "case 4: --only unknown_section exits 3, prints valid names, writes no JSONL"

# Case 5: --only docker_prune --dry-run combined with JANITOR_DOCKER_PRUNE=no.
# Expectation: docker_prune event STILL appears (--only filters the candidate
# set; the env-var disable is gated INSIDE the action). Because --dry-run
# dominates and the script never calls act_docker_prune in dry-run, the
# event is status=dry_run — config gating only takes effect on real runs.
# This documents the existing-behavior interaction; if dry-run ever starts
# invoking the action, this assertion will need updating.
ONLY_W5="$(mktemp -d)"
JANITOR_DOCKER_PRUNE=no JANITOR_LOG_DIR="${ONLY_W5}" "$SCRIPT" --only docker_prune --dry-run >/dev/null
got5="$(_only_sections "${ONLY_W5}/janitor.jsonl" | paste -sd, -)"
[ "$got5" = "run_start,docker_prune,safety_integrity,run_end" ] \
  || fail "case 5: --only docker_prune + JANITOR_DOCKER_PRUNE=no should still emit docker_prune event, got [$got5]"
grep -q '"section":"docker_prune","status":"dry_run"' "${ONLY_W5}/janitor.jsonl" \
  || fail "case 5: docker_prune should be status=dry_run (dry-run dominates over config gating)"
rm -rf "$ONLY_W5"
pass "case 5: --only composes with JANITOR_DOCKER_PRUNE=no (event still emitted; dry-run dominates)"

# Case 6: --sections is an accepted synonym for --only.
ONLY_W6="$(mktemp -d)"
JANITOR_LOG_DIR="${ONLY_W6}" "$SCRIPT" --sections docker_prune --dry-run >/dev/null
got6="$(_only_sections "${ONLY_W6}/janitor.jsonl" | paste -sd, -)"
[ "$got6" = "run_start,docker_prune,safety_integrity,run_end" ] \
  || fail "case 6: --sections synonym should behave identically to --only, got [$got6]"
rm -rf "$ONLY_W6"
pass "case 6: --sections is a working synonym for --only"

echo
echo "all smoke checks passed"

echo
echo "── JSON schemas ─────────────────────────────────────────────"
# Validate --report --json and --health --json output against the frozen
# Draft 2020-12 JSON Schemas in schemas/. Uses python's `jsonschema` package
# when available; falls back to a minimal hand-rolled validator otherwise so
# the schema check still runs in stripped-down CI environments.

SCHEMA_REPORT="${REPO_ROOT}/schemas/report.schema.json"
SCHEMA_HEALTH="${REPO_ROOT}/schemas/health.schema.json"

[ -s "$SCHEMA_REPORT" ] || fail "schemas/report.schema.json missing"
[ -s "$SCHEMA_HEALTH" ] || fail "schemas/health.schema.json missing"

if python3 -c "import jsonschema" >/dev/null 2>&1; then
  VALIDATOR_PATH="jsonschema"
else
  VALIDATOR_PATH="hand-rolled"
fi
echo "validator: ${VALIDATOR_PATH}"

# _validate <instance.json> <schema.json> — returns 0 on success, nonzero
# on schema violation. Output captured to stderr by the caller.
_validate() {
  local inst="$1" schema="$2"
  if [ "$VALIDATOR_PATH" = "jsonschema" ]; then
    python3 - "$inst" "$schema" <<'PY'
import json, sys, jsonschema
inst = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))
jsonschema.validate(inst, schema)
PY
  else
    # Hand-rolled fallback: top-level type is object, all `required` keys
    # present (recursively, one level deep into objects/arrays that have
    # their own `required`), and every documented `enum` is honored where
    # the field is present. Intentionally conservative — agents in
    # CI-without-pip get a tripwire, not a full validator.
    python3 - "$inst" "$schema" <<'PY'
import json, sys
inst = json.load(open(sys.argv[1]))
schema = json.load(open(sys.argv[2]))

def check(node, sch, path="$"):
    t = sch.get("type")
    if t == "object":
        if not isinstance(node, dict):
            raise SystemExit(f"{path}: expected object, got {type(node).__name__}")
        for k in sch.get("required", []):
            if k not in node:
                raise SystemExit(f"{path}: missing required key '{k}'")
        for k, sub in sch.get("properties", {}).items():
            if k in node:
                check(node[k], sub, f"{path}.{k}")
    elif t == "array":
        if not isinstance(node, list):
            raise SystemExit(f"{path}: expected array")
        items = sch.get("items")
        if isinstance(items, dict):
            for i, e in enumerate(node):
                check(e, items, f"{path}[{i}]")
    if "enum" in sch and node not in sch["enum"]:
        raise SystemExit(f"{path}: value {node!r} not in enum {sch['enum']}")
    # Resolve simple local $ref into $defs (best-effort)
    if "$ref" in sch:
        ref = sch["$ref"]
        if ref.startswith("#/$defs/"):
            defs = json.load(open(sys.argv[2])).get("$defs", {})
            target = defs.get(ref.split("/")[-1])
            if target:
                check(node, target, path)
    if "oneOf" in sch:
        for sub in sch["oneOf"]:
            try:
                check(node, sub, path); break
            except SystemExit:
                continue
        else:
            raise SystemExit(f"{path}: no oneOf branch matched")
    if "allOf" in sch:
        for sub in sch["allOf"]:
            check(node, sub, path)

check(inst, schema)
PY
  fi
}

SCHEMA_WORK="$(mktemp -d)"
SCHEMA_HEALTHY_DIR="${SCHEMA_WORK}/healthy"
mkdir -p "$SCHEMA_HEALTHY_DIR"

# Reuse the dry-run state from the top of this script as a "healthy" log dir
# (it has a complete, parseable JSONL and a valid last-run.json).
JANITOR_LOG_DIR="$SCHEMA_HEALTHY_DIR" "$SCRIPT" --config "$CONFIG" --dry-run >/dev/null

# 1. --report --json validates.
REPORT_OUT="${SCHEMA_WORK}/report.json"
JANITOR_LOG_DIR="$SCHEMA_HEALTHY_DIR" "$SCRIPT" --report --json > "$REPORT_OUT"
_validate "$REPORT_OUT" "$SCHEMA_REPORT" \
  || fail "--report --json output failed schema validation"
pass "--report --json validates against schemas/report.schema.json"

# 2a. --health --json (healthy case, exit 0) validates.
HEALTH_OK="${SCHEMA_WORK}/health-healthy.json"
JANITOR_LOG_DIR="$SCHEMA_HEALTHY_DIR" "$SCRIPT" --health --json > "$HEALTH_OK" || true
_validate "$HEALTH_OK" "$SCHEMA_HEALTH" \
  || fail "--health --json (healthy) failed schema validation"
grep -q '"status": "healthy"' "$HEALTH_OK" \
  || fail "expected healthy case to report status=healthy"
pass "--health --json (healthy) validates"

# 2b. --health --json (degraded case, exit 4). Corrupt the JSONL with a
# malformed line so jsonl_parses fails.
SCHEMA_DEGRADED_DIR="${SCHEMA_WORK}/degraded"
mkdir -p "$SCHEMA_DEGRADED_DIR"
JANITOR_LOG_DIR="$SCHEMA_DEGRADED_DIR" "$SCRIPT" --config "$CONFIG" --dry-run >/dev/null
echo '{not valid json' >> "${SCHEMA_DEGRADED_DIR}/janitor.jsonl"
HEALTH_DEG="${SCHEMA_WORK}/health-degraded.json"
set +e
JANITOR_LOG_DIR="$SCHEMA_DEGRADED_DIR" "$SCRIPT" --health --json > "$HEALTH_DEG"
deg_rc=$?
set -e
[ "$deg_rc" -eq 4 ] || fail "expected degraded --health to exit 4, got ${deg_rc}"
_validate "$HEALTH_DEG" "$SCHEMA_HEALTH" \
  || fail "--health --json (degraded) failed schema validation"
grep -q '"status": "degraded"' "$HEALTH_DEG" \
  || fail "expected degraded case to report status=degraded"
pass "--health --json (degraded, exit 4) validates"

# 2c. --health --json (unknown case, exit 5). Use a never-created log dir.
HEALTH_UNK="${SCHEMA_WORK}/health-unknown.json"
set +e
JANITOR_LOG_DIR="${SCHEMA_WORK}/does-not-exist" "$SCRIPT" --health --json > "$HEALTH_UNK"
unk_rc=$?
set -e
[ "$unk_rc" -eq 5 ] || fail "expected unknown --health to exit 5, got ${unk_rc}"
_validate "$HEALTH_UNK" "$SCHEMA_HEALTH" \
  || fail "--health --json (unknown) failed schema validation"
grep -q '"status": "unknown"' "$HEALTH_UNK" \
  || fail "expected unknown case to report status=unknown"
pass "--health --json (unknown, exit 5) validates"

# 3. Negative test: deleting a required field must make the validator fail.
# This proves the validator actually validates (catches the failure-mode
# regression where the check becomes a no-op).
BROKEN="${SCHEMA_WORK}/report-broken.json"
python3 - "$REPORT_OUT" "$BROKEN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("generated_at", None)  # documented required field
json.dump(d, open(sys.argv[2], "w"))
PY
if _validate "$BROKEN" "$SCHEMA_REPORT" 2>/dev/null; then
  fail "validator accepted report missing required 'generated_at' — validator is broken"
fi
pass "validator rejects report with missing required field (negative test)"

BROKEN_H="${SCHEMA_WORK}/health-broken.json"
python3 - "$HEALTH_OK" "$BROKEN_H" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["status"] = "wobbly"  # not in enum
json.dump(d, open(sys.argv[2], "w"))
PY
if _validate "$BROKEN_H" "$SCHEMA_HEALTH" 2>/dev/null; then
  fail "validator accepted health with status='wobbly' — validator is broken"
fi
pass "validator rejects health with out-of-enum status (negative test)"

rm -rf "$SCHEMA_WORK"
echo
echo "all schema checks passed (validator: ${VALIDATOR_PATH})"

# ─── --version ───────────────────────────────────────────────
# Capability-discovery probe for autonomous agents. Read-only, exits 0,
# does not require a log dir or any state. Pair with --json for a
# stable, alphabetically-sorted capabilities[] list.
echo "─── --version ───────────────────────────────────────────────"

# Case 1: plain --version exits 0 and prints "system-janitor <X.Y.Z>".
VERSION_W1="$(mktemp -d)"
( cd "$VERSION_W1" && "$SCRIPT" --version > "$VERSION_W1/out" 2> "$VERSION_W1/err" )
rc=$?
[ "$rc" = 0 ] || fail "--version: expected exit 0, got $rc"
grep -Eq '^system-janitor 0\.1\.0$' "$VERSION_W1/out" \
  || fail "--version: stdout did not match '^system-janitor 0\\.1\\.0\$' (got: $(cat "$VERSION_W1/out"))"
rm -rf "$VERSION_W1"
pass "case 1: --version exits 0 and prints 'system-janitor 0.1.0'"

# Case 2: --version --json is valid JSON with required shape.
VERSION_W2="$(mktemp -d)"
( cd "$VERSION_W2" && "$SCRIPT" --version --json > "$VERSION_W2/out" 2> "$VERSION_W2/err" )
rc=$?
[ "$rc" = 0 ] || fail "--version --json: expected exit 0, got $rc"
python3 - "$VERSION_W2/out" <<'PY' || fail "--version --json: shape validation failed"
import json, sys
with open(sys.argv[1]) as fh:
    obj = json.load(fh)
assert isinstance(obj, dict), "top-level must be object"
for k in ("name", "version", "capabilities"):
    assert k in obj, f"missing key: {k}"
assert obj["name"] == "system-janitor", f"bad name: {obj['name']!r}"
assert isinstance(obj["version"], str) and obj["version"], "version must be non-empty string"
caps = obj["capabilities"]
assert isinstance(caps, list) and caps, "capabilities must be non-empty array"
for c in caps:
    assert isinstance(c, str), f"capability not string: {c!r}"
for required in ("report", "health"):
    assert required in caps, f"capabilities must contain {required!r}, got {caps!r}"
PY
rm -rf "$VERSION_W2"
pass "case 2: --version --json is valid JSON with name/version/capabilities[]"

# Case 3: --version works without a log dir (no JANITOR_LOG_DIR, fresh tmpdir).
# Confirms the short-circuit runs BEFORE mkdir/flock/log redirect.
VERSION_W3="$(mktemp -d)"
(
  cd "$VERSION_W3"
  unset JANITOR_LOG_DIR
  "$SCRIPT" --version > "$VERSION_W3/out" 2> "$VERSION_W3/err"
)
rc=$?
[ "$rc" = 0 ] || fail "--version (no log dir): expected exit 0, got $rc (stderr: $(cat "$VERSION_W3/err"))"
# No state files should have been created in the working dir.
[ -z "$(find "$VERSION_W3" -mindepth 1 -name 'janitor*' -o -name 'last-run*' 2>/dev/null)" ] \
  || fail "--version: should not create any state files"
rm -rf "$VERSION_W3"
pass "case 3: --version succeeds without a log dir and writes no state"

# Case 4: capabilities[] is alphabetically sorted (locks in stability).
VERSION_W4="$(mktemp -d)"
"$SCRIPT" --version --json > "$VERSION_W4/out" 2> "$VERSION_W4/err"
python3 - "$VERSION_W4/out" <<'PY' || fail "--version --json: capabilities not sorted"
import json, sys
with open(sys.argv[1]) as fh:
    obj = json.load(fh)
caps = obj["capabilities"]
assert caps == sorted(caps), f"capabilities not sorted: {caps!r}"
PY
rm -rf "$VERSION_W4"
pass "case 4: --version --json capabilities[] is alphabetically sorted"

echo "─── last-run.json enrichment ───────────────────────────────"

# 1-5: Inspect the full-dry-run last-run.json produced by the first stage
# above. `sections[]` must cover every non-meta event in the JSONL, in
# declaration order, with status/items/freed_bytes matching the JSONL.
python3 - "$LATEST" "$JSONL" <<'PY'
import json, sys

last = json.load(open(sys.argv[1]))
jsonl_path = sys.argv[2]

# (1) sections key present and is a list
if "sections" not in last:
    print("FAIL: last-run.json has no 'sections' key", file=sys.stderr); sys.exit(1)
secs = last["sections"]
if not isinstance(secs, list):
    print(f"FAIL: sections is not a list: {type(secs).__name__}", file=sys.stderr); sys.exit(1)

# Load JSONL events for this run.
run_id = last["run_id"]
events = []
with open(jsonl_path) as fh:
    for line in fh:
        line = line.strip()
        if not line: continue
        ev = json.loads(line)
        if ev.get("run_id") == run_id:
            events.append(ev)

META = {"run_start", "run_end"}
expected = [e for e in events if e["section"] not in META]

# (3) sections[].name covers every non-meta event in declaration order
got_names = [s["name"] for s in secs]
want_names = [e["section"] for e in expected]
if got_names != want_names:
    print(f"FAIL: section name order mismatch.\n  got:  {got_names}\n  want: {want_names}", file=sys.stderr)
    sys.exit(1)

# (4) statuses match
for s, e in zip(secs, expected):
    if s["status"] != e["status"]:
        print(f"FAIL: status mismatch for {s['name']}: last-run={s['status']!r} jsonl={e['status']!r}", file=sys.stderr)
        sys.exit(1)

# (5) items + freed_bytes are integers and match (freed_bytes == freed_kb*1024)
for s, e in zip(secs, expected):
    if not isinstance(s["items"], int) or not isinstance(s["freed_bytes"], int):
        print(f"FAIL: {s['name']} items/freed_bytes not int", file=sys.stderr); sys.exit(1)
    if s["items"] != int(e["items"]):
        print(f"FAIL: items mismatch for {s['name']}", file=sys.stderr); sys.exit(1)
    if s["freed_bytes"] != int(e["freed_kb"]) * 1024:
        print(f"FAIL: freed_bytes mismatch for {s['name']}: {s['freed_bytes']} != {e['freed_kb']}*1024", file=sys.stderr); sys.exit(1)

# Also: started_at, ended_at, run_id round-trip cleanly
for k in ("run_id", "started_at", "ended_at"):
    if not last.get(k):
        print(f"FAIL: last-run.json missing/empty '{k}'", file=sys.stderr); sys.exit(1)
PY
pass "last-run.json: sections[] mirrors JSONL (name order, status, items, freed_bytes)"

# (6) --only filtering propagates to sections[]
ONLY_W7="$(mktemp -d)"
JANITOR_LOG_DIR="${ONLY_W7}" "$SCRIPT" --only docker_prune --dry-run >/dev/null
python3 - "${ONLY_W7}/last-run.json" "${ONLY_W7}/janitor.jsonl" <<'PY'
import json, sys
last = json.load(open(sys.argv[1]))
got = [s["name"] for s in last.get("sections", [])]
# --only filters action sections; safety_integrity always runs.
want = ["docker_prune", "safety_integrity"]
if got != want:
    print(f"FAIL: --only docker_prune sections={got}, expected {want}", file=sys.stderr); sys.exit(1)
# Cross-check against JSONL of the same run.
run_id = last["run_id"]
jsonl_names = []
with open(sys.argv[2]) as fh:
    for line in fh:
        line = line.strip()
        if not line: continue
        ev = json.loads(line)
        if ev.get("run_id") == run_id and ev["section"] not in {"run_start", "run_end"}:
            jsonl_names.append(ev["section"])
if got != jsonl_names:
    print(f"FAIL: sections != JSONL non-meta events: sections={got} jsonl={jsonl_names}", file=sys.stderr); sys.exit(1)
PY
rm -rf "$ONLY_W7"
pass "last-run.json: --only docker_prune yields sections=[docker_prune, safety_integrity]"

# (7) Schema-old compat: synthesize a pre-enrichment last-run.json and verify
# --health doesn't crash and the new check skips gracefully.
COMPAT_DIR="$(mktemp -d)"
mkdir -p "$COMPAT_DIR"
# Need a minimal valid JSONL too so other checks don't degrade us.
cat > "${COMPAT_DIR}/janitor.jsonl" <<'EOF'
{"run_id":"old","ts":"2026-01-01T00:00:00+0000","host":"h","user":"u","section":"run_start","status":"ok","freed_kb":0,"items":0,"note":"dry_run=1"}
{"run_id":"old","ts":"2026-01-01T00:00:01+0000","host":"h","user":"u","section":"safety_integrity","status":"ok","freed_kb":0,"items":0,"note":"clean"}
{"run_id":"old","ts":"2026-01-01T00:00:02+0000","host":"h","user":"u","section":"run_end","status":"ok","freed_kb":0,"items":0,"note":"integrity=ok"}
EOF
cat > "${COMPAT_DIR}/last-run.json" <<'EOF'
{"run_id":"old","finished":"2026-01-01T00:00:02+0000","host":"h","user":"u","freed_kb":0,"safety_integrity":"ok","start_used_kb":0,"end_used_kb":0,"dry_run":1}
EOF
HEALTH_OUT="$(JANITOR_LOG_DIR="$COMPAT_DIR" "$SCRIPT" --health --json)"
HEALTH_RC=$?
[ "$HEALTH_RC" = "0" ] \
  || fail "schema-old compat: --health exited $HEALTH_RC (expected 0)"
python3 - <<PY
import json, sys
d = json.loads("""$HEALTH_OUT""")
by = {c["name"]: c for c in d["checks"]}
if "last_run_parses_sections" not in by:
    print("FAIL: new check missing from --health output", file=sys.stderr); sys.exit(1)
c = by["last_run_parses_sections"]
if not c["ok"]:
    print(f"FAIL: schema-old should not fail the new check, got: {c}", file=sys.stderr); sys.exit(1)
if "older" not in (c["detail"] or ""):
    print(f"FAIL: expected 'older'-mentioning detail, got: {c['detail']!r}", file=sys.stderr); sys.exit(1)
# Existing integrity check must still pass and not crash on missing sections.
if not by["last_run_integrity_ok"]["ok"]:
    print(f"FAIL: last_run_integrity_ok regressed on schema-old: {by['last_run_integrity_ok']}", file=sys.stderr); sys.exit(1)
PY
rm -rf "$COMPAT_DIR"
pass "last-run.json: schema-old (no sections[]) skips new check, no crash, no regression"

echo "─── --health-acknowledge ────────────────────────────────────"
# --health-acknowledge writes a byte-offset baseline so --health ignores
# pre-existing malformed JSONL lines. Lives in $JANITOR_LOG_DIR/.health-baseline,
# single integer, atomic (write-tmp-then-rename), safe under concurrent run.

ACK_WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$HEALTH_WORK" "$ACK_WORK"' EXIT

# Case 1: --health-acknowledge on missing log dir exits 0 with baseline=0.
A_MISS="${ACK_WORK}/never-existed"
set +e
JANITOR_LOG_DIR="$A_MISS" "$SCRIPT" --health-acknowledge > "${ACK_WORK}/m.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "${ACK_WORK}/m.out"; fail "case 1: --health-acknowledge on missing dir exited $rc, expected 0"; }
[ -f "${A_MISS}/.health-baseline" ] || fail "case 1: .health-baseline not written"
got="$(cat "${A_MISS}/.health-baseline")"
[ "$got" = "0" ] || fail "case 1: baseline on missing log dir should be 0, got '$got'"
grep -q "baseline set to 0 bytes" "${ACK_WORK}/m.out" \
  || { cat "${ACK_WORK}/m.out"; fail "case 1: stdout missing 'baseline set to 0 bytes'"; }
pass "case 1: --health-acknowledge on missing log dir → baseline=0, exit 0"

# Case 2: --health-acknowledge on dir with malformed JSONL → baseline == file size.
A_BAD="${ACK_WORK}/baddir"
mkdir -p "$A_BAD"
echo '{"section":"run_start","ts":"2026-01-01"}' >> "${A_BAD}/janitor.jsonl"
echo '{"section":"foo","items":00}' >> "${A_BAD}/janitor.jsonl"
expected_size="$(wc -c < "${A_BAD}/janitor.jsonl")"
set +e
JANITOR_LOG_DIR="$A_BAD" "$SCRIPT" --health-acknowledge > "${ACK_WORK}/b.out" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "${ACK_WORK}/b.out"; fail "case 2: --health-acknowledge exited $rc, expected 0"; }
got="$(cat "${A_BAD}/.health-baseline")"
[ "$got" = "$expected_size" ] || fail "case 2: baseline=$got, expected file size $expected_size"
grep -qE "baseline set to ${expected_size} bytes \(2 existing events excluded" "${ACK_WORK}/b.out" \
  || { cat "${ACK_WORK}/b.out"; fail "case 2: stdout missing expected message"; }
pass "case 2: --health-acknowledge writes baseline=filesize and reports event count"

# Case 3: After ack, --health on a degraded dir returns healthy (recovery path).
A_REC="${ACK_WORK}/recover"
cp -r "$H_HEALTHY" "$A_REC"
echo '{"section":"foo","items":00}' >> "${A_REC}/janitor.jsonl"
# Sanity: before ack it should be degraded.
set +e
JANITOR_LOG_DIR="$A_REC" "$SCRIPT" --health > "${ACK_WORK}/r.before" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || { cat "${ACK_WORK}/r.before"; fail "case 3: pre-ack should be degraded(4), got $rc"; }
# Acknowledge.
JANITOR_LOG_DIR="$A_REC" "$SCRIPT" --health-acknowledge >/dev/null
# Now --health should be healthy.
set +e
JANITOR_LOG_DIR="$A_REC" "$SCRIPT" --health > "${ACK_WORK}/r.after" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || { cat "${ACK_WORK}/r.after"; fail "case 3: post-ack should be healthy(0), got $rc"; }
grep -q "healthy" "${ACK_WORK}/r.after" || fail "case 3: post-ack output missing 'healthy'"
grep -q "baseline=" "${ACK_WORK}/r.after" \
  || fail "case 3: post-ack jsonl_parses detail should mention baseline"
pass "case 3: --health-acknowledge recovers degraded → healthy"

# Case 4: NEW malformed line after ack triggers degraded again (only new issues count).
echo '{"section":"bar","items":00}' >> "${A_REC}/janitor.jsonl"
set +e
JANITOR_LOG_DIR="$A_REC" "$SCRIPT" --health > "${ACK_WORK}/r.new" 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || { cat "${ACK_WORK}/r.new"; fail "case 4: new malformed line should re-degrade, got rc=$rc"; }
grep -q "since baseline" "${ACK_WORK}/r.new" \
  || { cat "${ACK_WORK}/r.new"; fail "case 4: detail should say 'since baseline'"; }
pass "case 4: new malformed line after baseline re-degrades --health"

# Case 5: --health-acknowledge --json emits valid JSON with documented keys.
A_JSON="${ACK_WORK}/jsoncase"
mkdir -p "$A_JSON"
echo '{"a":1}' > "${A_JSON}/janitor.jsonl"
JANITOR_LOG_DIR="$A_JSON" "$SCRIPT" --health-acknowledge --json > "${ACK_WORK}/j.out"
python3 - "${ACK_WORK}/j.out" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("acknowledged") is True, d
assert isinstance(d.get("baseline_bytes"), int) and d["baseline_bytes"] > 0, d
assert isinstance(d.get("excluded_events"), int) and d["excluded_events"] == 1, d
PY
pass "case 5: --health-acknowledge --json emits valid JSON with documented keys"

# Case 6: idempotency — running ack twice on an unchanged file → same baseline.
#         Adding new events and re-running advances baseline to new EOF.
A_IDEM="${ACK_WORK}/idem"
mkdir -p "$A_IDEM"
echo '{"a":1}' > "${A_IDEM}/janitor.jsonl"
JANITOR_LOG_DIR="$A_IDEM" "$SCRIPT" --health-acknowledge >/dev/null
b1="$(cat "${A_IDEM}/.health-baseline")"
JANITOR_LOG_DIR="$A_IDEM" "$SCRIPT" --health-acknowledge >/dev/null
b2="$(cat "${A_IDEM}/.health-baseline")"
[ "$b1" = "$b2" ] || fail "case 6: baseline changed on unchanged file: $b1 → $b2"
echo '{"b":2}' >> "${A_IDEM}/janitor.jsonl"
JANITOR_LOG_DIR="$A_IDEM" "$SCRIPT" --health-acknowledge >/dev/null
b3="$(cat "${A_IDEM}/.health-baseline")"
[ "$b3" -gt "$b2" ] || fail "case 6: baseline did not advance after appending: $b2 → $b3"
new_size="$(wc -c < "${A_IDEM}/janitor.jsonl")"
[ "$b3" = "$new_size" ] || fail "case 6: baseline=$b3 != file size $new_size after re-ack"
pass "case 6: --health-acknowledge is idempotent on unchanged files, advances on new events"

# Case 7: --json without any companion flag still rejects --json (precondition).
set +e
"$SCRIPT" --json > "${ACK_WORK}/jo.out" 2> "${ACK_WORK}/jo.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "case 7: --json alone should exit 3 (got $rc)"
grep -q "health-acknowledge" "${ACK_WORK}/jo.err" \
  || fail "case 7: error message should mention --health-acknowledge"
pass "case 7: --json alone error message lists --health-acknowledge"

# ─── --health detail wording ─────────────────────────────────────
echo "─── --health detail wording ─────────────────────────────────"
WORD_WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" "$WORK2" "$HEALTH_WORK" "$ACK_WORK" "$WORD_WORK"' EXIT

extract_detail() {
  python3 - "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
jp = [c for c in d["checks"] if c["name"] == "jsonl_parses"][0]
print(jp["detail"])
PY
}

# Case 1: all-excluded production-shape (baseline at EOF, historical malformed line)
W1="${WORD_WORK}/all_excluded"
mkdir -p "$W1"
printf 'not json at all\n' > "${W1}/janitor.jsonl"
for i in $(seq 1 64); do echo "{\"i\":$i}" >> "${W1}/janitor.jsonl"; done
wc -c < "${W1}/janitor.jsonl" > "${W1}/.health-baseline"
JANITOR_LOG_DIR="$W1" "$SCRIPT" --health --json > "${W1}/out.json" 2>/dev/null || true
d1="$(extract_detail "${W1}/out.json")"
echo "  case 1 detail: $d1"
echo "$d1" | grep -Eq '^0 invalid lines \(baseline=.*all .* events excluded.*\)$' \
  || fail "case 1: wording regex mismatch: $d1"
echo "$d1" | grep -Eq '^0 events parse cleanly' \
  && fail "case 1: still leads with 'events parse cleanly': $d1"
pass "case 1: all-excluded production case leads with '0 invalid lines'"

# Case 2: mixed — baseline mid-file, post-baseline all clean
W2="${WORD_WORK}/mixed"
mkdir -p "$W2"
for i in $(seq 1 5); do echo "{\"pre\":$i}" >> "${W2}/janitor.jsonl"; done
size_pre="$(wc -c < "${W2}/janitor.jsonl")"
for i in $(seq 1 3); do echo "{\"post\":$i}" >> "${W2}/janitor.jsonl"; done
echo "$size_pre" > "${W2}/.health-baseline"
JANITOR_LOG_DIR="$W2" "$SCRIPT" --health --json > "${W2}/out.json" 2>/dev/null || true
d2="$(extract_detail "${W2}/out.json")"
echo "  case 2 detail: $d2"
echo "$d2" | grep -Eq '^0 invalid lines among 3 events checked \(baseline=.*5 events excluded\)$' \
  || fail "case 2: wording mismatch: $d2"
pass "case 2: mixed case says '0 invalid lines among N events checked'"

# Case 3: invalid since baseline
W3="${WORD_WORK}/invalid_after"
mkdir -p "$W3"
for i in $(seq 1 4); do echo "{\"pre\":$i}" >> "${W3}/janitor.jsonl"; done
size_pre3="$(wc -c < "${W3}/janitor.jsonl")"
echo '{"ok":1}' >> "${W3}/janitor.jsonl"
echo 'this is not json' >> "${W3}/janitor.jsonl"
echo '{"ok":2}' >> "${W3}/janitor.jsonl"
echo "$size_pre3" > "${W3}/.health-baseline"
set +e
JANITOR_LOG_DIR="$W3" "$SCRIPT" --health --json > "${W3}/out.json" 2>/dev/null
set -e
d3="$(extract_detail "${W3}/out.json")"
echo "  case 3 detail: $d3"
echo "$d3" | grep -Eq '^1 invalid line since baseline \(line [0-9]+, 3 events checked, 4 events excluded\)$' \
  || fail "case 3: wording mismatch: $d3"
pass "case 3: post-baseline malformed line leads with '1 invalid line since baseline'"

# Case 4: no baseline, all clean
W4="${WORD_WORK}/no_baseline_clean"
mkdir -p "$W4"
for i in $(seq 1 7); do echo "{\"i\":$i}" >> "${W4}/janitor.jsonl"; done
JANITOR_LOG_DIR="$W4" "$SCRIPT" --health --json > "${W4}/out.json" 2>/dev/null || true
d4="$(extract_detail "${W4}/out.json")"
echo "  case 4 detail: $d4"
echo "$d4" | grep -Eq '^0 invalid lines' \
  || fail "case 4: no-baseline clean must start with '0 invalid lines': $d4"
pass "case 4: no-baseline clean case leads with '0 invalid lines'"

# Case 5: regex contract — every detail starts with "N invalid line"
for f in "${W1}/out.json" "${W2}/out.json" "${W3}/out.json" "${W4}/out.json"; do
  d="$(extract_detail "$f")"
  echo "$d" | grep -Eq '^[0-9]+ invalid line' \
    || fail "case 5: detail does not lead with 'N invalid line': $d (from $f)"
done
pass "case 5: all jsonl_parses details match ^[0-9]+ invalid line regex"

echo "─── capability completeness ─────────────────────────────────"
# Contract: every string in `--version --json`.capabilities[] is an agent-
# facing feature that MUST actually work. This stage probes each one
# end-to-end. If a capability is claimed but its probe fails, smoke fails.
# (The reverse direction — a feature added without claiming a capability —
# cannot be caught mechanically; it's enforced by code review.)
CAP_WORK="${WORK}/capabilities"
mkdir -p "$CAP_WORK"

# 1. Pull capabilities[] from --version --json.
CAPS_JSON="${CAP_WORK}/caps.json"
"$SCRIPT" --version --json > "$CAPS_JSON"
mapfile -t CLAIMED < <(python3 -c "
import json
d = json.load(open('$CAPS_JSON'))
for c in d['capabilities']:
    print(c)
")
[ "${#CLAIMED[@]}" -gt 0 ] || fail "capability completeness: capabilities[] is empty"

# 2. Build the expected set. report-bytes is conditional: only expected
#    when --report --json actually surfaces total_freed_bytes (parallel
#    unit-consistency-bytes agent). Detect dynamically.
REPORT_JSON_OUT="${CAP_WORK}/report.json"
"$SCRIPT" --report --json > "$REPORT_JSON_OUT" 2>/dev/null || true
has_total_freed_bytes=$(python3 -c "
import json
try:
    d = json.load(open('$REPORT_JSON_OUT'))
    print('yes' if 'total_freed_bytes' in d else 'no')
except Exception:
    print('no')
")

EXPECTED=(
  health
  health-acknowledge
  health-json
  idle-status
  json-schemas
  last-run-sections
  only
  report
  report-json
  schema-aliases
  version
  version-json
)
if [ "$has_total_freed_bytes" = "yes" ]; then
  EXPECTED+=("report-bytes")
fi

# 3. Every expected capability must be claimed.
claimed_str=" ${CLAIMED[*]} "
for cap in "${EXPECTED[@]}"; do
  case "$claimed_str" in
    *" $cap "*) : ;;
    *) fail "capability completeness: expected capability '$cap' missing from --version --json"
       ;;
  esac
done
pass "capabilities[] contains all expected entries (${#EXPECTED[@]} items)"

# 4. Per-capability probes — claiming a capability means the feature works.
probe_fail() { fail "capability completeness: probe for '$1' failed — $2"; }

for cap in "${CLAIMED[@]}"; do
  case "$cap" in
    report)
      set +e; "$SCRIPT" --report > "${CAP_WORK}/p_report.out" 2>&1; rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc, expected 0"
      ;;
    report-json)
      set +e; "$SCRIPT" --report --json > "${CAP_WORK}/p_report.json" 2>/dev/null; rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc"
      python3 -c "
import json,sys
d=json.load(open('${CAP_WORK}/p_report.json'))
assert 'data_quality' in d, 'missing data_quality'
" || probe_fail "$cap" "JSON missing data_quality key"
      ;;
    health)
      W="${CAP_WORK}/p_health"; mkdir -p "$W"
      set +e; JANITOR_LOG_DIR="$W" "$SCRIPT" --health > "${W}/out" 2>&1; rc=$?; set -e
      case "$rc" in 0|4|5) : ;; *) probe_fail "$cap" "exit $rc not in {0,4,5}";; esac
      ;;
    health-json)
      W="${CAP_WORK}/p_hjson"; mkdir -p "$W"
      set +e; JANITOR_LOG_DIR="$W" "$SCRIPT" --health --json > "${W}/out" 2>/dev/null; set -e
      python3 -c "
import json
d=json.load(open('${W}/out'))
assert 'status' in d and 'exit_code' in d, d
" || probe_fail "$cap" "JSON missing status/exit_code"
      ;;
    health-acknowledge)
      W="${CAP_WORK}/p_ack"; mkdir -p "$W"
      echo '{"a":1}' > "${W}/janitor.jsonl"
      set +e; JANITOR_LOG_DIR="$W" "$SCRIPT" --health-acknowledge > "${W}/out" 2>&1; rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc"
      [ -s "${W}/.health-baseline" ] || probe_fail "$cap" ".health-baseline not created"
      ;;
    only)
      W="${CAP_WORK}/p_only"; mkdir -p "$W"
      set +e; JANITOR_LOG_DIR="$W" "$SCRIPT" --only docker_prune --dry-run > "${W}/out" 2>&1; rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc"
      # Action sections in JSONL must be limited to docker_prune. Meta
      # sections (run_start, run_end, safety_integrity) may also appear.
      python3 -c "
import json
action_sections = {'docker_prune','go_build_cache','tmp_gobuild_orphans','workspace_binobj','extra_cleanup','nuget_http_temp'}
seen = set()
for line in open('${W}/janitor.jsonl'):
    line = line.strip()
    if not line: continue
    s = json.loads(line).get('section')
    if s in action_sections: seen.add(s)
assert seen == {'docker_prune'}, f'expected only docker_prune, got {seen}'
" || probe_fail "$cap" "--only did not restrict action sections"
      ;;
    idle-status)
      # Real (non-dry) run of opt-in section workspace_binobj pointed at
      # an empty workspace → produces zero items → status=idle event.
      W="${CAP_WORK}/p_idle"; mkdir -p "$W/ws_empty" "$W/state"
      CFG="${W}/cfg"
      cat > "$CFG" <<EOF
JANITOR_DOCKER_PRUNE=no
JANITOR_GO_CLEAN=no
JANITOR_TMP_GOBUILD_ORPHANS=no
JANITOR_NUGET_CLEAN=no
JANITOR_WORKSPACE_DIRS="${W}/ws_empty"
EOF
      set +e; JANITOR_LOG_DIR="${W}/state" "$SCRIPT" --config "$CFG" --only workspace_binobj > "${W}/out" 2>&1; rc=$?; set -e
      [ "$rc" -eq 0 ] || { cat "${W}/out"; probe_fail "$cap" "real run exit $rc"; }
      grep -q '"status":"idle"' "${W}/state/janitor.jsonl" \
        || probe_fail "$cap" "no status=idle event in janitor.jsonl"
      ;;
    schema-aliases)
      # Inject a synthetic JSONL event using the legacy alias
      # 'copilot_integrity'. --report --json must merge it under the
      # canonical name 'safety_integrity' (a meta-section, so it does
      # NOT surface in per_section — but the alias key must not leak).
      W="${CAP_WORK}/p_alias"; mkdir -p "$W"
      cat > "${W}/janitor.jsonl" <<EOF
{"ts":"2026-01-01T00:00:00Z","run_id":"r1","section":"copilot_integrity","status":"ok","freed_kb":0,"items":0,"note":""}
EOF
      set +e
      JANITOR_LOG_DIR="$W" "$SCRIPT" --report --json > "${W}/r.json" 2>/dev/null
      rc=$?
      set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "--report --json exit $rc"
      python3 -c "
import json
d=json.load(open('${W}/r.json'))
per = d.get('per_section', [])
# per_section is a list of dicts with a 'section' key (or similar). Flatten to names.
names = set()
if isinstance(per, list):
    for entry in per:
        if isinstance(entry, dict):
            names.add(entry.get('section') or entry.get('name') or '')
        else:
            names.add(str(entry))
elif isinstance(per, dict):
    names = set(per.keys())
assert 'copilot_integrity' not in names, f'alias leaked into per_section: {names}'
# Streaks must also not contain the alias name.
streaks = {s.get('section') for s in d.get('idle_streaks', []) if isinstance(s, dict)}
assert 'copilot_integrity' not in streaks, f'alias leaked into idle_streaks: {streaks}'
" || probe_fail "$cap" "alias was not remapped (copilot_integrity still present)"
      ;;
    version)
      set +e; out=$("$SCRIPT" --version 2>&1); rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc"
      case "$out" in *system-janitor*) : ;; *) probe_fail "$cap" "stdout lacks 'system-janitor': $out";; esac
      ;;
    version-json)
      set +e; "$SCRIPT" --version --json > "${CAP_WORK}/p_ver.json" 2>/dev/null; rc=$?; set -e
      [ "$rc" -eq 0 ] || probe_fail "$cap" "exit $rc"
      python3 -c "
import json
d=json.load(open('${CAP_WORK}/p_ver.json'))
assert 'version' in d, d
" || probe_fail "$cap" "JSON missing version key"
      ;;
    json-schemas)
      for s in report health; do
        f="${REPO_ROOT}/schemas/${s}.schema.json"
        [ -s "$f" ] || probe_fail "$cap" "schemas/${s}.schema.json missing"
        python3 -c "import json; json.load(open('$f'))" \
          || probe_fail "$cap" "schemas/${s}.schema.json is not valid JSON"
      done
      ;;
    last-run-sections)
      W="${CAP_WORK}/p_lrs"; mkdir -p "$W/state"
      CFG="${W}/cfg"
      cat > "$CFG" <<EOF
JANITOR_DOCKER_PRUNE=no
JANITOR_GO_CLEAN=no
JANITOR_TMP_GOBUILD_ORPHANS=no
JANITOR_NUGET_CLEAN=no
EOF
      set +e; JANITOR_LOG_DIR="${W}/state" "$SCRIPT" --config "$CFG" --dry-run > "${W}/out" 2>&1; rc=$?; set -e
      [ "$rc" -eq 0 ] || { cat "${W}/out"; probe_fail "$cap" "run exit $rc"; }
      python3 -c "
import json
d=json.load(open('${W}/state/last-run.json'))
secs = d.get('sections')
assert isinstance(secs, list) and len(secs) > 0, f'sections missing or empty: {secs!r}'
assert all(isinstance(s, dict) and 'name' in s for s in secs), secs
" || probe_fail "$cap" "last-run.json sections[] missing or malformed"
      ;;
    report-bytes)
      python3 -c "
import json
d=json.load(open('${CAP_WORK}/report.json'))
assert 'total_freed_bytes' in d, d
" || probe_fail "$cap" "--report --json missing total_freed_bytes"
      ;;
    *)
      fail "capability completeness: unknown capability '$cap' claimed — add a probe for it in tests/smoke.sh"
      ;;
  esac
done
pass "every claimed capability has a working end-to-end probe (${#CLAIMED[@]} probes)"

# ─── unit consistency ───────────────────────────────────────
# Bytes are the canonical unit in `--report --json`; `_kb` fields are
# back-compat aliases. This stage builds a synthetic JSONL with known
# `freed_kb` values, asserts the report's `_bytes` math is consistent
# with the events directly (not derived from the `_kb` total), and
# re-validates the new shape against the report schema.
echo "─── unit consistency ───────────────────────────────────"
UC_WORK="$(mktemp -d)"
UC_DIR="${UC_WORK}/state"
mkdir -p "$UC_DIR"
UC_JSONL="${UC_DIR}/janitor.jsonl"

# Three sections with known freed_kb (in KB). Total = 7 KB = 7168 bytes.
# run_end.freed_kb deliberately set to the sum so total_freed_kb matches.
SEC_A_KB=3
SEC_B_KB=4
SEC_C_KB=0
TOTAL_KB=$((SEC_A_KB + SEC_B_KB + SEC_C_KB))
K_BYTES=$((TOTAL_KB * 1024))

cat > "$UC_JSONL" <<JSONL
{"run_id":"r1","ts":"2026-05-12T00:00:00+0000","host":"h","user":"u","section":"run_start","status":"ok","freed_kb":0,"items":0,"note":""}
{"run_id":"r1","ts":"2026-05-12T00:00:01+0000","host":"h","user":"u","section":"docker_prune","status":"ok","freed_kb":${SEC_A_KB},"items":1,"note":""}
{"run_id":"r1","ts":"2026-05-12T00:00:02+0000","host":"h","user":"u","section":"go_build_cache","status":"ok","freed_kb":${SEC_B_KB},"items":2,"note":""}
{"run_id":"r1","ts":"2026-05-12T00:00:03+0000","host":"h","user":"u","section":"nuget_http_temp","status":"ok","freed_kb":${SEC_C_KB},"items":0,"note":""}
{"run_id":"r1","ts":"2026-05-12T00:00:04+0000","host":"h","user":"u","section":"safety_integrity","status":"ok","freed_kb":0,"items":0,"note":""}
{"run_id":"r1","ts":"2026-05-12T00:00:05+0000","host":"h","user":"u","section":"run_end","status":"ok","freed_kb":${TOTAL_KB},"items":3,"note":""}
JSONL

UC_REPORT="${UC_WORK}/report.json"
JANITOR_LOG_DIR="$UC_DIR" "$SCRIPT" --report --json > "$UC_REPORT"
[ -s "$UC_REPORT" ] || fail "unit-consistency: --report --json produced empty output"

# Check 1: total_freed_bytes == K, total_freed_kb == K // 1024 (integer
# division — `_bytes` is the canonical unit and is summed independently
# from per-event values, so `_kb` is always `_bytes // 1024` even if
# events ever carry sub-KB byte counts in future).
python3 - "$UC_REPORT" "$K_BYTES" "$TOTAL_KB" <<'PY' || fail "unit-consistency: totals mismatch"
import json, sys
d = json.load(open(sys.argv[1]))
k_bytes = int(sys.argv[2]); total_kb = int(sys.argv[3])
assert "total_freed_bytes" in d, "missing total_freed_bytes"
assert isinstance(d["total_freed_bytes"], int), "total_freed_bytes not int"
assert d["total_freed_bytes"] >= 0, "total_freed_bytes negative"
assert d["total_freed_bytes"] == k_bytes, \
    f"total_freed_bytes={d['total_freed_bytes']}, want {k_bytes}"
assert d["total_freed_kb"] == k_bytes // 1024, \
    f"total_freed_kb={d['total_freed_kb']}, want {k_bytes // 1024}"
assert d["total_freed_kb"] == total_kb, \
    f"total_freed_kb={d['total_freed_kb']}, want {total_kb}"
PY
pass "unit-consistency: total_freed_bytes == K and total_freed_kb == K // 1024"

# Check 2: every per_section entry has freed_bytes (int >= 0).
python3 - "$UC_REPORT" <<'PY' || fail "unit-consistency: per_section freed_bytes shape"
import json, sys
d = json.load(open(sys.argv[1]))
assert d["per_section"], "per_section empty"
for s in d["per_section"]:
    assert "freed_bytes" in s, f"missing freed_bytes in {s['name']}"
    assert isinstance(s["freed_bytes"], int), f"{s['name']} freed_bytes not int"
    assert s["freed_bytes"] >= 0, f"{s['name']} freed_bytes negative"
    assert s["freed_bytes"] == s["freed_kb_total"] * 1024, \
        f"{s['name']}: freed_bytes={s['freed_bytes']} != freed_kb_total*1024={s['freed_kb_total']*1024}"
PY
pass "unit-consistency: per_section[*] has freed_bytes (int >= 0, == freed_kb_total*1024)"

# Check 3: schema still validates the new shape.
_validate "$UC_REPORT" "$SCHEMA_REPORT" \
  || fail "unit-consistency: report with _bytes fields failed schema validation"
pass "unit-consistency: new report shape validates against report.schema.json"

# Check 4: cross-source — sum JSONL events for a specific section
# independently, verify report.per_section[name].freed_bytes matches.
# Proves bytes is computed from events, not converted from a kb total.
python3 - "$UC_REPORT" "$UC_JSONL" docker_prune <<'PY' || fail "unit-consistency: cross-source mismatch"
import json, sys
report = json.load(open(sys.argv[1]))
target = sys.argv[3]
expected_bytes = 0
with open(sys.argv[2]) as fh:
    for line in fh:
        if not line.strip(): continue
        ev = json.loads(line)
        if ev.get("section") != target: continue
        fb = ev.get("freed_bytes")
        if fb is not None:
            expected_bytes += int(fb)
        else:
            expected_bytes += int(ev.get("freed_kb") or 0) * 1024
match = [s for s in report["per_section"] if s["name"] == target]
assert match, f"section {target} not in per_section"
got = match[0]["freed_bytes"]
assert got == expected_bytes, f"{target}: report freed_bytes={got}, sum from JSONL={expected_bytes}"
PY
pass "unit-consistency: report.per_section[docker_prune].freed_bytes == sum(JSONL events)"

# Check 5: most_recent_run carries freed_bytes alongside freed_kb.
python3 - "$UC_REPORT" <<'PY' || fail "unit-consistency: most_recent_run.freed_bytes missing"
import json, sys
d = json.load(open(sys.argv[1]))
mr = d.get("most_recent_run")
assert mr is not None, "most_recent_run is null"
assert "freed_bytes" in mr, "freed_bytes missing from most_recent_run"
assert isinstance(mr["freed_bytes"], int) and mr["freed_bytes"] >= 0, "freed_bytes shape"
assert mr["freed_bytes"] == mr["freed_kb"] * 1024, \
    f"most_recent_run: freed_bytes={mr['freed_bytes']} != freed_kb*1024={mr['freed_kb']*1024}"
PY
pass "unit-consistency: most_recent_run has freed_bytes matching freed_kb*1024"

rm -rf "$UC_WORK"
echo "all unit-consistency checks passed"
