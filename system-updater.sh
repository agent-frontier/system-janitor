#!/usr/bin/env bash
# system-updater — Debian/Ubuntu apt package updater with audit-grade logging.
#
# Sibling tool to system-janitor. Same agent contract (exit codes, status
# enum, capability list, JSONL audit trail, atomic state writes, lock
# discipline). Where the contract is extended for package upgrades, see
# --help and docs/agents/contracts.md.
#
# Defaults to --dry-run (apt-get -s upgrade). The destructive path
# (apt-get upgrade -y) requires --apply AND euid==0; otherwise refused
# with exit 2 + clear stderr.
#
# Configuration:
#   ~/.config/system-updater/config       (XDG_CONFIG_HOME/system-updater/config)
# or
#   --config <path>                       (override on command line)
#
# Environment variables also accepted; see --help.

set -uo pipefail

# ── Version ────────────────────────────────────────────────────────────
# Bumped whenever the agent-visible contract changes (capabilities list,
# exit codes, JSONL/report/health schemas). The capabilities array in
# do_version() below is the authoritative feature-detection surface for
# autonomous agents — they should query `--version --json`.
readonly VERSION="0.1.0"
# ── end Version ────────────────────────────────────────────────────────

# ── Default cron-safe environment ──────────────────────────────────────
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
[ -z "${HOME:-}" ] && { echo "[FATAL] HOME unset" >&2; exit 3; }

# ── XDG paths ──────────────────────────────────────────────────────────
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${XDG_STATE_HOME:=${HOME}/.local/state}"

DEFAULT_CONFIG="${XDG_CONFIG_HOME}/system-updater/config"

# ── CLI flags ──────────────────────────────────────────────────────────
CONFIG_FILE=""
DRY_RUN=1            # default: dry-run is the safe path
APPLY=0
FORCE=0
SHOW_HELP=0
DO_REPORT=0
REPORT_JSON=0
DO_HEALTH=0
DO_HEALTH_ACK=0
DO_VERSION=0
ONLY_PACKAGES=()
EXCLUDE_PACKAGES=()
EXPLICIT_DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --config=*)   CONFIG_FILE="${1#*=}"; shift ;;
    --dry-run|-n) DRY_RUN=1; EXPLICIT_DRY_RUN=1; shift ;;
    --apply)      APPLY=1; DRY_RUN=0; shift ;;
    --force)      FORCE=1; shift ;;
    --report)     DO_REPORT=1; shift ;;
    --health)     DO_HEALTH=1; shift ;;
    --health-acknowledge) DO_HEALTH_ACK=1; shift ;;
    --version)    DO_VERSION=1; shift ;;
    --json)       REPORT_JSON=1; shift ;;
    --only)
      [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value" >&2; exit 3; }
      IFS=',' read -r -a _only_parts <<< "$2"
      for _p in "${_only_parts[@]}"; do
        [ -n "$_p" ] && ONLY_PACKAGES+=("$_p")
      done
      shift 2 ;;
    --only=*)
      IFS=',' read -r -a _only_parts <<< "${1#*=}"
      for _p in "${_only_parts[@]}"; do
        [ -n "$_p" ] && ONLY_PACKAGES+=("$_p")
      done
      shift ;;
    --exclude)
      [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value" >&2; exit 3; }
      IFS=',' read -r -a _excl_parts <<< "$2"
      for _p in "${_excl_parts[@]}"; do
        [ -n "$_p" ] && EXCLUDE_PACKAGES+=("$_p")
      done
      shift 2 ;;
    --exclude=*)
      IFS=',' read -r -a _excl_parts <<< "${1#*=}"
      for _p in "${_excl_parts[@]}"; do
        [ -n "$_p" ] && EXCLUDE_PACKAGES+=("$_p")
      done
      shift ;;
    --help|-h)    SHOW_HELP=1; shift ;;
    *) echo "[ERROR] unknown flag: $1" >&2; SHOW_HELP=1; shift ;;
  esac
done

# --apply and --dry-run are mutually exclusive.
if [ "$APPLY" = 1 ] && [ "$EXPLICIT_DRY_RUN" = 1 ]; then
  echo "[ERROR] --apply and --dry-run are mutually exclusive" >&2
  exit 3
fi

# --json is only meaningful as a modifier on a read-only flag.
if [ "$REPORT_JSON" = 1 ] \
   && [ "$DO_REPORT" != 1 ] \
   && [ "$DO_HEALTH" != 1 ] \
   && [ "$DO_VERSION" != 1 ] \
   && [ "$DO_HEALTH_ACK" != 1 ]; then
  echo "[ERROR] --json requires --report, --health, --health-acknowledge, or --version" >&2
  exit 3
fi

if [ "$SHOW_HELP" = 1 ]; then
  cat <<'USAGE'
system-updater — apt package updater with audit-grade logging.

USAGE:
  system-updater [--config <path>] [--dry-run | --apply] [--force]
                 [--only <list>] [--exclude <list>]
                 [--report [--json]] [--health [--json]]
                 [--health-acknowledge [--json]]
                 [--version [--json]] [--help]

FLAGS:
  --config <path>   Source <path> for configuration (default:
                    $XDG_CONFIG_HOME/system-updater/config)
  --dry-run, -n     Simulate the upgrade (apt-get -s upgrade). No package
                    is modified. This is the DEFAULT when neither
                    --dry-run nor --apply is given.
  --apply           Actually perform the upgrade (apt-get upgrade -y).
                    Requires euid==0; otherwise exits 2.
                    Mutually exclusive with --dry-run.
  --force           Bypass the maintenance-window gate
                    (UPDATER_MAINTENANCE_WINDOW). Has no other effect.
  --only <list>     Restrict to the named packages (comma-separated,
                    exact names — no globs). Other packages skipped
                    silently with status=excluded.
  --exclude <list>  Skip the matching packages (comma-separated globs).
                    Skipped packages emit a dispatcher event with
                    status=excluded.
  --report          Print a human summary of past runs from
                    $UPDATER_LOG_DIR/updater.jsonl and exit 0.
                    Read-only: no lock, no log dir creation.
  --health          Probe the audit trail and exit:
                      0  healthy
                      4  degraded
                      5  unknown (never run here)
  --health-acknowledge
                    Record current size of updater.jsonl as a baseline
                    so future --health probes ignore historical
                    malformed lines. Atomic write.
  --json            Modifier for --report / --health /
                    --health-acknowledge / --version. ASCII-safe JSON.
  --version         Print version. Pair with --json for the
                    capabilities[] feature-detection surface.
  --help, -h        Show this help and exit.

CONFIG (sourced as bash):
  UPDATER_BACKEND              apt | stub | auto (default: auto — apt
                               if apt-get present, else stub)
  UPDATER_HOLD_PACKAGES        space-separated globs; matching packages
                               are skipped with status=held
  UPDATER_SECURITY_ONLY        yes/no — when yes, non-security packages
                               are skipped with status=filtered_non_security
                               (security detected via source repo
                               containing "security")
  UPDATER_MAINTENANCE_WINDOW   HH:MM-HH:MM — refuse to run outside the
                               window with exit 6; --force bypasses
  UPDATER_REQUIRE_SNAPSHOT     yes/no — accepted as v0 stub (logs
                               snapshot_check=stub; always passes).
                               Real detection deferred.
  UPDATER_LOG_DIR              state directory
                               (default: $XDG_STATE_HOME/system-updater)

EXIT CODES:
  0   success (default run, --health healthy, --report, --version)
  1   another instance running (lock held)
  2   pre-flight failed (--apply without root; snapshot required but
      missing — v0 stub always passes)
  3   precondition failed (e.g., HOME unset, --json without prereq,
      --apply with --dry-run, conflicting flags)
  4   --health: degraded
  5   --health: unknown (never run here)
  6   refused: outside UPDATER_MAINTENANCE_WINDOW (use --force to bypass)
  7   one or more package upgrades failed during --apply

STATUS ENUM (updater.jsonl "status" field):
  ok                       package upgraded successfully
  warn                     non-fatal issue (informational)
  dry_run                  --dry-run; package would have been upgraded
  idle                     run produced no work
  held                     skipped: matched UPDATER_HOLD_PACKAGES
  excluded                 skipped: matched --exclude or not in --only
  filtered_non_security    skipped: UPDATER_SECURITY_ONLY=yes and not
                           a security update
  out_of_window            refused: outside UPDATER_MAINTENANCE_WINDOW
  reboot_required          run_end event when /var/run/reboot-required
                           was present after the run
  snapshot_missing         pre-flight: snapshot required but missing
                           (v0 stub always passes; reserved)
  failed                   --apply: package upgrade failed

EXAMPLES:
  # Dry-run preview (default):
  system-updater
  system-updater --dry-run

  # Real upgrade (must be root):
  sudo system-updater --apply

  # Security-only with hold list:
  UPDATER_SECURITY_ONLY=yes UPDATER_HOLD_PACKAGES="linux-* nvidia-*" \
    sudo system-updater --apply

  # Targeted upgrade:
  sudo system-updater --apply --only curl,openssl

  # Machine-readable run summary:
  system-updater --report --json

  # Feature-detection probe:
  system-updater --version --json

  # Health recovery after a historical malformed line:
  system-updater --health                 # → degraded (exit 4)
  system-updater --health-acknowledge     # baseline current EOF
  system-updater --health                 # → healthy (exit 0)

LOGS:
  $UPDATER_LOG_DIR/updater.log              human-readable
  $UPDATER_LOG_DIR/updater.jsonl            one JSON event per package (append-only)
  $UPDATER_LOG_DIR/updater-last-run.json    latest summary (atomic)
  $UPDATER_LOG_DIR/.health-baseline         byte offset for --health
  Default UPDATER_LOG_DIR: $XDG_STATE_HOME/system-updater.

See https://github.com/agent-frontier/agent-toolkit for full docs.
USAGE
  exit 0
fi

# ── Load configuration ────────────────────────────────────────────────
load_config() {
  local f="${CONFIG_FILE:-$DEFAULT_CONFIG}"
  if [ -f "$f" ]; then
    # shellcheck disable=SC1090
    if ! source "$f"; then
      echo "[FATAL] config file invalid: $f" >&2
      exit 3
    fi
    CONFIG_LOADED="$f"
  else
    CONFIG_LOADED=""
  fi
}
load_config

# Apply defaults (config values win over these).
UPDATER_BACKEND="${UPDATER_BACKEND:-auto}"
UPDATER_HOLD_PACKAGES="${UPDATER_HOLD_PACKAGES:-}"
UPDATER_SECURITY_ONLY="${UPDATER_SECURITY_ONLY:-no}"
UPDATER_MAINTENANCE_WINDOW="${UPDATER_MAINTENANCE_WINDOW:-}"
UPDATER_REQUIRE_SNAPSHOT="${UPDATER_REQUIRE_SNAPSHOT:-no}"
UPDATER_LOG_DIR="${UPDATER_LOG_DIR:-${XDG_STATE_HOME}/system-updater}"

# Resolve auto backend.
if [ "$UPDATER_BACKEND" = "auto" ]; then
  if command -v apt-get >/dev/null 2>&1; then
    UPDATER_BACKEND="apt"
  else
    UPDATER_BACKEND="stub"
  fi
fi

# ── Read-only report (must run BEFORE mkdir/flock/exec-redirect) ──────
do_report() {
  local jsonl="${UPDATER_LOG_DIR}/updater.jsonl"
  local last_run="${UPDATER_LOG_DIR}/updater-last-run.json"
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"

  REPORT_MODE="$mode" \
    REPORT_LOG_DIR="$UPDATER_LOG_DIR" \
    REPORT_JSONL="$jsonl" \
    REPORT_LAST_RUN="$last_run" \
    python3 - <<'PY'
import json, os, sys, datetime
from collections import defaultdict, OrderedDict

mode     = os.environ["REPORT_MODE"]
log_dir  = os.environ["REPORT_LOG_DIR"]
path     = os.environ["REPORT_JSONL"]
last_run_path = os.environ["REPORT_LAST_RUN"]

generated_at = datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")

def emit_json(obj):
    sys.stdout.write(json.dumps(obj, indent=2))
    sys.stdout.write("\n")

empty = {
    "generated_at": generated_at,
    "log_dir": log_dir,
    "jsonl_path": path,
    "total_runs": 0,
    "real_runs": 0,
    "dry_runs": 0,
    "total_packages_upgraded": 0,
    "total_packages_failed": 0,
    "total_packages_held": 0,
    "date_range": {"first": None, "last": None},
    "per_package": [],
    "most_recent_run": None,
    "idle_streaks": [],
    "data_quality": {"invalid_lines": 0, "examples": []},
}

if not os.path.isfile(path):
    if mode == "json":
        emit_json(empty)
    else:
        print("system-updater - report")
        print(f"  log dir : {log_dir}")
        print()
        print(f"no runs found at {path}")
    sys.exit(0)

events = []
malformed = []
with open(path, "r", errors="replace") as fh:
    for lineno, raw in enumerate(fh, 1):
        line = raw.rstrip("\n")
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
            if not isinstance(obj, dict):
                raise ValueError("not an object")
        except Exception as e:
            malformed.append((lineno, str(e)[:120]))
            continue
        events.append(obj)

run_ids = []
seen = set()
for ev in events:
    rid = ev.get("run_id")
    if rid and rid not in seen:
        seen.add(rid)
        run_ids.append(rid)

dry_run_ids = set()
real_run_ids = set()
for ev in events:
    if ev.get("stage") == "run_start":
        rid = ev.get("run_id")
        dr = ev.get("dry_run")
        if dr in (1, "1", True, "yes", "true"):
            dry_run_ids.add(rid)
        else:
            real_run_ids.add(rid)
unknown = set(run_ids) - dry_run_ids - real_run_ids
real_run_ids |= unknown

timestamps = sorted(ev.get("ts", "") for ev in events if ev.get("ts"))
ts_first = timestamps[0]  if timestamps else None
ts_last  = timestamps[-1] if timestamps else None

per_package = defaultdict(lambda: {"runs": set(), "upgrades": 0, "fails": 0,
                                   "held": 0, "last_status": "", "last_seen": ""})
total_upgraded = 0
total_failed = 0
total_held = 0

for ev in events:
    if ev.get("stage") != "package":
        continue
    name = ev.get("package") or ""
    if not name:
        continue
    status = ev.get("status", "")
    ts = ev.get("ts") or ""
    p = per_package[name]
    p["runs"].add(ev.get("run_id"))
    if status == "ok":
        p["upgrades"] += 1
        total_upgraded += 1
    elif status == "failed":
        p["fails"] += 1
        total_failed += 1
    elif status == "held":
        p["held"] += 1
        total_held += 1
    if ts >= (p["last_seen"] or ""):
        p["last_seen"] = ts
        p["last_status"] = status

per_package_list = [
    {
        "name": n,
        "runs": len(p["runs"]),
        "upgrades": p["upgrades"],
        "fails": p["fails"],
        "held": p["held"],
        "last_status": p["last_status"],
        "last_seen": p["last_seen"],
    }
    for n, p in sorted(per_package.items(), key=lambda kv: (-kv[1]["upgrades"], kv[0]))
]

# Most recent run from updater-last-run.json (preferred) or run_end event.
most_recent = None
if os.path.isfile(last_run_path):
    try:
        with open(last_run_path, "r", errors="replace") as fh:
            most_recent = json.load(fh)
    except Exception:
        most_recent = None
if most_recent is None:
    last_end = None
    for ev in events:
        if ev.get("stage") == "run_end":
            if last_end is None or (ev.get("ts", "") > last_end.get("ts", "")):
                last_end = ev
    if last_end:
        most_recent = {
            "run_id": last_end.get("run_id"),
            "finished": last_end.get("ts"),
            "status": last_end.get("status"),
        }

# Idle streaks: per package, count trailing consecutive runs where status != ok.
# Lightweight v0 implementation; surface streaks >= 2.
pkg_events = defaultdict(list)
for ev in events:
    if ev.get("stage") != "package":
        continue
    if ev.get("run_id") not in real_run_ids:
        continue
    name = ev.get("package") or ""
    if not name:
        continue
    pkg_events[name].append(ev)

idle_streaks = []
for name, evs in pkg_events.items():
    evs_sorted = sorted(evs, key=lambda e: e.get("ts", ""))
    trailing = 0
    last_productive = None
    for ev in evs_sorted:
        if ev.get("status") == "ok":
            last_productive = {"run_id": ev.get("run_id"), "ts": ev.get("ts")}
            trailing = 0
        elif ev.get("status") in ("held", "excluded", "filtered_non_security", "idle"):
            trailing += 1
        else:
            trailing = 0
    if trailing >= 2:
        idle_streaks.append({
            "package": name,
            "consecutive_idle_runs": trailing,
            "last_productive_run": last_productive,
        })
idle_streaks.sort(key=lambda d: -d["consecutive_idle_runs"])

if mode == "json":
    out = OrderedDict()
    out["generated_at"] = generated_at
    out["log_dir"]      = log_dir
    out["jsonl_path"]   = path
    out["total_runs"]   = len(run_ids)
    out["real_runs"]    = len(real_run_ids)
    out["dry_runs"]     = len(dry_run_ids)
    out["total_packages_upgraded"] = total_upgraded
    out["total_packages_failed"]   = total_failed
    out["total_packages_held"]     = total_held
    out["date_range"]   = {"first": ts_first, "last": ts_last}
    out["per_package"]  = per_package_list
    out["most_recent_run"] = most_recent
    out["idle_streaks"] = idle_streaks
    out["data_quality"] = {
        "invalid_lines": len(malformed),
        "examples": [{"line": ln, "error": err} for ln, err in malformed[:3]],
    }
    emit_json(out)
    sys.exit(0)

print("system-updater - report")
print(f"  log dir : {log_dir}")
print(f"  events  : {len(events)} (across {len(run_ids)} runs)")
ts_min = ts_first[:10] if ts_first else "?"
ts_max = ts_last[:10]  if ts_last  else "?"
print(f"  range   : {ts_min} .. {ts_max}")
print(f"  real runs: {len(real_run_ids)}    dry runs: {len(dry_run_ids)}")
print()
print(f"Totals: upgraded={total_upgraded}  failed={total_failed}  held={total_held}")
print()
print("Per-package:")
print(f"  {'package':<32} {'runs':>5} {'upg':>5} {'fail':>5} {'held':>5}   last")
for p in per_package_list:
    print(f"  {p['name']:<32} {p['runs']:>5} {p['upgrades']:>5} {p['fails']:>5} {p['held']:>5}   {p['last_status']}")
if idle_streaks:
    print()
    print("Idle packages (skipped/non-productive trailing real runs):")
    for entry in idle_streaks:
        print(f"  {entry['package']:<32} idle for {entry['consecutive_idle_runs']} runs")
print()
print("Most recent run:")
if most_recent:
    print(f"  {most_recent.get('run_id','?')}  finished={most_recent.get('finished','?')}")
else:
    print("  (none)")
if malformed:
    print()
    print(f"Data-quality issues: {len(malformed)} malformed line(s)")
    for ln, err in malformed[:5]:
        print(f"  line {ln}: {err[:60]}")
PY
}

if [ "$DO_REPORT" = 1 ]; then
  do_report
  exit 0
fi

# ── --version flag ─────────────────────────────────────────────────────
do_version() {
  if [ "$REPORT_JSON" = 1 ]; then
    python3 - <<PY
import json
print(json.dumps({
    "name": "system-updater",
    "version": "${VERSION}",
    "capabilities": sorted([
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
        "version-json",
    ]),
}, indent=2))
PY
  else
    printf 'system-updater %s\n' "$VERSION"
  fi
}

if [ "$DO_VERSION" = 1 ]; then
  do_version
  exit 0
fi
# ── end --version flag ─────────────────────────────────────────────────

# ── --health flag ──────────────────────────────────────────────────────
do_health() {
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"
  local log_dir="$UPDATER_LOG_DIR"
  local jsonl="${log_dir}/updater.jsonl"
  local last_run="${log_dir}/updater-last-run.json"
  local baseline_file="${log_dir}/.health-baseline"

  HEALTH_MODE="$mode" \
    HEALTH_LOG_DIR="$log_dir" \
    HEALTH_JSONL="$jsonl" \
    HEALTH_LAST_RUN="$last_run" \
    HEALTH_BASELINE_FILE="$baseline_file" \
    python3 - <<'PY'
import json, os, sys, datetime, subprocess, time, shutil

mode          = os.environ["HEALTH_MODE"]
log_dir       = os.environ["HEALTH_LOG_DIR"]
jsonl         = os.environ["HEALTH_JSONL"]
last_run      = os.environ["HEALTH_LAST_RUN"]
baseline_file = os.environ["HEALTH_BASELINE_FILE"]

generated_at = datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")

checks = []
def add(name, ok, detail=None):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})

# log_dir_exists
log_dir_ok = os.path.isdir(log_dir)
add("log_dir_exists", log_dir_ok, log_dir if log_dir_ok else f"{log_dir} (missing)")

# Read baseline
baseline = 0
if log_dir_ok and os.path.isfile(baseline_file):
    try:
        with open(baseline_file, "r", errors="replace") as bf:
            baseline = int((bf.read().strip() or "0"))
        if baseline < 0:
            baseline = 0
    except Exception:
        baseline = 0

# jsonl_present
jsonl_ok = False
jsonl_detail = None
event_count = 0
lines = []
line_offsets = []
if log_dir_ok:
    if os.path.isfile(jsonl) and os.path.getsize(jsonl) > 0:
        try:
            with open(jsonl, "rb") as fh:
                raw = fh.read()
            byte_lines = raw.splitlines(keepends=True)
            off = 0
            for bl in byte_lines:
                line_offsets.append(off)
                off += len(bl)
                lines.append(bl.decode("utf-8", errors="replace"))
            event_count = sum(1 for l in lines if l.strip())
            jsonl_ok = event_count > 0
            jsonl_detail = f"{event_count} events" if jsonl_ok else "file present but empty"
        except OSError as e:
            jsonl_detail = f"read error: {e}"
    elif os.path.isfile(jsonl):
        jsonl_detail = "file present but empty"
    else:
        jsonl_detail = "updater.jsonl missing"
else:
    jsonl_detail = "log dir missing"
add("jsonl_present", jsonl_ok, jsonl_detail)

# baseline-applied slice
parse_start_idx = 0
if baseline > 0:
    parse_start_idx = len(line_offsets)
    for i, off in enumerate(line_offsets):
        if off >= baseline:
            parse_start_idx = i
            break
excluded_events = sum(1 for l in lines[:parse_start_idx] if l.strip())

# jsonl_parses
parses_ok = False
parses_detail = None
malformed = []
if jsonl_ok:
    iter_slice = lines[parse_start_idx:]
    base = parse_start_idx
    for j, raw in enumerate(iter_slice):
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if not isinstance(obj, dict):
                raise ValueError("not an object")
        except Exception as e:
            malformed.append((base + j + 1, str(e)[:100]))
    if not malformed:
        parses_ok = True
        considered = event_count - excluded_events
        if baseline > 0:
            parses_detail = (
                f"0 invalid lines among {considered} events checked "
                f"(baseline={baseline} bytes, {excluded_events} excluded)"
            )
        else:
            parses_detail = f"0 invalid lines ({event_count} events checked)"
    else:
        ln, err = malformed[0]
        n = len(malformed)
        parses_detail = f"{n} invalid line{'s' if n>1 else ''} (line {ln}: {err})"
else:
    parses_detail = "skipped: jsonl_present failed"
add("jsonl_parses", parses_ok, parses_detail)

# last_run_parses
last_data = None
last_parses_ok = False
last_parses_detail = None
if not log_dir_ok:
    last_parses_detail = "skipped: log dir missing"
elif not os.path.isfile(last_run):
    last_parses_detail = "updater-last-run.json missing"
else:
    try:
        with open(last_run, "r", errors="replace") as fh:
            last_data = json.load(fh)
        last_parses_ok = True
    except Exception as e:
        last_parses_detail = f"parse error: {str(e)[:100]}"
add("last_run_parses", last_parses_ok, last_parses_detail)

# last_run_packages
pkgs_ok = True
pkgs_detail = None
if last_data is None:
    pkgs_ok = False
    pkgs_detail = "skipped: last_run_parses failed"
elif "packages" not in last_data:
    pkgs_ok = False
    pkgs_detail = "missing packages[] in last-run.json"
else:
    pkgs = last_data.get("packages")
    if not isinstance(pkgs, list):
        pkgs_ok = False
        pkgs_detail = f"packages is not an array (got {type(pkgs).__name__})"
    else:
        bad = []
        for i, p in enumerate(pkgs):
            if not isinstance(p, dict):
                bad.append((i, "not an object")); continue
            missing = [k for k in ("name", "status") if k not in p]
            if missing:
                bad.append((i, f"missing {missing}"))
        if bad:
            pkgs_ok = False
            idx, err = bad[0]
            pkgs_detail = f"{len(bad)} malformed entr{'ies' if len(bad)>1 else 'y'} (index {idx}: {err})"
        else:
            pkgs_detail = f"{len(pkgs)} package record{'s' if len(pkgs)!=1 else ''} well-formed"
add("last_run_packages", pkgs_ok, pkgs_detail)

# dpkg_unbroken (informational; never blocks)
dpkg_ok = True
dpkg_detail = "skipped: dpkg unavailable"
if shutil.which("dpkg"):
    try:
        r = subprocess.run(["dpkg", "--audit"], capture_output=True, text=True, timeout=30)
        out = (r.stdout or "").strip()
        if out:
            dpkg_ok = True  # informational only — does not flip degraded
            dpkg_detail = f"dpkg --audit non-empty: {out.splitlines()[0][:80]}"
        else:
            dpkg_detail = "dpkg --audit clean"
    except Exception as e:
        dpkg_detail = f"dpkg --audit error: {str(e)[:80]}"
add("dpkg_unbroken", dpkg_ok, dpkg_detail)

# reboot_not_required (informational; never blocks)
reboot_ok = True
rr = "/var/run/reboot-required"
if os.path.isfile(rr):
    try:
        age_days = (time.time() - os.path.getmtime(rr)) / 86400.0
    except OSError:
        age_days = 0
    if age_days > 7:
        reboot_detail = f"reboot pending {age_days:.1f} days (informational)"
    else:
        reboot_detail = f"reboot pending {age_days:.1f} days"
else:
    reboot_detail = "no reboot required"
add("reboot_not_required", reboot_ok, reboot_detail)

# Overall status
last_run_missing = log_dir_ok and not os.path.isfile(last_run)
if not log_dir_ok or last_run_missing:
    status = "unknown"
    exit_code = 5
else:
    # Only blocking checks contribute to degraded; dpkg/reboot are informational.
    blocking = ["log_dir_exists", "jsonl_present", "jsonl_parses",
                "last_run_parses", "last_run_packages"]
    failed = [c for c in checks if c["name"] in blocking and not c["ok"]]
    if failed:
        status = "degraded"
        exit_code = 4
    else:
        status = "healthy"
        exit_code = 0

if mode == "json":
    out = {
        "status": status,
        "exit_code": exit_code,
        "generated_at": generated_at,
        "log_dir": log_dir,
        "checks": checks,
    }
    sys.stdout.write(json.dumps(out, indent=2))
    sys.stdout.write("\n")
else:
    print(f"system-updater health: {status} (exit {exit_code})")
    name_w = max(len(c["name"]) for c in checks)
    for c in checks:
        glyph = "OK" if c["ok"] else "XX"
        detail = "" if c["detail"] is None else c["detail"]
        print(f"  [{glyph}] {c['name']:<{name_w}}  {detail}")

sys.exit(exit_code)
PY
}

if [ "$DO_HEALTH" = 1 ]; then
  do_health
  exit $?
fi
# ── end --health flag ──────────────────────────────────────────────────

# ── --health-acknowledge flag ──────────────────────────────────────────
do_health_acknowledge() {
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"
  local log_dir="$UPDATER_LOG_DIR"
  local jsonl="${log_dir}/updater.jsonl"
  local baseline_file="${log_dir}/.health-baseline"

  ACK_MODE="$mode" \
    ACK_LOG_DIR="$log_dir" \
    ACK_JSONL="$jsonl" \
    ACK_BASELINE_FILE="$baseline_file" \
    python3 - <<'PY'
import json, os, sys

mode          = os.environ["ACK_MODE"]
log_dir       = os.environ["ACK_LOG_DIR"]
jsonl         = os.environ["ACK_JSONL"]
baseline_file = os.environ["ACK_BASELINE_FILE"]

size = 0
event_count = 0
if os.path.isfile(jsonl):
    try:
        size = os.path.getsize(jsonl)
        with open(jsonl, "rb") as fh:
            for ln in fh:
                if ln.strip():
                    event_count += 1
    except OSError:
        size = 0
        event_count = 0

try:
    os.makedirs(log_dir, exist_ok=True)
except OSError as e:
    sys.stderr.write(f"[ERROR] cannot create {log_dir}: {e}\n")
    sys.exit(3)

tmp = baseline_file + ".tmp"
try:
    with open(tmp, "w") as fh:
        fh.write(f"{size}\n")
    os.replace(tmp, baseline_file)
except OSError as e:
    sys.stderr.write(f"[ERROR] cannot write {baseline_file}: {e}\n")
    try: os.unlink(tmp)
    except OSError: pass
    sys.exit(3)

if mode == "json":
    out = {"acknowledged": True, "baseline_bytes": size, "excluded_events": event_count}
    sys.stdout.write(json.dumps(out, indent=2))
    sys.stdout.write("\n")
else:
    sys.stdout.write(
        f"acknowledged: baseline set to {size} bytes "
        f"({event_count} existing events excluded from future --health checks)\n"
    )
sys.exit(0)
PY
}

if [ "$DO_HEALTH_ACK" = 1 ]; then
  do_health_acknowledge
  exit $?
fi
# ── end --health-acknowledge flag ──────────────────────────────────────

# ───────────────────────────────────────────────────────────────────────
# Below this line: real / dry-run path. Acquires lock, writes audit trail.
# ───────────────────────────────────────────────────────────────────────

# ── Pre-flight: --apply requires root ─────────────────────────────────
if [ "$APPLY" = 1 ] && [ "$(id -u)" -ne 0 ]; then
  echo "[ERROR] --apply requires root (euid=0); rerun with sudo" >&2
  exit 2
fi

# ── Pre-flight: maintenance window ────────────────────────────────────
# Format: HH:MM-HH:MM (24h). Window may wrap midnight (e.g., 22:00-06:00).
in_maintenance_window() {
  local win="$1"
  local now_min start_h start_m end_h end_m start_min end_min
  case "$win" in
    [0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]) ;;
    *) echo "[ERROR] UPDATER_MAINTENANCE_WINDOW must be HH:MM-HH:MM, got: $win" >&2
       return 2 ;;
  esac
  now_min=$(( 10#$(date +%H) * 60 + 10#$(date +%M) ))
  start_h="${win%%:*}"
  start_m="${win#*:}"; start_m="${start_m%%-*}"
  end_h="${win##*-}"; end_h="${end_h%%:*}"
  end_m="${win##*:}"
  start_min=$((10#$start_h * 60 + 10#$start_m))
  end_min=$((10#$end_h * 60 + 10#$end_m))
  if [ "$start_min" -le "$end_min" ]; then
    [ "$now_min" -ge "$start_min" ] && [ "$now_min" -lt "$end_min" ]
  else
    # Wraps midnight.
    [ "$now_min" -ge "$start_min" ] || [ "$now_min" -lt "$end_min" ]
  fi
}

if [ -n "$UPDATER_MAINTENANCE_WINDOW" ] && [ "$FORCE" != 1 ]; then
  if ! in_maintenance_window "$UPDATER_MAINTENANCE_WINDOW"; then
    rc=$?
    if [ "$rc" = 2 ]; then
      exit 3   # malformed window value
    fi
    echo "[refused] outside UPDATER_MAINTENANCE_WINDOW=$UPDATER_MAINTENANCE_WINDOW; use --force to bypass" >&2
    exit 6
  fi
fi

# ── Augment PATH (cron-safe) ──────────────────────────────────────────
for d in "${HOME}/.local/bin" /usr/local/sbin /usr/sbin /sbin; do
  [ -d "$d" ] && case ":${PATH}:" in *":${d}:"*) ;; *) PATH="${d}:${PATH}";; esac
done
export PATH

# ── Paths and identifiers ──────────────────────────────────────────────
LOG_DIR="$UPDATER_LOG_DIR"
LOG="${LOG_DIR}/updater.log"
JSONL="${LOG_DIR}/updater.jsonl"
LATEST="${LOG_DIR}/updater-last-run.json"
LOCK="${LOG_DIR}/updater.lock"
mkdir -p "$LOG_DIR"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo deadbeef)"
PACKAGES_TMP="${LOG_DIR}/.packages.${RUN_ID}.$$"
: > "$PACKAGES_TMP"
RUN_STARTED_AT=""
RUN_ENDED_AT=""
HOSTNAME_S="$(hostname)"
USER_S="${USER:-$(id -un)}"

# ── Single-instance lock ───────────────────────────────────────────────
exec 9>"$LOCK"
if ! flock -n 9; then
  logger -t system-updater "skipped — another instance is running" 2>/dev/null || true
  echo "[skip] another instance is running" >&2
  exit 1
fi

# ── Log rotation (5 MB threshold, 8 backups) ───────────────────────────
rotate() {
  local f="$1"
  [ -f "$f" ] || return 0
  [ "$(stat -c%s "$f" 2>/dev/null || echo 0)" -le 5242880 ] && return 0
  for i in 7 6 5 4 3 2 1; do
    [ -f "${f}.${i}" ] && mv "${f}.${i}" "${f}.$((i+1))"
  done
  mv "$f" "${f}.1"
}
rotate "$LOG"
rotate "$JSONL"

exec >>"$LOG" 2>&1

# ── Helpers ────────────────────────────────────────────────────────────
ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

jsonescape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "${1//\"/\\\"}"
}

# emit_event <stage> <status> [package] [from_version] [to_version]
#            [duration_ms] [source_repo] [security_yes_no]
# Same numeric sanitization as janitor's emit_event for duration_ms.
emit_event() {
  local stage="$1" status="$2"
  local package="${3:-}" from_v="${4:-}" to_v="${5:-}"
  local dur_ms="${6:-0}"
  local source_repo="${7:-}" security="${8:-}"
  dur_ms="${dur_ms//[^0-9]/}"
  dur_ms=$((10#${dur_ms:-0} + 0))
  printf '{"ts":"%s","host":"%s","user":"%s","run_id":"%s","stage":"%s","package":%s,"from_version":%s,"to_version":%s,"status":"%s","duration_ms":%s,"dry_run":%s,"source_repo":%s,"security":%s}\n' \
    "$(ts)" "$HOSTNAME_S" "$USER_S" "$RUN_ID" "$stage" \
    "$(jsonescape "$package")" \
    "$(jsonescape "$from_v")" \
    "$(jsonescape "$to_v")" \
    "$status" "$dur_ms" "$DRY_RUN" \
    "$(jsonescape "$source_repo")" \
    "$(jsonescape "$security")" \
    >>"$JSONL"

  # Accumulate per-package records for last-run.json packages[].
  case "$stage" in
    package)
      printf '{"name":%s,"status":"%s","from_version":%s,"to_version":%s,"security":%s,"source_repo":%s}\n' \
        "$(jsonescape "$package")" "$status" \
        "$(jsonescape "$from_v")" \
        "$(jsonescape "$to_v")" \
        "$(jsonescape "$security")" \
        "$(jsonescape "$source_repo")" \
        >>"$PACKAGES_TMP" 2>/dev/null || true
      ;;
  esac
}

section_header() { echo; echo "── $* ── $(ts)"; }

# ── Backend dispatch ───────────────────────────────────────────────────
# v0 backends: apt, stub. dnf/zypper deferred — do not stub them here.
#
# Backend contract: prints one line per upgradable package to stdout in
# the format:
#   <name> <from_version> <to_version> <security_yes_no> <source_repo>
# Fields are space-separated. <source_repo> may be "-" if unknown.

_stub_apt_simulate() {
  printf '%s %s %s %s %s\n' \
    "pkg-clean"    "1.0" "1.1" "no"  "stub-main"
  printf '%s %s %s %s %s\n' \
    "pkg-security" "2.0" "2.1" "yes" "stub-security"
  printf '%s %s %s %s %s\n' \
    "pkg-held"     "3.0" "3.1" "no"  "stub-main"
}

_apt_simulate() {
  # apt-get -s upgrade output parsing: lines like
  #   "Inst <name> [<from>] (<to> <repo>)"
  # Source repo string contains "security" for security updates.
  apt-get -s upgrade 2>/dev/null \
    | awk '
        /^Inst / {
          name=$2
          from=""; to=""; repo=""; sec="no"
          # try to capture [from]
          for (i=3; i<=NF; i++) {
            if ($i ~ /^\[/) {
              from=$i
              gsub(/[\[\]]/, "", from)
            } else if ($i ~ /^\(/) {
              to=$i
              gsub(/^\(/, "", to)
              # accumulate the rest as repo until closing paren
              rest=""
              for (j=i+1; j<=NF; j++) {
                rest=rest " " $j
              }
              gsub(/^ +/, "", rest)
              gsub(/\)$/, "", rest)
              repo=rest
              break
            }
          }
          if (repo ~ /security/) sec="yes"
          if (from=="") from="-"
          if (to=="") to="-"
          if (repo=="") repo="-"
          gsub(/ /, "_", repo)
          print name, from, to, sec, repo
        }
      '
}

backend_list_upgrades() {
  case "$UPDATER_BACKEND" in
    stub) _stub_apt_simulate ;;
    apt)  _apt_simulate ;;
    # dnf|zypper — deferred (v0)
    *) echo "[FATAL] unknown UPDATER_BACKEND=$UPDATER_BACKEND" >&2; return 1 ;;
  esac
}

# Apply a single package upgrade. Echoes nothing on success, exits non-zero
# on failure. For stub backend, always succeeds.
backend_apply_one() {
  local name="$1"
  case "$UPDATER_BACKEND" in
    stub) return 0 ;;
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$name" >/dev/null 2>&1
      return $?
      ;;
    *) return 1 ;;
  esac
}

# ── Filter helpers ────────────────────────────────────────────────────
matches_glob_list() {
  # $1 = name, rest = space-separated globs
  local name="$1"; shift
  local pat
  for pat in "$@"; do
    # shellcheck disable=SC2254
    case "$name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

is_in_only() {
  local name="$1" p
  [ ${#ONLY_PACKAGES[@]} -eq 0 ] && return 0
  for p in "${ONLY_PACKAGES[@]}"; do
    [ "$p" = "$name" ] && return 0
  done
  return 1
}

is_excluded() {
  local name="$1"
  [ ${#EXCLUDE_PACKAGES[@]} -eq 0 ] && return 1
  matches_glob_list "$name" "${EXCLUDE_PACKAGES[@]}"
}

is_held() {
  local name="$1"
  [ -z "$UPDATER_HOLD_PACKAGES" ] && return 1
  # shellcheck disable=SC2086
  matches_glob_list "$name" $UPDATER_HOLD_PACKAGES
}

# ── Run header ─────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════════"
echo " system-updater"
echo " run_id  : $RUN_ID"
echo " host    : $HOSTNAME_S"
echo " user    : $USER_S"
echo " start   : $(ts)"
echo " config  : ${CONFIG_LOADED:-<none — using defaults>}"
echo " backend : $UPDATER_BACKEND"
echo " dryrun  : $DRY_RUN"
echo " apply   : $APPLY"
echo " holds   : ${UPDATER_HOLD_PACKAGES:-<none>}"
echo " sec_only: $UPDATER_SECURITY_ONLY"
echo " window  : ${UPDATER_MAINTENANCE_WINDOW:-<none>}"
echo " snapshot: $UPDATER_REQUIRE_SNAPSHOT (v0 stub: always passes)"
echo "════════════════════════════════════════════════════════════════"

RUN_STARTED_AT="$(ts)"
emit_event "run_start" "ok" "" "" "" 0 "" ""

# Snapshot gate (v0 stub).
echo "snapshot_check=stub (UPDATER_REQUIRE_SNAPSHOT=$UPDATER_REQUIRE_SNAPSHOT)"

# Refresh apt indexes for the apt backend on real apply runs.
if [ "$UPDATER_BACKEND" = "apt" ] && [ "$APPLY" = 1 ]; then
  section_header "apt-get update"
  apt-get update 2>&1 | tail -20 || true
fi

# ── Dispatcher: enumerate upgradable packages ─────────────────────────
section_header "enumerate upgradable packages (backend=$UPDATER_BACKEND)"
UPGRADE_LIST_FILE="${LOG_DIR}/.upgrade-list.${RUN_ID}.$$"
if ! backend_list_upgrades > "$UPGRADE_LIST_FILE" 2>>"$LOG"; then
  echo "[ERROR] backend enumeration failed"
  emit_event "dispatcher" "warn" "" "" "" 0 "" ""
fi

UPGRADE_COUNT=$(wc -l < "$UPGRADE_LIST_FILE" | tr -d ' ')
echo "upgradable: $UPGRADE_COUNT package(s)"

# ── Per-package processing ────────────────────────────────────────────
TOTAL_UPGRADED=0
TOTAL_FAILED=0
TOTAL_HELD=0
TOTAL_EXCLUDED=0
TOTAL_FILTERED=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  # Parse: name from to security source_repo
  # shellcheck disable=SC2086
  set -- $line
  pkg_name="${1:-}"
  pkg_from="${2:--}"
  pkg_to="${3:--}"
  pkg_sec="${4:-no}"
  pkg_repo="${5:--}"
  [ -z "$pkg_name" ] && continue

  # --only filter
  if ! is_in_only "$pkg_name"; then
    emit_event "dispatcher" "excluded" "$pkg_name" "$pkg_from" "$pkg_to" 0 "$pkg_repo" "$pkg_sec"
    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED+1))
    echo "  [excluded] $pkg_name (not in --only)"
    continue
  fi

  # --exclude filter
  if is_excluded "$pkg_name"; then
    emit_event "dispatcher" "excluded" "$pkg_name" "$pkg_from" "$pkg_to" 0 "$pkg_repo" "$pkg_sec"
    TOTAL_EXCLUDED=$((TOTAL_EXCLUDED+1))
    echo "  [excluded] $pkg_name (matched --exclude)"
    continue
  fi

  # Hold list
  if is_held "$pkg_name"; then
    emit_event "package" "held" "$pkg_name" "$pkg_from" "$pkg_to" 0 "$pkg_repo" "$pkg_sec"
    TOTAL_HELD=$((TOTAL_HELD+1))
    echo "  [held] $pkg_name (matched UPDATER_HOLD_PACKAGES)"
    continue
  fi

  # Security-only filter
  if [ "$UPDATER_SECURITY_ONLY" = "yes" ] && [ "$pkg_sec" != "yes" ]; then
    emit_event "package" "filtered_non_security" "$pkg_name" "$pkg_from" "$pkg_to" 0 "$pkg_repo" "$pkg_sec"
    TOTAL_FILTERED=$((TOTAL_FILTERED+1))
    echo "  [filtered] $pkg_name (UPDATER_SECURITY_ONLY=yes; not security)"
    continue
  fi

  # Apply or simulate
  start_ms=$(date +%s%3N 2>/dev/null || echo 0)
  if [ "$DRY_RUN" = "1" ]; then
    echo "  [dry_run] $pkg_name: $pkg_from -> $pkg_to (security=$pkg_sec, repo=$pkg_repo)"
    end_ms=$(date +%s%3N 2>/dev/null || echo 0)
    dur=$((end_ms - start_ms))
    [ "$dur" -lt 0 ] && dur=0
    emit_event "package" "dry_run" "$pkg_name" "$pkg_from" "$pkg_to" "$dur" "$pkg_repo" "$pkg_sec"
  else
    if backend_apply_one "$pkg_name"; then
      end_ms=$(date +%s%3N 2>/dev/null || echo 0)
      dur=$((end_ms - start_ms))
      [ "$dur" -lt 0 ] && dur=0
      echo "  [ok] $pkg_name: $pkg_from -> $pkg_to (${dur}ms)"
      emit_event "package" "ok" "$pkg_name" "$pkg_from" "$pkg_to" "$dur" "$pkg_repo" "$pkg_sec"
      TOTAL_UPGRADED=$((TOTAL_UPGRADED+1))
    else
      end_ms=$(date +%s%3N 2>/dev/null || echo 0)
      dur=$((end_ms - start_ms))
      [ "$dur" -lt 0 ] && dur=0
      echo "  [failed] $pkg_name: $pkg_from -> $pkg_to (${dur}ms)"
      emit_event "package" "failed" "$pkg_name" "$pkg_from" "$pkg_to" "$dur" "$pkg_repo" "$pkg_sec"
      TOTAL_FAILED=$((TOTAL_FAILED+1))
    fi
  fi
done < "$UPGRADE_LIST_FILE"
rm -f "$UPGRADE_LIST_FILE"

# ── Integrity stage: dpkg --audit (informational) ─────────────────────
section_header "Integrity check (dpkg --audit)"
INTEGRITY_STATUS="ok"
if command -v dpkg >/dev/null 2>&1; then
  audit_out="$(dpkg --audit 2>&1 || true)"
  if [ -n "$audit_out" ]; then
    INTEGRITY_STATUS="warn"
    echo "$audit_out" | head -5
  else
    echo "dpkg --audit clean"
  fi
else
  INTEGRITY_STATUS="warn"
  echo "dpkg not available (informational)"
fi
emit_event "integrity" "$INTEGRITY_STATUS" "" "" "" 0 "" ""

# ── Reboot detection ──────────────────────────────────────────────────
REBOOT_REQUIRED=0
if [ -f /var/run/reboot-required ]; then
  REBOOT_REQUIRED=1
fi

# ── Run end ───────────────────────────────────────────────────────────
section_header "Summary"
echo "upgraded : $TOTAL_UPGRADED"
echo "failed   : $TOTAL_FAILED"
echo "held     : $TOTAL_HELD"
echo "excluded : $TOTAL_EXCLUDED"
echo "filtered : $TOTAL_FILTERED"
echo "reboot   : $REBOOT_REQUIRED"

EXIT_CODE=0
RUN_END_STATUS="ok"
if [ "$REBOOT_REQUIRED" = 1 ]; then
  RUN_END_STATUS="reboot_required"
fi
if [ "$DRY_RUN" = 1 ]; then
  RUN_END_STATUS="dry_run"
fi
if [ "$TOTAL_UPGRADED" = 0 ] && [ "$TOTAL_FAILED" = 0 ] \
   && [ "$DRY_RUN" != 1 ] && [ "$REBOOT_REQUIRED" != 1 ]; then
  RUN_END_STATUS="idle"
fi

# Atomic last-run.json with packages[] enrichment.
RUN_ENDED_AT="$(ts)"
TMPSUM="${LATEST}.tmp.$$"
if RUN_ID_E="$RUN_ID" \
   STARTED_AT_E="$RUN_STARTED_AT" \
   ENDED_AT_E="$RUN_ENDED_AT" \
   HOST_E="$HOSTNAME_S" \
   USER_E="$USER_S" \
   BACKEND_E="$UPDATER_BACKEND" \
   DRY_RUN_E="$DRY_RUN" \
   APPLY_E="$APPLY" \
   STATUS_E="$RUN_END_STATUS" \
   UPGRADED_E="$TOTAL_UPGRADED" \
   FAILED_E="$TOTAL_FAILED" \
   HELD_E="$TOTAL_HELD" \
   EXCLUDED_E="$TOTAL_EXCLUDED" \
   FILTERED_E="$TOTAL_FILTERED" \
   REBOOT_E="$REBOOT_REQUIRED" \
   INTEGRITY_E="$INTEGRITY_STATUS" \
   PACKAGES_FILE_E="$PACKAGES_TMP" \
   python3 - > "$TMPSUM" <<'PY'
import json, os
packages = []
pf = os.environ.get("PACKAGES_FILE_E", "")
if pf and os.path.isfile(pf):
    with open(pf, "r", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if not isinstance(obj, dict):
                continue
            packages.append({
                "name":         str(obj.get("name", "")),
                "status":       str(obj.get("status", "")),
                "from_version": str(obj.get("from_version", "")),
                "to_version":   str(obj.get("to_version", "")),
                "security":     str(obj.get("security", "")),
                "source_repo":  str(obj.get("source_repo", "")),
            })

def _int(v, default=0):
    try: return int(v)
    except (TypeError, ValueError): return default

out = {
    "run_id":      os.environ["RUN_ID_E"],
    "started_at":  os.environ["STARTED_AT_E"],
    "ended_at":    os.environ["ENDED_AT_E"],
    "finished":    os.environ["ENDED_AT_E"],
    "host":        os.environ["HOST_E"],
    "user":        os.environ["USER_E"],
    "backend":     os.environ["BACKEND_E"],
    "dry_run":     _int(os.environ.get("DRY_RUN_E")),
    "apply":       _int(os.environ.get("APPLY_E")),
    "status":      os.environ["STATUS_E"],
    "integrity":   os.environ["INTEGRITY_E"],
    "reboot_required": _int(os.environ.get("REBOOT_E")),
    "totals": {
        "upgraded": _int(os.environ.get("UPGRADED_E")),
        "failed":   _int(os.environ.get("FAILED_E")),
        "held":     _int(os.environ.get("HELD_E")),
        "excluded": _int(os.environ.get("EXCLUDED_E")),
        "filtered_non_security": _int(os.environ.get("FILTERED_E")),
    },
    "packages":    packages,
}
print(json.dumps(out))
PY
then
  mv "$TMPSUM" "$LATEST"
else
  # Fallback writer (no packages[] — agents must treat absence as unknown).
  {
    printf '{'
    printf '"run_id":%s,'      "$(jsonescape "$RUN_ID")"
    printf '"started_at":%s,'  "$(jsonescape "$RUN_STARTED_AT")"
    printf '"ended_at":%s,'    "$(jsonescape "$RUN_ENDED_AT")"
    printf '"finished":%s,'    "$(jsonescape "$RUN_ENDED_AT")"
    printf '"host":%s,'        "$(jsonescape "$HOSTNAME_S")"
    printf '"user":%s,'        "$(jsonescape "$USER_S")"
    printf '"backend":%s,'     "$(jsonescape "$UPDATER_BACKEND")"
    printf '"dry_run":%s,'     "$DRY_RUN"
    printf '"apply":%s,'       "$APPLY"
    printf '"status":%s,'      "$(jsonescape "$RUN_END_STATUS")"
    printf '"integrity":%s,'   "$(jsonescape "$INTEGRITY_STATUS")"
    printf '"reboot_required":%s' "$REBOOT_REQUIRED"
    printf '}\n'
  } > "$TMPSUM" && mv "$TMPSUM" "$LATEST"
fi
rm -f "$PACKAGES_TMP"

emit_event "run_end" "$RUN_END_STATUS" "" "" "" 0 "" ""

if [ "$TOTAL_FAILED" -gt 0 ]; then
  EXIT_CODE=7
fi

logger -t system-updater -p user.info \
  "run_id=$RUN_ID upgraded=$TOTAL_UPGRADED failed=$TOTAL_FAILED held=$TOTAL_HELD reboot=$REBOOT_REQUIRED dry_run=$DRY_RUN" \
  2>/dev/null || true

echo "════════════════════════════════════════════════════════════════"
exit $EXIT_CODE
