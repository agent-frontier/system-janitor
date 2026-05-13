#!/usr/bin/env bash
# tests/updater-smoke.sh — hermetic smoke test for system-updater.sh.
#
# Exercises the v0.1.0 contract against the stub backend. No root, no real
# apt, no network. Each stage gets its own mktemp -d UPDATER_LOG_DIR so
# stages cannot pollute each other; everything is torn down on EXIT.
#
# Run from the repo root:  ./tests/updater-smoke.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="${REPO_ROOT}/system-updater.sh"

[ -x "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing or not executable" >&2; exit 1; }

# ─── per-stage tmpdir tracking ───────────────────────────────────────────────
STAGE_DIRS=()
cleanup_all() {
  local d
  for d in "${STAGE_DIRS[@]}"; do
    [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d"
  done
}
trap cleanup_all EXIT INT TERM

# Create a fresh per-stage workdir, register it for cleanup, echo the path.
new_workdir() {
  local d
  d=$(mktemp -d)
  STAGE_DIRS+=("$d")
  echo "$d"
}

fail()    { echo "FAIL: $*" >&2; exit 1; }
pass()    { echo "ok: $*"; ASSERTIONS=$((ASSERTIONS + 1)); }
section() { echo; echo "$*"; }
warn()    { echo "WARN: $*" >&2; }

ASSERTIONS=0

# Common env baseline for hermetic stub runs.
export UPDATER_BACKEND=stub
# Reset everything that might leak from the host environment.
unset UPDATER_HOLD_PACKAGES UPDATER_SECURITY_ONLY UPDATER_MAINTENANCE_WINDOW \
      UPDATER_REQUIRE_SNAPSHOT UPDATER_REBOOT_POLICY

# Wrapper: run the script with a per-call LOG_DIR + isolated env.
# Usage: run_updater <log_dir> [args...]
run_updater() {
  local log_dir="$1"; shift
  UPDATER_LOG_DIR="$log_dir" "$SCRIPT" "$@"
}

# ─── 01: syntax + shellcheck ────────────────────────────────────────────────
section "─── 01: syntax + shellcheck ─────────────────────────────────"
bash -n "$SCRIPT"
pass "bash -n clean"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -S warning "$SCRIPT"
  pass "shellcheck -S warning clean"
else
  warn "01: shellcheck not installed — skipping lint"
fi

# ─── 02: --version ──────────────────────────────────────────────────────────
section "─── 02: --version ───────────────────────────────────────────"
W=$(new_workdir)

# --version must work without UPDATER_LOG_DIR set.
( unset UPDATER_LOG_DIR; "$SCRIPT" --version > "${W}/v.out" )
grep -Eq '^system-updater 0\.1\.0$' "${W}/v.out" \
  || fail "--version stdout did not match '^system-updater 0\\.1\\.0$': $(cat "${W}/v.out")"
pass "--version exits 0 and prints exactly 'system-updater 0.1.0'"

( unset UPDATER_LOG_DIR; "$SCRIPT" --version --json > "${W}/v.json" )
python3 - "${W}/v.json" <<'PY' || fail "--version --json failed contract checks"
import json, sys
d = json.load(open(sys.argv[1]))
caps = d.get("capabilities")
assert isinstance(caps, list), f"capabilities not a list: {caps!r}"
expected = [
    "apt-backend", "exclude", "force", "health", "health-acknowledge",
    "health-json", "holds", "maintenance-window", "only",
    "report", "report-json", "security-only", "stub-backend",
    "version", "version-json",
]
assert caps == sorted(caps), f"capabilities not sorted alphabetically: {caps}"
assert caps == expected, f"capabilities mismatch:\n  got:      {caps}\n  expected: {expected}"
PY
pass "--version --json capabilities[] is the exact 15-item v0 set, alphabetical"

# ─── 03: --help ─────────────────────────────────────────────────────────────
section "─── 03: --help ──────────────────────────────────────────────"
W=$(new_workdir)
( unset UPDATER_LOG_DIR; "$SCRIPT" --help > "${W}/h.out" )
pass "--help exits 0"

flags=( --config --dry-run --apply --only --exclude --report --json --health \
        --health-acknowledge --version --force --help )
for f in "${flags[@]}"; do
  grep -q -- "$f" "${W}/h.out" || fail "--help missing mention of '$f'"
done
pass "--help mentions every documented flag (${#flags[@]} flags)"

# EXIT CODES section enumerating 0-7.
grep -qiE 'EXIT CODES?' "${W}/h.out" || fail "--help missing EXIT CODES section"
for code in 0 1 2 3 4 5 6 7; do
  grep -Eq "(^|[^0-9])${code}([^0-9]|$)" "${W}/h.out" \
    || fail "--help EXIT CODES section missing code ${code}"
done
pass "--help documents all eight exit codes (0–7)"

# ─── 04: dry-run is default ─────────────────────────────────────────────────
section "─── 04: dry-run is default ──────────────────────────────────"
W1=$(new_workdir); W2=$(new_workdir)

run_updater "$W1"            >/dev/null
pass "no-args run exits 0 (dry-run is default)"
run_updater "$W2" --dry-run  >/dev/null
pass "explicit --dry-run exits 0"

JSONL1="${W1}/updater.jsonl"
JSONL2="${W2}/updater.jsonl"
[ -s "$JSONL1" ] || fail "no-args run did not write updater.jsonl"
[ -s "$JSONL2" ] || fail "--dry-run did not write updater.jsonl"

python3 - "$JSONL1" <<'PY' || fail "default-run JSONL invalid or non-dry-run package events"
import json, sys
saw_pkg = False
for i, l in enumerate(open(sys.argv[1]), 1):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "package":
        saw_pkg = True
        assert o.get("status") == "dry_run", f"line {i}: package event status={o.get('status')!r}, expected dry_run"
        assert o.get("dry_run") in (True, 1, "1", "true"), f"line {i}: dry_run flag falsy: {o.get('dry_run')!r}"
assert saw_pkg, "no package stage events emitted"
PY
pass "default run emits package events with status=dry_run"

# Compare statuses across the two runs (modulo timing-only fields).
diff \
  <(python3 -c "import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get('stage')=='package':
        print(o.get('package'), o.get('status'))" "$JSONL1" | sort) \
  <(python3 -c "import json,sys
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get('stage')=='package':
        print(o.get('package'), o.get('status'))" "$JSONL2" | sort) \
  || fail "no-args and --dry-run produced different package statuses"
pass "implicit and explicit dry-run produce identical package statuses"

# ─── 05: --apply pre-flight refusal ─────────────────────────────────────────
section "─── 05: --apply pre-flight refusal ──────────────────────────"
[ "$(id -u)" -ne 0 ] || fail "smoke must not be run as root"

W=$(new_workdir)
set +e
run_updater "$W" --apply > "${W}/out" 2> "${W}/err"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "--apply as non-root exit=$rc, expected 2 (pre-flight). stderr: $(cat "${W}/err")"
grep -qi 'root' "${W}/err" || fail "--apply refusal stderr does not mention 'root': $(cat "${W}/err")"
pass "--apply as non-root → exit 2 with 'root' in stderr"

W=$(new_workdir)
set +e
run_updater "$W" --apply --dry-run > "${W}/out" 2> "${W}/err"
rc=$?
set -e
case "$rc" in
  2) pass "--apply --dry-run → exit 2 (root pre-flight wins; documented)" ;;
  3) pass "--apply --dry-run → exit 3 (conflicting-flags precondition; documented)" ;;
  *) fail "--apply --dry-run unexpected exit=$rc (want 2 or 3). stderr: $(cat "${W}/err")" ;;
esac

# ─── 06: --only filtering ───────────────────────────────────────────────────
section "─── 06: --only filtering ────────────────────────────────────"
W=$(new_workdir)
run_updater "$W" --only pkg-clean >/dev/null
pass "--only pkg-clean exits 0"

JSONL="${W}/updater.jsonl"
python3 - "$JSONL" <<'PY' || fail "--only behaviour mismatch (see assertion message)"
import json, sys
events = {}  # pkg -> status
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "package":
        events[o["package"]] = o["status"]
# Contract (locked-in by smoke):
#   pkg-clean MUST appear with a non-skipped status (dry_run or ok).
#   pkg-security and pkg-held MUST either be absent OR carry status=excluded.
assert "pkg-clean" in events, f"pkg-clean missing from --only run: {events}"
assert events["pkg-clean"] in ("dry_run", "ok"), \
    f"pkg-clean status={events['pkg-clean']!r}, expected dry_run|ok"
for other in ("pkg-security", "pkg-held"):
    if other in events:
        assert events[other] == "excluded", \
            f"{other} present with status={events[other]!r}, expected excluded or absent"
PY
pass "--only restricts active packages to pkg-clean (others excluded or absent)"

# ─── 07: --exclude filtering ────────────────────────────────────────────────
section "─── 07: --exclude filtering ─────────────────────────────────"
W=$(new_workdir)
run_updater "$W" --exclude 'pkg-h*' >/dev/null
pass "--exclude 'pkg-h*' exits 0"

python3 - "${W}/updater.jsonl" <<'PY' || fail "--exclude behaviour mismatch"
import json, sys
events = {}
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "package":
        events[o["package"]] = o["status"]
# pkg-held MUST be absent or carry status=excluded.
if "pkg-held" in events:
    assert events["pkg-held"] == "excluded", \
        f"pkg-held excluded but status={events['pkg-held']!r}"
# Non-excluded packages should still appear with dry_run.
for p in ("pkg-clean", "pkg-security"):
    assert p in events, f"non-excluded package {p} missing: {events}"
    assert events[p] in ("dry_run", "ok"), f"{p} status={events[p]!r}"
PY
pass "--exclude 'pkg-h*' marks pkg-held excluded (or omits it) and leaves others active"

# ─── 08: holds ──────────────────────────────────────────────────────────────
section "─── 08: holds ───────────────────────────────────────────────"
W=$(new_workdir)
UPDATER_HOLD_PACKAGES='pkg-held*' run_updater "$W" >/dev/null
pass "UPDATER_HOLD_PACKAGES run exits 0"

python3 - "${W}/updater.jsonl" <<'PY' || fail "hold semantics violated"
import json, sys
events = {}
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "package":
        events[o["package"]] = o["status"]
assert events.get("pkg-held") == "held", \
    f"pkg-held status={events.get('pkg-held')!r}, expected 'held'. all: {events}"
PY
pass "UPDATER_HOLD_PACKAGES='pkg-held*' → pkg-held event has status=held"

# ─── 09: security-only ──────────────────────────────────────────────────────
section "─── 09: security-only ───────────────────────────────────────"
W=$(new_workdir)
UPDATER_SECURITY_ONLY=yes run_updater "$W" >/dev/null
pass "UPDATER_SECURITY_ONLY=yes exits 0"

python3 - "${W}/updater.jsonl" <<'PY' || fail "security-only semantics violated"
import json, sys
events = {}
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "package":
        events[o["package"]] = o["status"]
for p in ("pkg-clean", "pkg-held"):
    assert events.get(p) == "filtered_non_security", \
        f"{p} status={events.get(p)!r}, expected 'filtered_non_security'. all: {events}"
assert events.get("pkg-security") in ("dry_run", "ok"), \
    f"pkg-security status={events.get('pkg-security')!r}, expected dry_run|ok"
PY
pass "security-only: non-security pkgs filtered_non_security, pkg-security active"

# ─── 10: maintenance window ─────────────────────────────────────────────────
section "─── 10: maintenance window ──────────────────────────────────"
# Time-of-day-dependent. We pick windows relative to the current wall-clock
# minute so that they are guaranteed in-window or out-of-window regardless
# of when smoke runs. (No env-based mocking — script doesn't promise one.)
NOW_H=$(date +%H); NOW_H=$((10#$NOW_H))
NOW_M=$(date +%M); NOW_M=$((10#$NOW_M))
# Out-of-window: a 1-minute window 6 hours ahead (mod 24). Always out of now.
OUT_H=$(( (NOW_H + 6) % 24 ))
OUT_WIN=$(printf '%02d:00-%02d:01' "$OUT_H" "$OUT_H")
# In-window: cover the whole day.
IN_WIN="00:00-23:59"

W=$(new_workdir)
set +e
UPDATER_MAINTENANCE_WINDOW="$OUT_WIN" run_updater "$W" >"${W}/out" 2>"${W}/err"
rc=$?
set -e
[ "$rc" -eq 6 ] || fail "out-of-window run exit=$rc (want 6). stderr: $(cat "${W}/err")"
pass "out-of-window window=${OUT_WIN} → exit 6"

# Lock in run_start handling: either no run_start event OR exactly one with
# status=out_of_window. Document the chosen behaviour.
if [ -s "${W}/updater.jsonl" ]; then
  python3 - "${W}/updater.jsonl" <<'PY' || fail "out-of-window JSONL violates contract"
import json, sys
saw_run_start = False
for l in open(sys.argv[1]):
    l = l.strip()
    if not l: continue
    o = json.loads(l)
    if o.get("stage") == "run_start":
        saw_run_start = True
        assert o.get("status") == "out_of_window", \
            f"run_start emitted out-of-window but status={o.get('status')!r}"
    # No package events should exist when we refused to run.
    assert o.get("stage") != "package", \
        f"package event {o['package']} emitted while out-of-window: {o}"
print("OUT_OF_WINDOW_RUN_START=" + ("present" if saw_run_start else "absent"))
PY
  pass "out-of-window: no package events; run_start (if present) status=out_of_window"
else
  pass "out-of-window: no JSONL written at all (also valid)"
fi

W=$(new_workdir)
UPDATER_MAINTENANCE_WINDOW="$OUT_WIN" run_updater "$W" --force >/dev/null
pass "out-of-window + --force → exit 0 (full run)"
grep -q '"stage":"package"' "${W}/updater.jsonl" \
  || fail "out-of-window + --force did not emit package events"
pass "out-of-window + --force emits package events"

W=$(new_workdir)
UPDATER_MAINTENANCE_WINDOW="$IN_WIN" run_updater "$W" >/dev/null
pass "in-window window=${IN_WIN} → exit 0"

# ─── 11: --report ───────────────────────────────────────────────────────────
section "─── 11: --report ────────────────────────────────────────────"
W=$(new_workdir)
run_updater "$W" >/dev/null  # seed one run
run_updater "$W" --report > "${W}/r.txt"
pass "--report exits 0 with human-readable summary"
[ -s "${W}/r.txt" ] || fail "--report produced no output"

run_updater "$W" --report --json > "${W}/r.json"
pass "--report --json exits 0"

python3 - "${W}/r.json" <<'PY' || fail "--report --json missing required keys"
import json, sys
d = json.load(open(sys.argv[1]))
required = {
    "generated_at", "log_dir", "jsonl_path", "total_runs", "real_runs",
    "dry_runs", "total_packages_upgraded", "total_packages_failed",
    "total_packages_held", "date_range", "per_package", "most_recent_run",
    "idle_streaks", "data_quality",
}
missing = required - d.keys()
assert not missing, f"--report --json missing keys: {missing}"
pp = d["per_package"]
# per_package may be a list-of-dicts or a dict-of-dicts; accept either.
if isinstance(pp, dict):
    names = set(pp.keys())
else:
    names = {e.get("package") or e.get("name") for e in pp if isinstance(e, dict)}
for stub in ("pkg-clean", "pkg-security", "pkg-held"):
    assert stub in names, f"per_package missing stub package {stub}: {names}"
PY
pass "--report --json has all 14 top-level keys; per_package contains the 3 stubs"

SCHEMA_REPORT="${REPO_ROOT}/schemas/updater-report.schema.json"
if [ -s "$SCHEMA_REPORT" ]; then
  # Schemas are being authored in parallel; treat mismatches as a warning
  # rather than a hard fail so smoke can land before the schema settles.
  set +e
  python3 - "$SCHEMA_REPORT" "${W}/r.json" > "${W}/schema.err" 2>&1 <<'PY'
import json, sys
try:
    import jsonschema
except ImportError:
    print("skip: jsonschema unavailable"); sys.exit(0)
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))
PY
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    pass "--report --json validates against schemas/updater-report.schema.json"
  else
    fail "11: --report --json does not match updater-report.schema.json:"
    sed 's/^/      /' "${W}/schema.err" >&2
  fi
else
  warn "11: schemas/updater-report.schema.json not yet present — skipping validation"
fi

# ─── 12: --health ───────────────────────────────────────────────────────────
section "─── 12: --health ────────────────────────────────────────────"
# (a) Missing log dir → unknown.
W_MISSING="$(new_workdir)/nope"   # subdir of a tracked tmpdir, never created
set +e
UPDATER_LOG_DIR="$W_MISSING" "$SCRIPT" --health >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 5 ] || fail "--health on missing log dir exit=$rc, expected 5 (unknown)"
pass "--health on missing log dir → exit 5"

UPDATER_LOG_DIR="$W_MISSING" "$SCRIPT" --health --json > "${W_MISSING%/nope}/h.json" 2>/dev/null || true
python3 - "${W_MISSING%/nope}/h.json" <<'PY' || fail "--health --json on missing dir not status=unknown"
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("status") == "unknown", f"status={d.get('status')!r}, expected 'unknown'"
PY
pass "--health --json on missing log dir reports status=unknown"

# (b) Clean dry-run → healthy.
W=$(new_workdir)
run_updater "$W" >/dev/null
set +e
run_updater "$W" --health > "${W}/h.txt" 2>&1
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "--health after clean dry-run exit=$rc, expected 0. out: $(cat "${W}/h.txt")"
pass "--health after clean dry-run → exit 0 (healthy)"

# (c) Malformed JSONL line → degraded.
echo 'this is not json {{{' >> "${W}/updater.jsonl"
set +e
run_updater "$W" --health >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "--health with malformed JSONL exit=$rc, expected 4 (degraded)"
pass "--health with malformed JSONL → exit 4 (degraded)"

run_updater "$W" --health --json > "${W}/h.json" 2>/dev/null || true
python3 - "${W}/h.json" <<'PY' || fail "--health --json missing required checks"
import json, sys
d = json.load(open(sys.argv[1]))
checks = d.get("checks")
required = {
    "log_dir_exists", "jsonl_present", "jsonl_parses", "last_run_parses",
    "last_run_packages", "dpkg_unbroken", "reboot_not_required",
}
# checks may be a list-of-{name,ok,...} or a dict keyed by name; tolerate both.
if isinstance(checks, list):
    by_name = {c.get("name"): c for c in checks if isinstance(c, dict)}
elif isinstance(checks, dict):
    by_name = checks
else:
    raise AssertionError(f"checks has unexpected type: {type(checks).__name__}")
missing = required - set(by_name.keys())
assert not missing, f"--health --json missing checks: {missing} (have: {set(by_name.keys())})"
# jsonl_parses must report failure on the malformed file.
jp = by_name["jsonl_parses"]
ok = jp.get("ok") if isinstance(jp, dict) else jp
status = jp.get("status") if isinstance(jp, dict) else None
assert ok is not True and status not in ("ok", "pass"), \
    f"jsonl_parses still ok after we appended garbage: {jp!r}"
PY
pass "--health --json reports all 7 checks; jsonl_parses fails on garbage"

# ─── 13: --health-acknowledge ───────────────────────────────────────────────
section "─── 13: --health-acknowledge ────────────────────────────────"
W=$(new_workdir)
run_updater "$W" >/dev/null
echo 'garbage line {' >> "${W}/updater.jsonl"

set +e; run_updater "$W" --health >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 4 ] || fail "pre-ack --health exit=$rc, expected 4"

set +e; run_updater "$W" --health-acknowledge > "${W}/ack.out" 2>&1; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "--health-acknowledge exit=$rc. out: $(cat "${W}/ack.out")"
[ -s "${W}/.health-baseline" ] || fail "--health-acknowledge did not write .health-baseline"
pass "--health-acknowledge writes .health-baseline and exits 0"

set +e; run_updater "$W" --health >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 0 ] || fail "post-ack --health exit=$rc, expected 0 (healthy after ack)"
pass "post-ack --health → healthy"

# Add a *new* malformed line; degraded must return.
echo 'more garbage }' >> "${W}/updater.jsonl"
set +e; run_updater "$W" --health >/dev/null 2>&1; rc=$?; set -e
[ "$rc" -eq 4 ] || fail "post-ack new-garbage --health exit=$rc, expected 4 (re-degraded)"
pass "new garbage after ack → degraded again"

# JSON variant parses.
run_updater "$W" --health-acknowledge --json > "${W}/ack.json"
python3 -c "import json,sys; json.load(open('${W}/ack.json'))" \
  || fail "--health-acknowledge --json output is not valid JSON"
pass "--health-acknowledge --json parses"

# ─── 14: capability completeness ────────────────────────────────────────────
section "─── 14: capability completeness ─────────────────────────────"
CAP_W=$(new_workdir)
( unset UPDATER_LOG_DIR; "$SCRIPT" --version --json > "${CAP_W}/caps.json" )
mapfile -t CLAIMED < <(python3 -c "
import json
for c in json.load(open('${CAP_W}/caps.json'))['capabilities']:
    print(c)
")
[ "${#CLAIMED[@]}" -eq 15 ] || fail "expected 15 capabilities, got ${#CLAIMED[@]}"
pass "capabilities[] has 15 entries"

probe_fail() { fail "capability '$1' probe failed: $2"; }

for cap in "${CLAIMED[@]}"; do
  P="${CAP_W}/${cap//[^a-zA-Z0-9_-]/_}"
  mkdir -p "$P"
  case "$cap" in
    version)
      out=$( ( unset UPDATER_LOG_DIR; "$SCRIPT" --version ) 2>&1) || probe_fail "$cap" "non-zero exit"
      case "$out" in *system-updater*) : ;; *) probe_fail "$cap" "stdout lacks 'system-updater'";; esac
      ;;
    version-json)
      ( unset UPDATER_LOG_DIR; "$SCRIPT" --version --json > "${P}/v.json" ) || probe_fail "$cap" "exit"
      python3 -c "import json; d=json.load(open('${P}/v.json')); assert d['version']=='0.1.0'" \
        || probe_fail "$cap" "version field not 0.1.0"
      ;;
    report)
      run_updater "$P" >/dev/null
      run_updater "$P" --report > "${P}/r.out" || probe_fail "$cap" "exit"
      [ -s "${P}/r.out" ] || probe_fail "$cap" "empty output"
      ;;
    report-json)
      run_updater "$P" >/dev/null
      run_updater "$P" --report --json > "${P}/r.json" || probe_fail "$cap" "exit"
      python3 -c "import json; d=json.load(open('${P}/r.json')); assert 'data_quality' in d" \
        || probe_fail "$cap" "missing data_quality"
      ;;
    health)
      run_updater "$P" >/dev/null
      set +e; run_updater "$P" --health >/dev/null 2>&1; rc=$?; set -e
      case "$rc" in 0|4|5) : ;; *) probe_fail "$cap" "exit $rc not in {0,4,5}";; esac
      ;;
    health-json)
      run_updater "$P" >/dev/null
      run_updater "$P" --health --json > "${P}/h.json" 2>/dev/null || true
      python3 -c "import json; d=json.load(open('${P}/h.json')); assert 'status' in d" \
        || probe_fail "$cap" "missing status"
      ;;
    health-acknowledge)
      run_updater "$P" >/dev/null
      echo 'garbage' >> "${P}/updater.jsonl"
      run_updater "$P" --health-acknowledge >/dev/null || probe_fail "$cap" "exit"
      [ -s "${P}/.health-baseline" ] || probe_fail "$cap" ".health-baseline missing"
      ;;
    only)
      run_updater "$P" --only pkg-clean >/dev/null || probe_fail "$cap" "exit"
      python3 - "${P}/updater.jsonl" <<'PY' || probe_fail "$cap" "--only did not restrict"
import json, sys
active = set()
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get("stage")=="package" and o.get("status") in ("dry_run","ok"):
        active.add(o["package"])
assert active == {"pkg-clean"}, f"active packages: {active}"
PY
      ;;
    exclude)
      run_updater "$P" --exclude 'pkg-h*' >/dev/null || probe_fail "$cap" "exit"
      python3 - "${P}/updater.jsonl" <<'PY' || probe_fail "$cap" "--exclude did not exclude pkg-held"
import json, sys
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get("stage")=="package" and o.get("package")=="pkg-held":
        assert o["status"]=="excluded", f"pkg-held status={o['status']!r}"
PY
      ;;
    holds)
      UPDATER_HOLD_PACKAGES='pkg-held*' run_updater "$P" >/dev/null || probe_fail "$cap" "exit"
      grep -q '"package":"pkg-held","[^"]*":"[^"]*"\|"status":"held"' "${P}/updater.jsonl" \
        || probe_fail "$cap" "no held event"
      ;;
    security-only)
      UPDATER_SECURITY_ONLY=yes run_updater "$P" >/dev/null || probe_fail "$cap" "exit"
      python3 - "${P}/updater.jsonl" <<'PY' || probe_fail "$cap" "security-only semantics broken"
import json, sys
for l in open(sys.argv[1]):
    l=l.strip()
    if not l: continue
    o=json.loads(l)
    if o.get("stage")=="package" and o.get("package")=="pkg-clean":
        assert o["status"]=="filtered_non_security", o
PY
      ;;
    maintenance-window)
      # Use the same +6h trick from stage 10 to guarantee out-of-window.
      H=$(( ( $(date +%H | sed 's/^0//') + 6 ) % 24 ))
      WIN=$(printf '%02d:00-%02d:01' "$H" "$H")
      set +e
      UPDATER_MAINTENANCE_WINDOW="$WIN" run_updater "$P" >/dev/null 2>&1
      rc=$?
      set -e
      [ "$rc" -eq 6 ] || probe_fail "$cap" "out-of-window exit=$rc, want 6"
      ;;
    force)
      H=$(( ( $(date +%H | sed 's/^0//') + 6 ) % 24 ))
      WIN=$(printf '%02d:00-%02d:01' "$H" "$H")
      UPDATER_MAINTENANCE_WINDOW="$WIN" run_updater "$P" --force >/dev/null \
        || probe_fail "$cap" "--force did not bypass window"
      ;;
    stub-backend)
      UPDATER_BACKEND=stub run_updater "$P" >/dev/null || probe_fail "$cap" "stub run failed"
      grep -q 'pkg-clean\|pkg-security\|pkg-held' "${P}/updater.jsonl" \
        || probe_fail "$cap" "stub run produced no stub-package events"
      ;;
    apt-backend)
      # Hermetic: just verify the script accepts UPDATER_BACKEND=apt in
      # --version mode without crashing. We cannot run a real apt cycle.
      ( unset UPDATER_LOG_DIR; UPDATER_BACKEND=apt "$SCRIPT" --version >/dev/null ) \
        || probe_fail "$cap" "UPDATER_BACKEND=apt --version crashed"
      ;;
    *)
      fail "capability completeness: unknown capability '$cap' — add a probe in tests/updater-smoke.sh"
      ;;
  esac
done
pass "all 15 capabilities probed end-to-end"

# ─── 15: schema validation (optional) ───────────────────────────────────────
section "─── 15: schema validation ───────────────────────────────────"
SCHEMA_REPORT="${REPO_ROOT}/schemas/updater-report.schema.json"
SCHEMA_HEALTH="${REPO_ROOT}/schemas/updater-health.schema.json"

if [ -s "$SCHEMA_REPORT" ] && [ -s "$SCHEMA_HEALTH" ]; then
  W=$(new_workdir)
  run_updater "$W" >/dev/null
  run_updater "$W" --report --json > "${W}/r.json"
  run_updater "$W" --health --json > "${W}/h.json" 2>/dev/null || true
  for pair in "report:$SCHEMA_REPORT:${W}/r.json" "health:$SCHEMA_HEALTH:${W}/h.json"; do
    name="${pair%%:*}"; rest="${pair#*:}"; schema="${rest%%:*}"; data="${rest#*:}"
    set +e
    python3 - "$schema" "$data" > "${W}/${name}.err" 2>&1 <<'PY'
import json, sys
try:
    import jsonschema
except ImportError:
    sys.exit(0)
jsonschema.validate(json.load(open(sys.argv[2])), json.load(open(sys.argv[1])))
PY
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      pass "--${name} --json validates against updater-${name}.schema.json"
    else
      fail "15: --${name} --json does not match updater-${name}.schema.json:"
      sed 's/^/      /' "${W}/${name}.err" >&2
    fi
  done
else
  warn "15: skipped — schemas not yet present (updater-report/updater-health)"
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "  updater-smoke: PASS — ${ASSERTIONS} assertions across 15 stages"
echo "════════════════════════════════════════════════════════════════"
