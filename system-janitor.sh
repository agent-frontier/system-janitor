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

set -uo pipefail

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

while [ $# -gt 0 ]; do
  case "$1" in
    --config)     CONFIG_FILE="$2"; shift 2 ;;
    --config=*)   CONFIG_FILE="${1#*=}"; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    --help|-h)    SHOW_HELP=1; shift ;;
    *) echo "[ERROR] unknown flag: $1" >&2; SHOW_HELP=1; shift ;;
  esac
done

if [ "$SHOW_HELP" = 1 ]; then
  cat <<'USAGE'
system-janitor — disk-cleanup sweep with audit-grade logging.

USAGE:
  system-janitor [--config <path>] [--dry-run] [--help]

FLAGS:
  --config <path>   Source <path> for configuration (default:
                    $XDG_CONFIG_HOME/system-janitor/config)
  --dry-run, -n     Log what would be done without modifying anything.
                    Item counts and pre-state are still reported.
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
  JANITOR_LOG_DIR                state directory
                                 (default: $XDG_STATE_HOME/janitor)

EXAMPLES:
  # Cron entry — Sunday 03:17 weekly:
  17 3 * * 0 $HOME/.local/bin/system-janitor

  # Dry-run preview:
  system-janitor --dry-run

LOGS:
  $XDG_STATE_HOME/janitor/janitor.log     human-readable
  $XDG_STATE_HOME/janitor/janitor.jsonl   one JSON event per section
  $XDG_STATE_HOME/janitor/last-run.json   latest summary

See https://github.com/agent-frontier/system-janitor for full docs.
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
  printf '{"run_id":"%s","ts":"%s","host":"%s","user":"%s","section":%s,"status":"%s","freed_kb":%s,"items":%s,"note":%s}\n' \
    "$RUN_ID" "$(ts)" "$HOSTNAME_S" "$USER_S" \
    "$(jsonescape "$section")" "$status" \
    "${freed_kb:-0}" "${items:-0}" \
    "$(jsonescape "$note")" >>"$JSONL"
}

section() { echo; echo "── $* ── $(ts)"; }

run_section() {
  local name="$1"; shift
  local item_count_expr="$1"; shift
  local before after freed status="ok" items=0 note=""

  section "$name"
  before=$(bytes_used_kb)

  if [ -n "$item_count_expr" ] && [ "$item_count_expr" != "0" ]; then
    items=$( { eval "$item_count_expr" 2>/dev/null || true; } | wc -l | tr -d ' \n')
    [ -z "$items" ] && items=0
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

# Atomic last-run.json
TMPSUM="${LATEST}.tmp.$$"
{
  printf '{'
  printf '"run_id":%s,'    "$(jsonescape "$RUN_ID")"
  printf '"finished":%s,'  "$(jsonescape "$(ts)")"
  printf '"host":%s,'      "$(jsonescape "$HOSTNAME_S")"
  printf '"user":%s,'      "$(jsonescape "$USER_S")"
  printf '"freed_kb":%s,'  "$TOTAL_FREED"
  printf '"safety_integrity":%s,' "$(jsonescape "$INTEGRITY")"
  printf '"start_used_kb":%s,'    "$START_KB"
  printf '"end_used_kb":%s,'      "$END_KB"
  printf '"dry_run":%s'           "$DRY_RUN"
  printf '}\n'
} > "$TMPSUM" && mv "$TMPSUM" "$LATEST"

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
