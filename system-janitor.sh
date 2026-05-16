#!/usr/bin/env bash
# system-janitor — disk-cleanup sweep with audit-grade logging.
#
# Reclaims build artifacts, container leftovers, and stale caches across
# multiple language toolchains. Designed for unattended cron execution
# on long-lived development hosts.
#
# Defaults to universally safe operations (Docker prune of unused
# resources, regenerable language caches). Anything that touches user
# paths is opt-in via configuration.
#
# Configuration:
#   ~/.config/system-janitor/config       (XDG_CONFIG_HOME/system-janitor/config)
# or
#   --config <path>                       (override on command line)
#
# Environment variables also accepted; see README and
# examples/config.example for the full knob list.
#
# Exit codes:
#   0  success
#   1  another instance running (lock held)
#   2  integrity violation (a configured safety-floor dir was disturbed)
#   3  precondition failed (e.g., HOME unset, config syntax error)
#   4  --health: degraded (log dir exists but one or more checks failed)
#   5  --health: unknown (log dir missing — system-janitor has never run here)

set -uo pipefail

# ── Version ────────────────────────────────────────────────────────────
# Bumped whenever the agent-visible contract changes (capabilities list,
# exit codes, JSONL/report/health schemas). The capabilities array in
# do_version() below is the authoritative feature-detection surface for
# autonomous agents — they should query `--version --json` and check
# `capabilities` rather than parsing `--help`.
readonly VERSION="0.1.0"
# ── end Version ────────────────────────────────────────────────────────

# ── Default cron-safe environment ──────────────────────────────────────
export PATH="${PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
[ -z "${HOME:-}" ] && { echo "[FATAL] HOME unset" >&2; exit 3; }

# ── XDG paths ──────────────────────────────────────────────────────────
: "${XDG_CONFIG_HOME:=${HOME}/.config}"
: "${XDG_STATE_HOME:=${HOME}/.local/state}"

DEFAULT_CONFIG="${XDG_CONFIG_HOME}/system-janitor/config"

# ── CLI flags ──────────────────────────────────────────────────────────
CONFIG_FILE=""
DRY_RUN="${JANITOR_DRY_RUN:-0}"
SHOW_HELP=0
DO_REPORT=0
REPORT_JSON=0
# ── --health flag ──────────────────────────────────────────────────────
DO_HEALTH=0
# ── end --health flag ──────────────────────────────────────────────────
# ── --health-acknowledge flag ──────────────────────────────────────────
# Records a byte offset into $JANITOR_LOG_DIR/janitor.jsonl so that
# subsequent --health probes ignore any malformed lines that already
# exist in the append-only history. See do_health_acknowledge below.
DO_HEALTH_ACK=0
# ── end --health-acknowledge flag ──────────────────────────────────────
# ── --version flag ─────────────────────────────────────────────────────
DO_VERSION=0
# ── end --version flag ─────────────────────────────────────────────────
# ── --only flag ────────────────────────────────────────────────────────
# Populated by --only / --sections. When non-empty, only these section
# names run; all other action sections are skipped silently (no JSONL
# event, no log line). Order of execution follows KNOWN_SECTIONS
# declaration order, NOT user input order — keeps behavior deterministic
# regardless of argv ordering. run_start, run_end, and safety_integrity
# always run (they bracket the run; safety is a contract, not an action).
ONLY_SECTIONS=()
# ── end --only flag ────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --config=*)   CONFIG_FILE="${1#*=}"; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --report)     DO_REPORT=1; shift ;;
    # ── --health flag ──
    --health)     DO_HEALTH=1; shift ;;
    # ── end --health flag ──
    # ── --health-acknowledge flag ──
    --health-acknowledge) DO_HEALTH_ACK=1; shift ;;
    # ── end --health-acknowledge flag ──
    # ── --version flag ──
    --version)    DO_VERSION=1; shift ;;
    # ── end --version flag ──
    --json)       REPORT_JSON=1; shift ;;
    # ── --only flag ──
    --only|--sections)
      [ $# -ge 2 ] || { echo "[ERROR] $1 requires a value" >&2; exit 3; }
      IFS=',' read -r -a _only_parts <<< "$2"
      for _p in "${_only_parts[@]}"; do
        [ -n "$_p" ] && ONLY_SECTIONS+=("$_p")
      done
      shift 2 ;;
    --only=*|--sections=*)
      IFS=',' read -r -a _only_parts <<< "${1#*=}"
      for _p in "${_only_parts[@]}"; do
        [ -n "$_p" ] && ONLY_SECTIONS+=("$_p")
      done
      shift ;;
    # ── end --only flag ──
    --help|-h)    SHOW_HELP=1; shift ;;
    *) echo "[ERROR] unknown flag: $1" >&2; SHOW_HELP=1; shift ;;
  esac
done

# ── --only flag: canonical section list & validation ──────────────────
# KNOWN_SECTIONS is the source of truth for both --only validation AND the
# order of execution (the run_section dispatch lines below MUST iterate or
# match this order). When adding a new action section, add it here.
KNOWN_SECTIONS=(docker_prune go_build_cache tmp_gobuild_orphans workspace_binobj extra_cleanup nuget_http_temp)

# Validate --only BEFORE flock / log redirect: invalid input is a precondition
# failure (exit 3) and the error message belongs on the user's stderr, not
# buried inside janitor.log.
if [ ${#ONLY_SECTIONS[@]} -gt 0 ]; then
  _unknown=()
  for _s in "${ONLY_SECTIONS[@]}"; do
    _found=0
    for _k in "${KNOWN_SECTIONS[@]}"; do
      [ "$_k" = "$_s" ] && { _found=1; break; }
    done
    [ "$_found" -eq 0 ] && _unknown+=("$_s")
  done
  if [ ${#_unknown[@]} -gt 0 ]; then
    _join_unknown="" _join_valid="" _sep=""
    for _s in "${_unknown[@]}"; do
      _join_unknown+="${_sep}${_s}"; _sep=", "
    done
    _sep=""
    for _s in "${KNOWN_SECTIONS[@]}"; do
      _join_valid+="${_sep}${_s}"; _sep=", "
    done
    echo "[ERROR] unknown section(s): ${_join_unknown}. Valid: ${_join_valid}" >&2
    exit 3
  fi
fi

# _should_run_section <name> — returns 0 (run) when --only is unset OR when
# <name> is in ONLY_SECTIONS; returns 1 (skip silently) otherwise. Action
# sections gate on this; meta-sections (run_start, run_end, safety_integrity)
# do NOT consult it — they always run.
_should_run_section() {
  [ ${#ONLY_SECTIONS[@]} -eq 0 ] && return 0
  local s
  for s in "${ONLY_SECTIONS[@]}"; do
    [ "$s" = "$1" ] && return 0
  done
  return 1
}
# ── end --only flag ────────────────────────────────────────────────────

# --json is only meaningful as a modifier on --report or --health. Reject it
# standalone with exit 3 (precondition failure) so agents fail fast rather
# than silently getting a human-formatted run.
if [ "$REPORT_JSON" = 1 ] && [ "$DO_REPORT" != 1 ] && [ "$DO_HEALTH" != 1 ] && [ "$DO_VERSION" != 1 ] && [ "$DO_HEALTH_ACK" != 1 ]; then
  echo "[ERROR] --json requires --report, --health, --health-acknowledge, or --version" >&2
  exit 3
fi

if [ "$SHOW_HELP" = 1 ]; then
  cat <<'USAGE'
system-janitor — disk-cleanup sweep with audit-grade logging.

USAGE:
  system-janitor [--config <path>] [--dry-run] [--only <list>]
                 [--report [--json]] [--health [--json]]
                 [--health-acknowledge [--json]]
                 [--version [--json]] [--help]

FLAGS:
  --config <path>   Source <path> for configuration (default:
                    $XDG_CONFIG_HOME/system-janitor/config)
  --dry-run, -n     Log what would be done without modifying anything.
                    Item counts and pre-state are still reported.
  --only <list>     Run ONLY the named section(s); skip all others
                    silently (no JSONL event for skipped sections).
                    <list> is comma-separated, no spaces. Valid names:
                    docker_prune, go_build_cache, tmp_gobuild_orphans,
                    workspace_binobj, extra_cleanup, nuget_http_temp.
                    Execution order follows the script's declaration
                    order, NOT the order given on the command line.
                    run_start, run_end, and safety_integrity always run.
                    Composes with --dry-run and with JANITOR_* config
                    knobs (--only narrows the candidate set; config
                    still gates execution within it). Unknown names
                    exit 3. --sections is accepted as a synonym.
                    Intended for autonomous agents doing targeted
                    cleanups (preferred over disabling every other
                    JANITOR_* knob individually).
  --report          Print a human-readable summary of past runs from
                    $JANITOR_LOG_DIR/janitor.jsonl and exit 0. Read-only:
                    does not acquire the lock or write any log file, so
                    it is safe to run while a cleanup is in progress.
                    Historical section aliases are merged; obsolete
                    sections are reported separately.
  --health          Probe the audit trail and exit with a status code
                    summarizing trust in the tool's state. Read-only:
                    does not acquire the lock, does not create the log
                    dir, does not write any log file. Exit codes:
                      0  healthy (all checks pass)
                      4  degraded (log dir exists, one or more
                         downstream checks failed)
                      5  unknown (log dir missing — never run here)
                    See EXIT CODES below. Pair with --json for a
                    machine-readable probe response.
  --health-acknowledge
                    Record the current size of janitor.jsonl as a
                    baseline so future --health probes ignore any
                    malformed lines that already exist in the
                    append-only history. Writes a single integer byte
                    offset to $JANITOR_LOG_DIR/.health-baseline
                    atomically. Lines whose start-byte-offset is below
                    the baseline are excluded from the jsonl_parses
                    check (other checks unaffected). This is the
                    agent's recovery interface: after triaging a
                    historical issue, acknowledge it and --health
                    will report healthy again until a new issue
                    appears. Read-only with respect to janitor.jsonl /
                    last-run.json; safe to run concurrently with a
                    cleanup. Pair with --json for a machine-readable
                    response.
  --json            With --report, emit the summary as a single JSON
                    object (pretty-printed, indent=2) instead of the
                    human table. With --health, emit the probe response
                    as JSON (no ANSI, no Unicode glyphs) with keys
                    status, exit_code, generated_at, log_dir, checks[].
                    With --health-acknowledge, emit a JSON object with
                    keys acknowledged, baseline_bytes, excluded_events.
                    With --version, emit a JSON object with keys name,
                    version, capabilities[] (alphabetically sorted) so
                    agents can feature-detect before invoking.
                    Schemas are documented in the README. Errors out
                    (exit 3) if used without --report, --health,
                    --health-acknowledge, or --version.
  --version         Print the script version and exit 0. Read-only:
                    does not acquire the lock, does not create the log
                    dir, does not require HOME or any state. Pair with
                    --json for a machine-readable capabilities probe
                    (preferred by autonomous agents over parsing --help).
  --help, -h        Show this help and exit.

CONFIG (sourced as bash):
  JANITOR_WORKSPACE_DIRS         colon-separated dirs scanned for bin/obj
                                 (e.g., $HOME/sandbox:$HOME/projects)
  JANITOR_EXTRA_CLEANUP_DIRS     colon-separated dirs to remove entirely
  JANITOR_SAFETY_FLOOR_DIRS      colon-separated dirs whose inode+size
                                 must NOT change during the run
  JANITOR_DOCKER_PRUNE           yes/no (default: yes if docker present)
  JANITOR_DOCKER_VOLUMES         yes/no (default: yes; passes --volumes)
  JANITOR_GO_CLEAN               yes/no (default: yes if go present)
  JANITOR_TMP_GOBUILD_ORPHANS    yes/no (default: yes)
  JANITOR_NUGET_CLEAN            yes/no (default: yes if dotnet present)
  JANITOR_DRY_RUN                0/1 (default: 0; 1 ⇒ implicit --dry-run)
  JANITOR_LOG_DIR                state directory
                                 (default: $XDG_STATE_HOME/janitor)

EXAMPLES:
  # Cron entry — Sunday 03:17 weekly:
  17 3 * * 0 $HOME/.local/bin/system-janitor

  # Dry-run preview:
  system-janitor --dry-run

  # Targeted cleanup (agent idiom): only run Docker prune
  system-janitor --only docker_prune --dry-run
  system-janitor --only docker_prune,go_build_cache

  # Machine-readable run summary (preferred by agents over parsing logs):
  system-janitor --report --json

  # Feature-detection probe (preferred by agents over parsing --help):
  system-janitor --version --json

  # Recover --health from a historical malformed JSONL line:
  system-janitor --health                  # → degraded (exit 4)
  system-janitor --health-acknowledge      # baseline current EOF
  system-janitor --health                  # → healthy  (exit 0)

LOGS:
  $JANITOR_LOG_DIR/janitor.log       human-readable
  $JANITOR_LOG_DIR/janitor.jsonl     one JSON event per section (append-only)
  $JANITOR_LOG_DIR/last-run.json     latest summary (atomic write-temp-rename)
  $JANITOR_LOG_DIR/.health-baseline  byte offset for --health (see
                                     --health-acknowledge)
  Default JANITOR_LOG_DIR: $XDG_STATE_HOME/janitor (~/.local/state/janitor).

STATUS ENUM (janitor.jsonl "status" field):
  ok                       action ran successfully (or section legitimately
                           had nothing to do — applies to default sections)
  idle                     opt-in section ran successfully but produced no
                           work (items=0, freed=0). Signals a likely stale
                           config; consecutive idle runs are surfaced via
                           --report's idle_streaks output. Only emitted for
                           opt-in sections (workspace_binobj, extra_cleanup).
  warn                     action exited non-zero; see "note" field
  dry_run                  --dry-run; action was not executed
  violated_missing         a safety-floor dir disappeared during the run
  violated_inode_changed   a safety-floor dir's inode changed during the run

EXIT CODES:
  0   success (default run or --health healthy)
  1   another instance running (lock held)
  2   integrity violation (a configured safety-floor dir was disturbed)
  3   precondition failed (e.g., HOME unset, config syntax error, or
      --json used without --report, --health, --health-acknowledge,
      or --version)
  4   --health: degraded (log dir exists, but one or more downstream
      checks failed — JSONL malformed, integrity violated, idle streak,
      etc.). The tool itself is usable; trust the audit trail
      conditionally.
  5   --health: unknown (log dir missing or last-run.json absent —
      system-janitor has never run on this host). Not a failure;
      just no signal yet.

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
JANITOR_WORKSPACE_DIRS="${JANITOR_WORKSPACE_DIRS:-}"
JANITOR_EXTRA_CLEANUP_DIRS="${JANITOR_EXTRA_CLEANUP_DIRS:-}"
JANITOR_SAFETY_FLOOR_DIRS="${JANITOR_SAFETY_FLOOR_DIRS:-}"
JANITOR_DOCKER_PRUNE="${JANITOR_DOCKER_PRUNE:-yes}"
JANITOR_DOCKER_VOLUMES="${JANITOR_DOCKER_VOLUMES:-yes}"
JANITOR_GO_CLEAN="${JANITOR_GO_CLEAN:-yes}"
JANITOR_TMP_GOBUILD_ORPHANS="${JANITOR_TMP_GOBUILD_ORPHANS:-yes}"
JANITOR_NUGET_CLEAN="${JANITOR_NUGET_CLEAN:-yes}"
JANITOR_LOG_DIR="${JANITOR_LOG_DIR:-${XDG_STATE_HOME}/janitor}"

# ── Schema history: section aliases & obsolete sections ───────────────
# Historical section aliases. Keys are old (historical) section names; values
# are the current canonical section name. --report merges old events under
# the canonical name. Obsolete sections (no current equivalent) go in
# OBSOLETE_SECTIONS instead.
#
# These live above do_report() (which consumes them) but are conceptually
# part of the section-dispatch contract below — when renaming a section,
# update both this map AND the run_section line, and document the change in
# .github/copilot-instructions.md ("Schema history & section aliases").
declare -A SECTION_ALIASES=(
  ["copilot_integrity"]="safety_integrity"
)
OBSOLETE_SECTIONS=("sandbox_binobj" "azure_openai_cli_dist" "user_cache_copilot")

# ── Read-only report (must run BEFORE mkdir/flock/exec-redirect) ──────
do_report() {
  local jsonl="${JANITOR_LOG_DIR}/janitor.jsonl"
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"

  # Build JSON for the alias map and obsolete list from the Bash structures
  # above so there's a single source of truth.
  local aliases_json="{" first=1 k
  for k in "${!SECTION_ALIASES[@]}"; do
    [ "$first" = 1 ] || aliases_json+=","
    first=0
    aliases_json+="\"${k}\":\"${SECTION_ALIASES[$k]}\""
  done
  aliases_json+="}"
  local obsolete_json="[" o
  first=1
  for o in "${OBSOLETE_SECTIONS[@]}"; do
    [ "$first" = 1 ] || obsolete_json+=","
    first=0
    obsolete_json+="\"${o}\""
  done
  obsolete_json+="]"

  REPORT_MODE="$mode" REPORT_LOG_DIR="$JANITOR_LOG_DIR" REPORT_JSONL="$jsonl" \
    JANITOR_SECTION_ALIASES_JSON="$aliases_json" \
    JANITOR_OBSOLETE_SECTIONS_JSON="$obsolete_json" \
    python3 - <<'PY'
import json, os, sys, datetime
from collections import defaultdict, OrderedDict

mode    = os.environ["REPORT_MODE"]
log_dir = os.environ["REPORT_LOG_DIR"]
path    = os.environ["REPORT_JSONL"]

ALIASES  = json.loads(os.environ.get("JANITOR_SECTION_ALIASES_JSON", "{}"))
OBSOLETE = set(json.loads(os.environ.get("JANITOR_OBSOLETE_SECTIONS_JSON", "[]")))

generated_at = datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")

def emit_json(obj):
    sys.stdout.write(json.dumps(obj, indent=2))
    sys.stdout.write("\n")

# ── Empty / missing JSONL ─────────────────────────────────────────────
if not os.path.isfile(path):
    if mode == "json":
        emit_json({
            "log_dir": log_dir,
            "jsonl_path": path,
            "generated_at": generated_at,
            "total_events": 0,
            "total_runs": 0,
            "real_runs": 0,
            "dry_runs": 0,
            "date_range": {"first": None, "last": None},
            "total_freed_kb": 0,
            "total_freed_bytes": 0,
            "per_section": [],
            "obsolete_sections": [],
            "most_recent_run": None,
            "data_quality": {"invalid_lines": 0, "examples": []},
            "idle_streaks": [],
        })
    else:
        print("system-janitor — report")
        print(f"  log dir : {log_dir}")
        print()
        print(f"no runs found at {path}")
    sys.exit(0)

# ── Parse ─────────────────────────────────────────────────────────────
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

# Deterministic run-id ordering (first-seen).
run_ids = []
seen_run_ids = set()
for ev in events:
    rid = ev.get("run_id")
    if rid and rid not in seen_run_ids:
        seen_run_ids.add(rid)
        run_ids.append(rid)

timestamps = sorted(ev.get("ts", "") for ev in events if ev.get("ts"))
ts_first = timestamps[0]  if timestamps else None
ts_last  = timestamps[-1] if timestamps else None

dry_run_ids = set()
real_run_ids = set()
for ev in events:
    if ev.get("section") == "run_start":
        rid = ev.get("run_id")
        note = ev.get("note", "") or ""
        if "dry_run=1" in note:
            dry_run_ids.add(rid)
        else:
            real_run_ids.add(rid)
unknown_run_ids = set(run_ids) - dry_run_ids - real_run_ids
real_run_ids |= unknown_run_ids  # treat un-tagged as real for totals

# Per-event byte extraction. JSONL events currently carry `freed_kb` only,
# but we read `freed_bytes` first when present so a future schema bump that
# adds `freed_bytes` to events flows through without code change. Bytes are
# the canonical unit: we compute `_bytes` totals directly from per-event
# values rather than multiplying a kb total by 1024, so the bytes path is
# independent of the kb path (no shared rounding).
def _event_bytes(ev):
    try:
        fb = ev.get("freed_bytes")
        if fb is not None:
            return int(fb)
    except (TypeError, ValueError):
        pass
    try:
        return int(ev.get("freed_kb") or 0) * 1024
    except (TypeError, ValueError):
        return 0

# Per-section aggregation.
per_section = defaultdict(lambda: {"runs": set(), "freed": 0, "freed_bytes": 0, "items": 0, "status": defaultdict(int)})
obsolete_section = defaultdict(lambda: {"runs": set(), "freed": 0, "freed_bytes": 0, "items": 0,
                                        "status": defaultdict(int),
                                        "first_seen": None, "last_seen": None})
SKIP = {"run_start", "run_end", "safety_integrity"}
for ev in events:
    sec = ev.get("section")
    if not sec:
        continue
    # Remap historical aliases FIRST so all downstream grouping (including
    # any future per-section computation) sees the canonical name.
    sec = ALIASES.get(sec, sec)
    if sec in OBSOLETE:
        rid = ev.get("run_id")
        ts  = ev.get("ts") or ""
        p = obsolete_section[sec]
        p["runs"].add(rid)
        try:
            p["freed"] += int(ev.get("freed_kb") or 0)
        except (TypeError, ValueError):
            pass
        p["freed_bytes"] += _event_bytes(ev)
        try:
            p["items"] += int(ev.get("items") or 0)
        except (TypeError, ValueError):
            pass
        p["status"][ev.get("status", "?")] += 1
        if ts:
            if p["first_seen"] is None or ts < p["first_seen"]:
                p["first_seen"] = ts
            if p["last_seen"] is None or ts > p["last_seen"]:
                p["last_seen"] = ts
        continue
    if sec in SKIP:
        continue
    rid = ev.get("run_id")
    p = per_section[sec]
    p["runs"].add(rid)
    if rid in real_run_ids:
        try:
            p["freed"] += int(ev.get("freed_kb") or 0)
        except (TypeError, ValueError):
            pass
        p["freed_bytes"] += _event_bytes(ev)
        try:
            p["items"] += int(ev.get("items") or 0)
        except (TypeError, ValueError):
            pass
    p["status"][ev.get("status", "?")] += 1

sorted_secs = sorted(per_section.items(), key=lambda kv: -kv[1]["freed"])
sorted_obsolete = sorted(obsolete_section.items(),
                         key=lambda kv: (kv[1]["last_seen"] or "", kv[0]),
                         reverse=True)

# ── Idle streaks ──────────────────────────────────────────────────────
# For each section, walk its events in chronological order (real runs
# only — exclude dry_run runs). Find the longest TRAILING run of
# consecutive "idle" events. For backward compat with historical events
# emitted before the "idle" status existed, also count "ok" events with
# freed_kb==0 and items==0 toward the trailing streak. Also locate the
# most recent productive run (freed_kb>0 OR items>0). Sections with a
# trailing streak >= 2 are surfaced; one idle run is normal noise, two
# starts to suggest a stale config or a dead daemon. Applies to ALL
# sections (not just opt-in), so an agent watching e.g. docker_prune
# go idle for many runs notices the docker daemon died.
def _intify(v):
    try: return int(v or 0)
    except (TypeError, ValueError): return 0

section_events = defaultdict(list)
for ev in events:
    sec = ev.get("section")
    if not sec:
        continue
    if ev.get("run_id") not in real_run_ids:
        continue
    # Apply schema-history rules so idle_streaks is consistent with
    # per_section: fold aliased names into the canonical name FIRST (so
    # historical names that map to a meta-section like safety_integrity
    # are correctly skipped below), then drop meta-sections and obsolete
    # sections (the latter are surfaced under obsolete_sections).
    sec = ALIASES.get(sec, sec)
    if sec in SKIP or sec in OBSOLETE:
        continue
    section_events[sec].append(ev)

idle_streaks = []
for sec, evs in section_events.items():
    evs_sorted = sorted(evs, key=lambda e: e.get("ts", ""))
    last_productive = None
    trailing = 0
    for ev in evs_sorted:
        freed = _intify(ev.get("freed_kb"))
        items = _intify(ev.get("items"))
        status = ev.get("status", "")
        productive = (freed > 0 or items > 0)
        if productive:
            last_productive = {"run_id": ev.get("run_id"), "ts": ev.get("ts")}
            trailing = 0
        elif status == "idle" or (status == "ok" and freed == 0 and items == 0):
            trailing += 1
        else:
            # warn / violated_* / unknown — break the streak without
            # claiming the section was productive.
            trailing = 0
    if trailing >= 2:
        idle_streaks.append({
            "section": sec,
            "consecutive_idle_runs": trailing,
            "last_productive_run": last_productive,
        })
idle_streaks.sort(key=lambda d: -d["consecutive_idle_runs"])

total_freed = 0
total_freed_bytes = 0
for ev in events:
    if ev.get("run_id") in real_run_ids and ev.get("section") == "run_end":
        try:
            total_freed += int(ev.get("freed_kb") or 0)
        except (TypeError, ValueError):
            pass
# Bytes are canonical and computed independently of `total_freed` (per-event,
# bytes-aware). We sum across the SAME action events that fed per_section so
# total_freed_bytes == sum of per_section[*].freed_bytes (cross-source check
# in tests/smoke.sh asserts this). This intentionally diverges from
# total_freed_kb, which folds the `freed_kb` field of run_end summary events
# — historically that should equal the sum of section freed_kb values, but
# computing bytes from kb*1024 of run_end would propagate any drift; instead
# we sum from action events for byte-accurate accounting.
for sec, p in per_section.items():
    total_freed_bytes += p["freed_bytes"]

# Most recent run (latest run_end ts).
last_end = None
for ev in events:
    if ev.get("section") == "run_end":
        if last_end is None or (ev.get("ts", "") > last_end.get("ts", "")):
            last_end = ev

# Integrity status for the most-recent run.
mr_safety = None
mr_dry = None
if last_end:
    rid = last_end.get("run_id")
    for ev in events:
        if ev.get("run_id") == rid and ev.get("section") == "safety_integrity":
            mr_safety = ev.get("status")
            break
    mr_dry = 1 if rid in dry_run_ids else 0

# Unfinished runs / integrity violations (used by both modes).
ended = {ev.get("run_id") for ev in events if ev.get("section") == "run_end"}
unfinished = [r for r in run_ids if r not in ended]
violations = [ev for ev in events
              if ev.get("section") == "safety_integrity"
              and ev.get("status") not in ("ok", None)]

# ── JSON mode ─────────────────────────────────────────────────────────
if mode == "json":
    out = OrderedDict()
    out["log_dir"]      = log_dir
    out["jsonl_path"]   = path
    out["generated_at"] = generated_at
    out["total_events"] = len(events)
    out["total_runs"]   = len(run_ids)
    out["real_runs"]    = len(real_run_ids)
    out["dry_runs"]     = len(dry_run_ids)
    out["date_range"]   = {"first": ts_first, "last": ts_last}
    out["total_freed_kb"] = total_freed
    out["total_freed_bytes"] = total_freed_bytes
    out["per_section"] = [
        {
            "name": sec,
            "runs": len(p["runs"]),
            "freed_kb_total": p["freed"],
            "freed_bytes": p["freed_bytes"],
            "items_total": p["items"],
            "status_counts": dict(sorted(p["status"].items())),
        }
        for sec, p in sorted_secs
    ]
    out["obsolete_sections"] = [
        {
            "name": sec,
            "runs": len(p["runs"]),
            "freed_kb_total": p["freed"],
            "freed_bytes": p["freed_bytes"],
            "items_total": p["items"],
            "status_counts": dict(sorted(p["status"].items())),
            "first_seen": p["first_seen"],
            "last_seen":  p["last_seen"],
        }
        for sec, p in sorted_obsolete
    ]
    if last_end:
        out["most_recent_run"] = {
            "run_id":           last_end.get("run_id"),
            "finished":         last_end.get("ts"),
            "freed_kb":         int(last_end.get("freed_kb") or 0),
            "freed_bytes":      _event_bytes(last_end),
            "safety_integrity": mr_safety,
            "dry_run":          mr_dry,
        }
    else:
        out["most_recent_run"] = None
    out["data_quality"] = {
        "invalid_lines": len(malformed),
        "examples": [{"line": ln, "error": err} for ln, err in malformed[:3]],
    }
    out["idle_streaks"] = idle_streaks
    emit_json(out)
    sys.exit(0)

# ── Text mode ─────────────────────────────────────────────────────────
print("system-janitor — report")
print(f"  log dir : {log_dir}")
if not events:
    print(f"  events  : 0")
    print()
    print(f"no parseable events in {path}")
    if malformed:
        print()
        print("Data-quality issues:")
        for ln, err in malformed:
            print(f"  line {ln}: {err}")
    sys.exit(0)

ts_min = ts_first[:10] if ts_first else "?"
ts_max = ts_last[:10]  if ts_last  else "?"
print(f"  events  : {len(events)} (across {len(run_ids)} runs)")
print(f"  range   : {ts_min} .. {ts_max}")
print(f"  real runs: {len(real_run_ids)}    dry runs: {len(dry_run_ids)}")
print()

print("Per-section totals (freed_kb/items count real runs only):")
print(f"  {'section':<22} {'runs':>5} {'freed_kb':>14} {'items':>8}   status")
for sec, p in sorted_secs:
    status_str = ",".join(f"{k}:{v}" for k, v in sorted(p["status"].items()))
    print(f"  {sec:<22} {len(p['runs']):>5} {p['freed']:>14} {p['items']:>8}   {status_str}")

if sorted_obsolete:
    print()
    print("Obsolete sections (from prior script version, no current equivalent):")
    for sec, p in sorted_obsolete:
        last = (p["last_seen"] or "?")[:10]
        print(f"  {sec:<26} {len(p['runs'])} runs    last seen {last}")

gb = total_freed / (1024 * 1024)
print()
print(f"Total reclaimed: {total_freed} KB ({gb:.2f} GB)")

if idle_streaks:
    print()
    print("Idle sections (no work in last N consecutive real runs):")
    for entry in idle_streaks:
        lp = entry["last_productive_run"]
        lp_str = "never" if lp is None else f"{lp.get('run_id','?')} ({lp.get('ts','?')})"
        print(f"  {entry['section']:<22} idle for {entry['consecutive_idle_runs']} runs   last productive: {lp_str}")

print()
print("Most recent run:")
if last_end:
    print(f"  {last_end.get('run_id','?')}   {last_end.get('ts','?')}   "
          f"freed={last_end.get('freed_kb',0)} KB   {last_end.get('note','')}")
else:
    last_ev = events[-1]
    print(f"  {last_ev.get('run_id','?')}   {last_ev.get('ts','?')}   (no run_end event)")

print()
print("Data-quality issues:")
issues = []
if malformed:
    issues.append(f"  {len(malformed)} malformed line(s):")
    for ln, err in malformed[:5]:
        issues.append(f"    line {ln}: {err[:60]}")
    if len(malformed) > 5:
        issues.append(f"    ... and {len(malformed) - 5} more")
if unfinished:
    issues.append(f"  {len(unfinished)} run(s) with no run_end event:")
    for r in unfinished[:5]:
        issues.append(f"    {r}")
if violations:
    issues.append(f"  {len(violations)} integrity violation(s):")
    for ev in violations[:5]:
        issues.append(f"    {ev.get('run_id','?')} status={ev.get('status')} note={ev.get('note','')}")
if issues:
    for line in issues:
        print(line)
else:
    print("  (none)")
PY
}

if [ "$DO_REPORT" = 1 ]; then
  do_report
  exit 0
fi

# ── --version flag ─────────────────────────────────────────────────────
# Read-only capability probe. Like --report / --health, this runs BEFORE
# flock, BEFORE mkdir of LOG_DIR, and BEFORE the exec >>"$LOG" redirect.
# It must not create or write to anything. Plain text on stdout, or a
# JSON object when paired with --json. Exit 0 always (no failure modes).
#
# The capabilities[] array is the agent-facing feature-detection surface:
# agents should query `--version --json` and check `capabilities` rather
# than parsing `--help`. Keep the list alphabetically sorted (the smoke
# test locks this in) so the JSON output is stable across runs.
do_version() {
  if [ "$REPORT_JSON" = 1 ]; then
    python3 - <<PY
import json
print(json.dumps({
    "name": "system-janitor",
    "version": "${VERSION}",
    # NOTE: when adding a new agent-visible feature (new flag, new
    # output field, new JSONL status, new schema file, …) you MUST add a
    # string here AND add a probe in the "capability completeness" stage
    # of tests/smoke.sh. The smoke stage proves every claimed capability
    # actually works; this list is what agents feature-detect against.
    "capabilities": sorted([
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
        "version-json",
    ]),
}, indent=2))
PY
  else
    printf 'system-janitor %s\n' "$VERSION"
  fi
}

if [ "$DO_VERSION" = 1 ]; then
  do_version
  exit 0
fi
# ── end --version flag ─────────────────────────────────────────────────

# ── --health flag ──────────────────────────────────────────────────────
# Read-only health probe. Like --report, this runs BEFORE flock, BEFORE
# mkdir of LOG_DIR, and BEFORE the exec >>"$LOG" redirect. It must not
# write to or create anything. Exit codes:
#   0  healthy   — all checks pass
#   4  degraded  — log dir exists, but one or more downstream checks failed
#   5  unknown   — log dir missing OR last-run.json absent (never ran here)
do_health() {
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"
  local log_dir="$JANITOR_LOG_DIR"
  local jsonl="${log_dir}/janitor.jsonl"
  local last_run="${log_dir}/last-run.json"
  local baseline_file="${log_dir}/.health-baseline"

  HEALTH_MODE="$mode" \
    HEALTH_LOG_DIR="$log_dir" \
    HEALTH_JSONL="$jsonl" \
    HEALTH_LAST_RUN="$last_run" \
    HEALTH_BASELINE_FILE="$baseline_file" \
    python3 - <<'PY'
import json, os, sys, datetime

mode         = os.environ["HEALTH_MODE"]
log_dir      = os.environ["HEALTH_LOG_DIR"]
jsonl        = os.environ["HEALTH_JSONL"]
last_run     = os.environ["HEALTH_LAST_RUN"]
baseline_file = os.environ["HEALTH_BASELINE_FILE"]

generated_at = datetime.datetime.now().astimezone().strftime("%Y-%m-%dT%H:%M:%S%z")

checks = []  # list of {"name","ok","detail"}

def add(name, ok, detail=None):
    checks.append({"name": name, "ok": bool(ok), "detail": detail})

# check.log_dir_exists
log_dir_ok = os.path.isdir(log_dir)
add("log_dir_exists", log_dir_ok, log_dir if log_dir_ok else f"{log_dir} (missing)")

# Read baseline (byte offset). Default 0. Bad/negative values fall back to 0.
# The baseline file is written atomically by --health-acknowledge; lines
# whose start byte offset is < baseline are excluded from jsonl_parses
# (the agent has acknowledged those historical events).
baseline = 0
if log_dir_ok and os.path.isfile(baseline_file):
    try:
        with open(baseline_file, "r", errors="replace") as bf:
            baseline = int((bf.read().strip() or "0"))
        if baseline < 0:
            baseline = 0
    except Exception:
        baseline = 0

# check.jsonl_present  (counts ALL events; baseline does NOT affect it)
jsonl_ok = False
jsonl_detail = None
event_count = 0
lines = []           # decoded text lines (with newline)
line_offsets = []    # byte offset of each line start
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
        jsonl_detail = "janitor.jsonl missing"
else:
    jsonl_detail = "log dir missing"
add("jsonl_present", jsonl_ok, jsonl_detail)

# Compute baseline-applied slice: lines whose start byte offset is >= baseline.
# If baseline lands mid-line, that line is excluded (its start offset < baseline);
# the next line starts >= baseline and is included — this is the snap-forward
# behavior described in the design (no half-parsed lines).
parse_start_idx = 0
if baseline > 0:
    parse_start_idx = len(line_offsets)
    for i, off in enumerate(line_offsets):
        if off >= baseline:
            parse_start_idx = i
            break
excluded_events = sum(1 for l in lines[:parse_start_idx] if l.strip())

# check.jsonl_parses  (honors baseline)
parses_ok = False
parses_detail = None
malformed = []
if jsonl_ok:
    iter_slice = lines[parse_start_idx:]
    iter_base_lineno = parse_start_idx  # 0-indexed; we report 1-indexed below
    for j, raw in enumerate(iter_slice):
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if not isinstance(obj, dict):
                raise ValueError("not an object")
        except Exception as e:
            malformed.append((iter_base_lineno + j + 1, str(e)[:100]))
    if not malformed:
        parses_ok = True
        considered = event_count - excluded_events
        if baseline > 0:
            if considered == 0:
                parses_detail = (
                    f"0 invalid lines (baseline={baseline} bytes; "
                    f"all {excluded_events} events excluded — "
                    f"append-only history acknowledged)"
                )
            else:
                parses_detail = (
                    f"0 invalid lines among {considered} events checked "
                    f"(baseline={baseline} bytes, {excluded_events} events excluded)"
                )
        else:
            parses_detail = f"0 invalid lines ({event_count} events checked)"
    else:
        ln, err = malformed[0]
        n = len(malformed)
        noun = f"{n} invalid line{'s' if n > 1 else ''}"
        considered = event_count - excluded_events
        if baseline > 0:
            parses_detail = (
                f"{noun} since baseline "
                f"(line {ln}, {considered} events checked, "
                f"{excluded_events} events excluded)"
            )
        else:
            parses_detail = f"{noun} (line {ln}: {err})"
else:
    parses_detail = "skipped: jsonl_present failed"
add("jsonl_parses", parses_ok, parses_detail)

# check.last_run_parses
last_parses_ok = False
last_parses_detail = None
last_data = None
if not log_dir_ok:
    last_parses_detail = "skipped: log dir missing"
elif not os.path.isfile(last_run):
    last_parses_detail = "last-run.json missing"
else:
    try:
        with open(last_run, "r", errors="replace") as fh:
            last_data = json.load(fh)
        last_parses_ok = True
    except Exception as e:
        last_parses_detail = f"parse error: {str(e)[:100]}"
add("last_run_parses", last_parses_ok, last_parses_detail)

# check.last_run_integrity_ok
integrity_ok = False
integrity_detail = None
section_count = None
if last_data is None:
    integrity_detail = "skipped: last_run_parses failed"
else:
    si = last_data.get("safety_integrity")
    secs = last_data.get("sections")
    if isinstance(secs, list):
        section_count = len(secs)
    if si == "ok":
        integrity_ok = True
        if section_count is not None:
            integrity_detail = f"safety_integrity=ok, {section_count} sections"
        else:
            integrity_detail = "safety_integrity=ok"
    else:
        integrity_detail = f"safety_integrity={si!r}"
add("last_run_integrity_ok", integrity_ok, integrity_detail)

# check.last_run_parses_sections
# Backward compat: a last-run.json written before the sections enrichment
# (schema "v0.1") legitimately lacks `sections`. Agents reading historical
# files must not flip degraded over that. Treat missing key as "skipped"
# (ok=True), malformed shape as a real failure.
sections_ok = True
sections_detail = None
if last_data is None:
    sections_detail = "skipped: last_run_parses failed"
elif "sections" not in last_data:
    sections_detail = "skipped: schema older than v0.2 (no sections[])"
else:
    secs = last_data.get("sections")
    if not isinstance(secs, list):
        sections_ok = False
        sections_detail = f"sections is not an array (got {type(secs).__name__})"
    else:
        bad = []
        for i, s in enumerate(secs):
            if not isinstance(s, dict):
                bad.append((i, "not an object"))
                continue
            missing = [k for k in ("name", "status", "items", "freed_bytes") if k not in s]
            if missing:
                bad.append((i, f"missing {missing}"))
                continue
            if not isinstance(s.get("items"), int) or not isinstance(s.get("freed_bytes"), int):
                bad.append((i, "items/freed_bytes not int"))
        if bad:
            sections_ok = False
            idx, err = bad[0]
            sections_detail = f"{len(bad)} malformed entr{'ies' if len(bad)>1 else 'y'} (index {idx}: {err})"
        else:
            sections_detail = f"{len(secs)} section{'s' if len(secs)!=1 else ''} well-formed"
add("last_run_parses_sections", sections_ok, sections_detail)

# check.no_long_idle_streaks (threshold: < 5)
# Reuses the same idle-streak logic as do_report. Folds aliases, drops
# meta + obsolete sections, counts trailing consecutive idle (or zero-work
# ok) events on REAL runs only.
from collections import defaultdict

ALIASES = {"copilot_integrity": "safety_integrity"}
OBSOLETE = {"sandbox_binobj", "azure_openai_cli_dist", "user_cache_copilot"}
SKIP = {"run_start", "run_end", "safety_integrity"}

events = []
if parses_ok:
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if isinstance(obj, dict):
                events.append(obj)
        except Exception:
            pass

# Classify dry vs real run ids.
dry_run_ids = set()
real_run_ids = set()
run_ids_seen = []
seen_set = set()
for ev in events:
    rid = ev.get("run_id")
    if rid and rid not in seen_set:
        seen_set.add(rid)
        run_ids_seen.append(rid)
    if ev.get("section") == "run_start":
        note = ev.get("note", "") or ""
        if "dry_run=1" in note:
            dry_run_ids.add(rid)
        else:
            real_run_ids.add(rid)
real_run_ids |= (set(run_ids_seen) - dry_run_ids - real_run_ids)

def _intify(v):
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0

section_events = defaultdict(list)
for ev in events:
    sec = ev.get("section")
    if not sec:
        continue
    if ev.get("run_id") not in real_run_ids:
        continue
    sec = ALIASES.get(sec, sec)
    if sec in SKIP or sec in OBSOLETE:
        continue
    section_events[sec].append(ev)

max_streak = 0
max_section = None
for sec, evs in section_events.items():
    evs_sorted = sorted(evs, key=lambda e: e.get("ts", ""))
    trailing = 0
    for ev in evs_sorted:
        freed = _intify(ev.get("freed_kb"))
        items = _intify(ev.get("items"))
        status = ev.get("status", "")
        productive = (freed > 0 or items > 0)
        if productive:
            trailing = 0
        elif status == "idle" or (status == "ok" and freed == 0 and items == 0):
            trailing += 1
        else:
            trailing = 0
    if trailing > max_streak:
        max_streak = trailing
        max_section = sec

streak_ok = True
streak_detail = "no real runs to evaluate"
if section_events:
    streak_ok = max_streak < 5
    if max_section is None:
        streak_detail = "max consecutive_idle=0"
    else:
        streak_detail = f"max consecutive_idle={max_streak} ({max_section})"
elif not parses_ok:
    streak_detail = "skipped: jsonl_parses failed"
add("no_long_idle_streaks", streak_ok, streak_detail)

# ── Determine overall status / exit code ─────────────────────────────
# unknown: log dir missing, OR last-run.json missing (never ran here)
# degraded: log dir exists, but >=1 downstream check failed
# healthy: all checks ok
last_run_missing = log_dir_ok and not os.path.isfile(last_run)
if not log_dir_ok or last_run_missing:
    status = "unknown"
    exit_code = 5
else:
    failed = [c for c in checks if not c["ok"]]
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
    print(f"system-janitor health: {status} (exit {exit_code})")
    name_w = max(len(c["name"]) for c in checks)
    for c in checks:
        glyph = "✓" if c["ok"] else "✗"
        detail = "" if c["detail"] is None else c["detail"]
        print(f"  {glyph} {c['name']:<{name_w}}  {detail}")

sys.exit(exit_code)
PY
}

if [ "$DO_HEALTH" = 1 ]; then
  do_health
  exit $?
fi
# ── end --health flag ──────────────────────────────────────────────────

# ── --health-acknowledge flag ──────────────────────────────────────────
# Records the current size of janitor.jsonl as a byte-offset baseline in
# $JANITOR_LOG_DIR/.health-baseline. Future --health probes ignore any
# lines whose start byte offset is below this baseline when running the
# jsonl_parses check — i.e. an agent acknowledges that it has triaged
# all currently-present events and only NEW malformed lines should
# degrade health.
#
# Like --report / --health, this runs BEFORE flock, BEFORE mkdir of
# LOG_DIR (it creates only the baseline file, not the dir itself if it
# doesn't already exist — but it does need the dir to exist to write
# the file, so it creates it if missing), and BEFORE the exec >>"$LOG"
# redirect. The write is atomic (tmp+rename), so a concurrent --health
# probe either sees the old baseline or the new one, never a torn read.
do_health_acknowledge() {
  local mode="text"
  [ "$REPORT_JSON" = 1 ] && mode="json"
  local log_dir="$JANITOR_LOG_DIR"
  local jsonl="${log_dir}/janitor.jsonl"
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

# Determine the current size of janitor.jsonl (0 if missing).
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

# Ensure the parent dir exists so we can write the baseline. This is the
# one case where --health-acknowledge will create LOG_DIR — it's intentional:
# acknowledging on a fresh host establishes baseline=0 atomically.
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
    try:
        os.unlink(tmp)
    except OSError:
        pass
    sys.exit(3)

if mode == "json":
    out = {
        "acknowledged": True,
        "baseline_bytes": size,
        "excluded_events": event_count,
    }
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

# Augment PATH with common toolchain locations (cron-safe).
for d in "${HOME}/.dotnet" "${HOME}/.local/bin" "${HOME}/go/bin" /snap/bin; do
  [ -d "$d" ] && case ":${PATH}:" in *":${d}:"*) ;; *) PATH="${d}:${PATH}";; esac
done
export PATH

# ── Paths and identifiers ──────────────────────────────────────────────
LOG_DIR="$JANITOR_LOG_DIR"
LOG="${LOG_DIR}/janitor.log"
JSONL="${LOG_DIR}/janitor.jsonl"
LATEST="${LOG_DIR}/last-run.json"
LOCK="${LOG_DIR}/janitor.lock"
mkdir -p "$LOG_DIR"

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo deadbeef)"
# Per-run accumulator for last-run.json `sections` array. One JSON line per
# section that emits an event (excluding meta-events run_start / run_end).
# Assembled into the final last-run.json at run_end via a python heredoc, then
# removed. Kept in $LOG_DIR (not /tmp) so it shares the same atomicity domain
# as last-run.json itself.
SECTIONS_TMP="${LOG_DIR}/.sections.${RUN_ID}.$$"
: > "$SECTIONS_TMP"
RUN_STARTED_AT=""
RUN_ENDED_AT=""
HOSTNAME_S="$(hostname)"
USER_S="${USER:-$(id -un)}"

# ── Single-instance lock ───────────────────────────────────────────────
exec 9>"$LOCK"
if ! flock -n 9; then
  logger -t system-janitor "skipped — another instance is running" 2>/dev/null || true
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
ts()             { date '+%Y-%m-%dT%H:%M:%S%z'; }
bytes_used_kb()  { df --output=used / | tail -1 | tr -d ' '; }
human_kb()       { numfmt --from=iec-i --to=iec-i --format='%.1f' "${1}K" 2>/dev/null \
                    || awk "BEGIN{printf \"%.1fM\",${1}/1024}"; }
dir_inode()      { stat -c '%i' "$1" 2>/dev/null || echo missing; }
dir_size()       { du -sb "$1" 2>/dev/null | awk '{print $1}'; }

split_paths() {
  # Split colon-separated, expand $HOME and ~, drop empties.
  local raw="$1" item
  # Use bash's IFS-aware read into an array, then expand.
  IFS=':' read -r -a _items <<< "$raw"
  for item in "${_items[@]}"; do
    [ -z "$item" ] && continue
    item="${item/#\~/$HOME}"
    eval "item=\"$item\""
    printf '%s\n' "$item"
  done
}

jsonescape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1" 2>/dev/null \
    || printf '"%s"' "${1//\"/\\\"}"
}

emit_event() {
  local section="$1" status="$2" freed_kb="${3:-0}" items="${4:-0}" note="${5:-}"
  # Sanitize numeric fields: the JSONL is a public contract, so freed_kb and
  # items must be valid JSON numbers (no leading zeros, no garbage). Strip
  # all non-digits then force base-10 arithmetic, which yields 0 for empty
  # input and naturally drops leading zeros (e.g. "00" -> 0, "007" -> 7).
  freed_kb="${freed_kb//[^0-9]/}"
  items="${items//[^0-9]/}"
  freed_kb=$((10#${freed_kb:-0} + 0))
  items=$((10#${items:-0} + 0))
  printf '{"run_id":"%s","ts":"%s","host":"%s","user":"%s","section":%s,"status":"%s","freed_kb":%s,"items":%s,"note":%s}\n' \
    "$RUN_ID" "$(ts)" "$HOSTNAME_S" "$USER_S" \
    "$(jsonescape "$section")" "$status" \
    "$freed_kb" "$items" \
    "$(jsonescape "$note")" >>"$JSONL"

  # Accumulate per-section records for last-run.json `sections[]`. Meta-events
  # run_start / run_end bracket the run and are not sections. safety_integrity
  # IS included (it's a per-run result, like an action section). Order of
  # appends is execution order, which is preserved through to the final write.
  case "$section" in
    run_start|run_end) : ;;
    *)
      printf '{"name":%s,"status":"%s","items":%s,"freed_bytes":%s}\n' \
        "$(jsonescape "$section")" "$status" "$items" "$((freed_kb * 1024))" \
        >>"$SECTIONS_TMP" 2>/dev/null || true
      ;;
  esac
}

section() { echo; echo "── $* ── $(ts)"; }

# ── Opt-in sections ────────────────────────────────────────────────────
# Sections that do nothing unless the operator explicitly opts in via a
# JANITOR_*_DIRS config knob. When such a section runs successfully but
# produces no work (items=0, freed=0) on a real run, the JSONL event is
# downgraded from status="ok" to status="idle" so an autonomous agent
# watching the audit trail can detect a stale config without aggregating
# all historical events itself. Default sections (docker_prune,
# go_build_cache, tmp_gobuild_orphans, nuget_http_temp) legitimately have
# nothing to do on a clean host and stay status="ok"; do not add them here.
# When introducing a new opt-in section, add its name to this array.
OPTIN_SECTIONS=("workspace_binobj" "extra_cleanup")

run_section() {
  local name="$1"; shift
  local item_count_expr="$1"; shift
  local before after freed status="ok" items=0 note=""

  # ── --only flag: skip silently when not in ONLY_SECTIONS ──
  # No log line, no JSONL event — the section is invisible for this run.
  # Meta-sections (run_start, run_end, safety_integrity) call emit_event
  # directly and don't pass through run_section, so they always emit.
  _should_run_section "$name" || return 0

  section "$name"
  before=$(bytes_used_kb)

  if [ -n "$item_count_expr" ] && [ "$item_count_expr" != "0" ]; then
    items=$( { eval "$item_count_expr" 2>/dev/null || true; } | wc -l | tr -d ' \n')
    [ -z "$items" ] && items=0
    # Force base-10 arithmetic so weird wc/eval output never reaches emit_event
    # as a non-numeric or leading-zero value (which would break JSONL validity).
    items="${items//[^0-9]/}"
    items=$((10#${items:-0} + 0))
  fi

  if [ "$DRY_RUN" = "1" ]; then
    echo "[dry-run] would execute: $*"
    status="dry_run"
  else
    if "$@" 2>&1; then
      status="ok"
    else
      status="warn"
      note="action exited non-zero (rc=$?)"
    fi
  fi

  after=$(bytes_used_kb)
  freed=$((before - after))
  [ "$freed" -lt 0 ] && freed=0

  # Promote ok→idle for opt-in sections that produced no work on a real
  # run. This is the silent-failure detector required by the north star:
  # an opt-in section configured against a stale path will accumulate
  # status="idle" events that --report --json surfaces via idle_streaks.
  if [ "$status" = "ok" ] && [ "$items" = "0" ] && [ "$freed" = "0" ]; then
    local s
    for s in "${OPTIN_SECTIONS[@]}"; do
      if [ "$s" = "$name" ]; then
        status="idle"
        break
      fi
    done
  fi

  echo "[done] section='$name' status=$status items=$items freed=${freed}KB ($(human_kb $freed))"
  emit_event "$name" "$status" "$freed" "$items" "$note"
}

# ── Action implementations ─────────────────────────────────────────────
act_docker_prune() {
  [ "$JANITOR_DOCKER_PRUNE" = "yes" ] || { echo "[skip] disabled by config"; return 0; }
  command -v docker >/dev/null 2>&1 || { echo "[skip] docker not installed"; return 0; }
  docker info >/dev/null 2>&1 || { echo "[skip] docker daemon down"; return 0; }
  if [ "$JANITOR_DOCKER_VOLUMES" = "yes" ]; then
    docker system prune -af --volumes | tail -10
  else
    docker system prune -af | tail -10
  fi
}

act_go_clean() {
  [ "$JANITOR_GO_CLEAN" = "yes" ] || { echo "[skip] disabled by config"; return 0; }
  command -v go >/dev/null 2>&1 || { echo "[skip] go not installed"; return 0; }
  go clean -cache -testcache 2>&1 | tail -5
}

act_tmp_gobuild() {
  [ "$JANITOR_TMP_GOBUILD_ORPHANS" = "yes" ] || { echo "[skip] disabled by config"; return 0; }
  local removed=0
  for path in /tmp/go-build* /tmp/gopath; do
    [ -e "$path" ] || continue
    chmod -R u+w "$path" 2>/dev/null || true
    if rm -rf "$path" 2>/dev/null; then
      removed=$((removed+1))
    else
      echo "[warn] could not fully remove $path"
    fi
  done
  echo "removed $removed path(s)"
}

act_workspace_binobj() {
  [ -n "$JANITOR_WORKSPACE_DIRS" ] || { echo "[skip] JANITOR_WORKSPACE_DIRS not set"; return 0; }
  local total=0 dir count
  while IFS= read -r dir; do
    [ -d "$dir" ] || { echo "[skip] $dir not found"; continue; }
    count=$(find "$dir" -maxdepth 6 -type d \( -name bin -o -name obj \) -prune 2>/dev/null | wc -l)
    find "$dir" -maxdepth 6 -type d \( -name bin -o -name obj \) -prune -exec rm -rf {} + 2>/dev/null
    echo "  $dir: removed $count bin/obj director(ies)"
    total=$((total+count))
  done < <(split_paths "$JANITOR_WORKSPACE_DIRS")
  echo "total $total bin/obj director(ies) removed"
}

act_extra_cleanup() {
  [ -n "$JANITOR_EXTRA_CLEANUP_DIRS" ] || { echo "[skip] JANITOR_EXTRA_CLEANUP_DIRS not set"; return 0; }
  local removed=0 dir
  while IFS= read -r dir; do
    if [ -e "$dir" ]; then
      rm -rf "$dir" && { echo "  removed $dir"; removed=$((removed+1)); } \
                    || echo "  [warn] could not remove $dir"
    else
      echo "  [skip] $dir already absent"
    fi
  done < <(split_paths "$JANITOR_EXTRA_CLEANUP_DIRS")
  echo "removed $removed path(s)"
}

act_nuget_caches() {
  [ "$JANITOR_NUGET_CLEAN" = "yes" ] || { echo "[skip] disabled by config"; return 0; }
  command -v dotnet >/dev/null 2>&1 || { echo "[skip] dotnet not installed"; return 0; }
  dotnet nuget locals http-cache --clear | tail -2
  dotnet nuget locals temp        --clear | tail -2
}

# ── Item-count expressions ─────────────────────────────────────────────
count_docker_images() { echo 'docker images -aq 2>/dev/null'; }
count_tmp_gobuild()   { echo 'ls -1d /tmp/go-build* /tmp/gopath 2>/dev/null'; }
count_workspace_binobj() {
  [ -n "$JANITOR_WORKSPACE_DIRS" ] || { echo ""; return; }
  local find_dirs=""
  while IFS= read -r d; do [ -d "$d" ] && find_dirs="$find_dirs $d"; done < <(split_paths "$JANITOR_WORKSPACE_DIRS")
  [ -n "$find_dirs" ] || { echo ""; return; }
  echo "find $find_dirs -maxdepth 6 -type d \\( -name bin -o -name obj \\) -prune 2>/dev/null"
}
count_extra_cleanup() {
  [ -n "$JANITOR_EXTRA_CLEANUP_DIRS" ] || { echo ""; return; }
  local args=""
  while IFS= read -r d; do args="$args \"$d\""; done < <(split_paths "$JANITOR_EXTRA_CLEANUP_DIRS")
  echo "ls -1d $args 2>/dev/null"
}

# ── Run header ─────────────────────────────────────────────────────────
START_KB=$(bytes_used_kb)

# Snapshot safety-floor dirs (inode + byte size) before the run.
declare -A SAFETY_BEFORE_INODE SAFETY_BEFORE_SIZE
SAFETY_DIRS_LIST=""
if [ -n "$JANITOR_SAFETY_FLOOR_DIRS" ]; then
  while IFS= read -r d; do
    SAFETY_DIRS_LIST="$SAFETY_DIRS_LIST $d"
    SAFETY_BEFORE_INODE["$d"]=$(dir_inode "$d")
    SAFETY_BEFORE_SIZE["$d"]=$(dir_size "$d")
  done < <(split_paths "$JANITOR_SAFETY_FLOOR_DIRS")
fi

echo "════════════════════════════════════════════════════════════════"
echo " system-janitor"
echo " run_id : $RUN_ID"
echo " host   : $HOSTNAME_S"
echo " user   : $USER_S"
echo " start  : $(ts)"
echo " config : ${CONFIG_LOADED:-<none — using defaults>}"
echo " dryrun : $DRY_RUN"
echo " safety : ${SAFETY_DIRS_LIST:-<none>}"
echo "════════════════════════════════════════════════════════════════"
df -h / | tail -2

RUN_STARTED_AT="$(ts)"
emit_event "run_start" "ok" 0 0 "config=${CONFIG_LOADED:-defaults} dry_run=$DRY_RUN"

# ── Sections ───────────────────────────────────────────────────────────
run_section "docker_prune"        "$(count_docker_images)"      act_docker_prune
run_section "go_build_cache"      ""                            act_go_clean
run_section "tmp_gobuild_orphans" "$(count_tmp_gobuild)"        act_tmp_gobuild
run_section "workspace_binobj"    "$(count_workspace_binobj)"   act_workspace_binobj
run_section "extra_cleanup"       "$(count_extra_cleanup)"      act_extra_cleanup
run_section "nuget_http_temp"     ""                            act_nuget_caches

# ── Integrity check on safety-floor dirs ──────────────────────────────
section "Integrity check"
INTEGRITY="ok"
INTEGRITY_NOTE=""
if [ -n "$JANITOR_SAFETY_FLOOR_DIRS" ]; then
  while IFS= read -r d; do
    after_inode=$(dir_inode "$d")
    after_size=$(dir_size "$d")
    before_inode="${SAFETY_BEFORE_INODE[$d]}"
    before_size="${SAFETY_BEFORE_SIZE[$d]}"
    line="$d before=(inode=$before_inode size=$before_size) after=(inode=$after_inode size=$after_size)"
    if [ "$after_inode" = "missing" ] && [ "$before_inode" != "missing" ]; then
      INTEGRITY="violated_missing"; INTEGRITY_NOTE="$INTEGRITY_NOTE $d:missing"
    elif [ "$before_inode" != "$after_inode" ]; then
      INTEGRITY="violated_inode_changed"; INTEGRITY_NOTE="$INTEGRITY_NOTE $d:inode_changed"
    elif [ -n "$before_size" ] && [ -n "$after_size" ] && [ "$before_size" != "$after_size" ]; then
      # Size change alone is informational unless inode also changed; some
      # safety dirs (like log dirs) may legitimately grow during a run.
      # We log it but do not fail the integrity check.
      line="$line [info: size changed]"
    fi
    echo "$line"
  done < <(split_paths "$JANITOR_SAFETY_FLOOR_DIRS")
else
  echo "(no safety-floor dirs configured)"
fi
echo "result: $INTEGRITY"
if [ -z "$JANITOR_SAFETY_FLOOR_DIRS" ]; then
  emit_event "safety_integrity" "$INTEGRITY" 0 0 "no_safety_dirs_configured"
else
  emit_event "safety_integrity" "$INTEGRITY" 0 0 "${INTEGRITY_NOTE:-clean}"
fi

# ── Final summary ──────────────────────────────────────────────────────
END_KB=$(bytes_used_kb)
TOTAL_FREED=$((START_KB - END_KB))
[ "$TOTAL_FREED" -lt 0 ] && TOTAL_FREED=0
EXIT_CODE=0

section "Summary"
df -h / | tail -2
echo
echo "run_id           : $RUN_ID"
echo "total reclaimed  : ${TOTAL_FREED} KB ($(human_kb $TOTAL_FREED))"
echo "safety integrity : $INTEGRITY"

# Atomic last-run.json (now with per-section records assembled from the
# accumulator). Existing fields are preserved verbatim — only new keys are
# added (run_id was already present; started_at, ended_at, sections are new).
RUN_ENDED_AT="$(ts)"
TMPSUM="${LATEST}.tmp.$$"
if RUN_ID_E="$RUN_ID" \
   STARTED_AT_E="$RUN_STARTED_AT" \
   ENDED_AT_E="$RUN_ENDED_AT" \
   HOST_E="$HOSTNAME_S" \
   USER_E="$USER_S" \
   FREED_KB_E="$TOTAL_FREED" \
   INTEGRITY_E="$INTEGRITY" \
   START_KB_E="$START_KB" \
   END_KB_E="$END_KB" \
   DRY_RUN_E="$DRY_RUN" \
   SECTIONS_FILE_E="$SECTIONS_TMP" \
   python3 - > "$TMPSUM" <<'PY'
import json, os
sections = []
sf = os.environ.get("SECTIONS_FILE_E", "")
if sf and os.path.isfile(sf):
    with open(sf, "r", errors="replace") as fh:
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
            # Normalize to documented schema; coerce numeric fields.
            try:
                items = int(obj.get("items", 0) or 0)
            except (TypeError, ValueError):
                items = 0
            try:
                fb = int(obj.get("freed_bytes", 0) or 0)
            except (TypeError, ValueError):
                fb = 0
            sections.append({
                "name":         str(obj.get("name", "")),
                "status":       str(obj.get("status", "")),
                "items":        items,
                "freed_bytes":  fb,
            })

def _int(v, default=0):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default

out = {
    # Pre-existing schema (DO NOT remove or rename these).
    "run_id":           os.environ["RUN_ID_E"],
    "finished":         os.environ["ENDED_AT_E"],
    "host":             os.environ["HOST_E"],
    "user":             os.environ["USER_E"],
    "freed_kb":         _int(os.environ.get("FREED_KB_E")),
    "safety_integrity": os.environ["INTEGRITY_E"],
    "start_used_kb":    _int(os.environ.get("START_KB_E")),
    "end_used_kb":      _int(os.environ.get("END_KB_E")),
    "dry_run":          _int(os.environ.get("DRY_RUN_E")),
    # Enrichment (added 2026-05; agents reading older files should treat
    # missing `sections` as "unknown", not "error").
    "started_at":       os.environ["STARTED_AT_E"],
    "ended_at":         os.environ["ENDED_AT_E"],
    "sections":         sections,
}
print(json.dumps(out))
PY
then
  mv "$TMPSUM" "$LATEST"
else
  # Python-heredoc path failed (missing python3, OOM, ...). Fall back to the
  # legacy shell-printf writer so monitoring tools still see a valid summary.
  # The fallback omits `sections[]` — agents must treat that absence as
  # "unknown", per the documented backward-compat policy.
  {
    printf '{'
    printf '"run_id":%s,'    "$(jsonescape "$RUN_ID")"
    printf '"finished":%s,'  "$(jsonescape "$RUN_ENDED_AT")"
    printf '"host":%s,'      "$(jsonescape "$HOSTNAME_S")"
    printf '"user":%s,'      "$(jsonescape "$USER_S")"
    printf '"freed_kb":%s,'  "$TOTAL_FREED"
    printf '"safety_integrity":%s,' "$(jsonescape "$INTEGRITY")"
    printf '"start_used_kb":%s,'    "$START_KB"
    printf '"end_used_kb":%s,'      "$END_KB"
    printf '"dry_run":%s'           "$DRY_RUN"
    printf '}\n'
  } > "$TMPSUM" && mv "$TMPSUM" "$LATEST"
fi
rm -f "$SECTIONS_TMP"

emit_event "run_end" "ok" "$TOTAL_FREED" 0 "integrity=$INTEGRITY"

if [ "$INTEGRITY" != "ok" ]; then
  logger -t system-janitor -p user.err "INTEGRITY VIOLATION run_id=$RUN_ID result=$INTEGRITY notes=$INTEGRITY_NOTE" 2>/dev/null || true
  echo "[FATAL] integrity violation: $INTEGRITY ($INTEGRITY_NOTE)" >&2
  EXIT_CODE=2
else
  logger -t system-janitor -p user.info "run_id=$RUN_ID freed=${TOTAL_FREED}KB integrity=ok dry_run=$DRY_RUN" 2>/dev/null || true
fi

echo "════════════════════════════════════════════════════════════════"
exit $EXIT_CODE
