#!/usr/bin/env bash
# system-janitor.sh — weekly disk-cleanup sweep with audit-grade logging.
#
# Production practices implemented:
#   - Per-section byte deltas (what each step actually freed)
#   - Item counts where measurable (containers/images/dirs/files)
#   - Structured JSON event line per section + final summary line
#   - Run-id correlation across all log lines
#   - Lock file prevents overlapping runs
#   - Integrity check on ~/.copilot before AND after (must never be touched)
#   - Exits non-zero on integrity violation; writes to syslog
#   - Append-only logs with size-triggered rotation (8 backups kept)
#   - Both human-readable .log and machine-parseable .jsonl
#
# Logs:
#   ~/.local/state/janitor/janitor.log    (human-readable)
#   ~/.local/state/janitor/janitor.jsonl  (one JSON event per line)
#   ~/.local/state/janitor/last-run.json  (latest summary, atomic-overwrite)
#
# Exit codes:
#   0  success (all sections completed; integrity OK)
#   1  another instance running (lock held)
#   2  integrity violation (~/.copilot disturbed)
#   3  precondition failed (e.g., $HOME unset)

set -uo pipefail

# ── Cron-safe environment ──────────────────────────────────────────────
export PATH="/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${HOME}/.dotnet:${HOME}/.local/bin:${HOME}/go/bin"
export DOTNET_ROOT="${HOME}/.dotnet"
[ -z "${HOME:-}" ] && { echo "[FATAL] HOME unset" >&2; exit 3; }

# ── Paths and identifiers ──────────────────────────────────────────────
LOG_DIR="${HOME}/.local/state/janitor"
LOG="${LOG_DIR}/janitor.log"
JSONL="${LOG_DIR}/janitor.jsonl"
LATEST="${LOG_DIR}/last-run.json"
LOCK="${LOG_DIR}/janitor.lock"
mkdir -p "$LOG_DIR"

# Pseudo-UUID: timestamp + 8 hex chars from /dev/urandom (no uuidgen dep).
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo deadbeef)"
HOSTNAME_S="$(hostname)"
USER_S="${USER:-$(id -un)}"

# ── Single-instance lock (flock-based, releases on exit) ───────────────
exec 9>"$LOCK"
if ! flock -n 9; then
  logger -t system-janitor "run skipped — another instance is running (lock=$LOCK)" 2>/dev/null || true
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

# All stdout/stderr goes to the human log from here.
exec >>"$LOG" 2>&1

# ── Helpers ────────────────────────────────────────────────────────────
ts()             { date '+%Y-%m-%dT%H:%M:%S%z'; }
bytes_used_kb()  { df --output=used / | tail -1 | tr -d ' '; }
human_kb()       { numfmt --from=iec-i --to=iec-i --format='%.1f' "${1}K" 2>/dev/null \
                    || awk "BEGIN{printf \"%.1fM\",${1}/1024}"; }
copilot_inode()  { stat -c '%i' "${HOME}/.copilot" 2>/dev/null || echo missing; }
copilot_size()   { du -sb "${HOME}/.copilot" 2>/dev/null | awk '{print $1}'; }

# JSON-escape via python (cron-safe; python3 is on every supported distro).
jsonescape() {
  python3 -c '
import json, sys
print(json.dumps(sys.argv[1]))
' "$1" 2>/dev/null || printf '"%s"' "${1//\"/\\\"}"
}

emit_event() {
  # emit_event <section> <status> <freed_kb> <items> <note>
  local section="$1" status="$2" freed_kb="${3:-0}" items="${4:-0}" note="${5:-}"
  printf '{"run_id":"%s","ts":"%s","host":"%s","user":"%s","section":%s,"status":"%s","freed_kb":%s,"items":%s,"note":%s}\n' \
    "$RUN_ID" "$(ts)" "$HOSTNAME_S" "$USER_S" \
    "$(jsonescape "$section")" "$status" \
    "${freed_kb:-0}" "${items:-0}" \
    "$(jsonescape "$note")" >>"$JSONL"
}

section() {
  echo
  echo "── $* ── $(ts)"
}

# Wrap a cleanup action: measure bytes before/after, count items, log both.
# Usage: run_section <name> <item_count_command_or_0> <action ...>
run_section() {
  local name="$1"; shift
  local item_count_expr="$1"; shift
  local before after freed status="ok" items=0 note=""

  section "$name"
  before=$(bytes_used_kb)

  # Count items (if expression provided). Eval in a subshell, never fatal.
  if [ -n "$item_count_expr" ] && [ "$item_count_expr" != "0" ]; then
    items=$(eval "$item_count_expr" 2>/dev/null | wc -l | tr -d ' \n' || echo 0)
  fi

  # Run the action.
  if "$@" 2>&1; then
    status="ok"
  else
    status="warn"
    note="action exited non-zero (rc=$?)"
  fi

  after=$(bytes_used_kb)
  freed=$((before - after))
  [ "$freed" -lt 0 ] && freed=0

  echo "[done] section='$name' status=$status items=$items freed=${freed}KB ($(human_kb $freed))"
  emit_event "$name" "$status" "$freed" "$items" "$note"
}

# ── Action implementations ─────────────────────────────────────────────
act_docker_prune() {
  if ! command -v docker >/dev/null 2>&1; then echo "[skip] docker not installed"; return 0; fi
  if ! docker info >/dev/null 2>&1;             then echo "[skip] docker daemon down"; return 0; fi
  docker system prune -af --volumes | tail -10
}

act_go_clean() {
  command -v go >/dev/null 2>&1 || { echo "[skip] go not installed"; return 0; }
  go clean -cache -testcache 2>&1 | tail -5
}

act_tmp_gobuild() {
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

act_sandbox_binobj() {
  [ -d "${HOME}/sandbox" ] || { echo "[skip] no ~/sandbox directory"; return 0; }
  local count
  count=$(find "${HOME}/sandbox" -maxdepth 6 -type d \( -name bin -o -name obj \) -prune 2>/dev/null | wc -l)
  find "${HOME}/sandbox" -maxdepth 6 -type d \( -name bin -o -name obj \) -prune -exec rm -rf {} + 2>/dev/null
  echo "removed $count bin/obj director(ies)"
}

act_aoai_dist() {
  if [ -d "${HOME}/sandbox/azure-openai-cli/dist" ]; then
    rm -rf "${HOME}/sandbox/azure-openai-cli/dist"
    echo "removed dist/"
  else
    echo "[skip] dist/ already absent"
  fi
}

act_nuget_caches() {
  command -v dotnet >/dev/null 2>&1 || { echo "[skip] dotnet not installed"; return 0; }
  dotnet nuget locals http-cache --clear | tail -2
  dotnet nuget locals temp        --clear | tail -2
}

act_user_cache_copilot() {
  # ~/.cache/copilot is distinct from ~/.copilot (which we MUST NOT touch).
  if [ -d "${HOME}/.cache/copilot" ]; then
    rm -rf "${HOME}/.cache/copilot"
    echo "removed ~/.cache/copilot"
  else
    echo "[skip] ~/.cache/copilot already absent"
  fi
}

# ── Item-count expressions (counted before action runs) ────────────────
count_docker_images()   { echo "docker images -aq 2>/dev/null"; }
count_sandbox_binobj()  { echo "find \"\${HOME}/sandbox\" -maxdepth 6 -type d \\( -name bin -o -name obj \\) -prune 2>/dev/null"; }
count_tmp_gobuild()     { echo "ls -1d /tmp/go-build* /tmp/gopath 2>/dev/null"; }

# ── Run header ─────────────────────────────────────────────────────────
START_KB=$(bytes_used_kb)
COPILOT_INODE_BEFORE=$(copilot_inode)
COPILOT_SIZE_BEFORE=$(copilot_size)

echo "════════════════════════════════════════════════════════════════"
echo " system-janitor"
echo " run_id : $RUN_ID"
echo " host   : $HOSTNAME_S"
echo " user   : $USER_S"
echo " start  : $(ts)"
echo "════════════════════════════════════════════════════════════════"
df -h / | tail -2

emit_event "run_start" "ok" 0 0 "run_id=$RUN_ID copilot_inode=$COPILOT_INODE_BEFORE copilot_size=$COPILOT_SIZE_BEFORE"

# ── Sections ───────────────────────────────────────────────────────────
run_section "docker_prune"          "$(count_docker_images)"  act_docker_prune
run_section "go_build_cache"        ""                        act_go_clean
run_section "tmp_gobuild_orphans"   "$(count_tmp_gobuild)"    act_tmp_gobuild
run_section "sandbox_binobj"        "$(count_sandbox_binobj)" act_sandbox_binobj
run_section "azure_openai_cli_dist" ""                        act_aoai_dist
run_section "nuget_http_temp"       ""                        act_nuget_caches
run_section "user_cache_copilot"    ""                        act_user_cache_copilot

# ── Integrity check on ~/.copilot ──────────────────────────────────────
section "Integrity check: ~/.copilot must be untouched"
COPILOT_INODE_AFTER=$(copilot_inode)
COPILOT_SIZE_AFTER=$(copilot_size)
INTEGRITY="ok"
if [ "$COPILOT_INODE_AFTER" = "missing" ]; then
  INTEGRITY="violated_missing"
elif [ "$COPILOT_INODE_BEFORE" != "$COPILOT_INODE_AFTER" ]; then
  INTEGRITY="violated_inode_changed"
fi
echo "before: inode=$COPILOT_INODE_BEFORE size=$COPILOT_SIZE_BEFORE bytes"
echo "after : inode=$COPILOT_INODE_AFTER  size=$COPILOT_SIZE_AFTER bytes"
echo "result: $INTEGRITY"
emit_event "copilot_integrity" "$INTEGRITY" 0 0 \
  "before_inode=$COPILOT_INODE_BEFORE after_inode=$COPILOT_INODE_AFTER before_size=$COPILOT_SIZE_BEFORE after_size=$COPILOT_SIZE_AFTER"

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
echo "copilot integrity: $INTEGRITY"

# Last-run summary (atomic write).
TMPSUM="${LATEST}.tmp.$$"
{
  printf '{'
  printf '"run_id":%s,'  "$(jsonescape "$RUN_ID")"
  printf '"finished":%s,' "$(jsonescape "$(ts)")"
  printf '"host":%s,'    "$(jsonescape "$HOSTNAME_S")"
  printf '"user":%s,'    "$(jsonescape "$USER_S")"
  printf '"freed_kb":%s,' "$TOTAL_FREED"
  printf '"copilot_integrity":%s,' "$(jsonescape "$INTEGRITY")"
  printf '"start_used_kb":%s,' "$START_KB"
  printf '"end_used_kb":%s'    "$END_KB"
  printf '}\n'
} > "$TMPSUM" && mv "$TMPSUM" "$LATEST"

emit_event "run_end" "ok" "$TOTAL_FREED" 0 "integrity=$INTEGRITY"

if [ "$INTEGRITY" != "ok" ]; then
  logger -t system-janitor -p user.err "INTEGRITY VIOLATION run_id=$RUN_ID result=$INTEGRITY" 2>/dev/null || true
  echo "[FATAL] integrity violation: $INTEGRITY" >&2
  EXIT_CODE=2
else
  logger -t system-janitor -p user.info "run_id=$RUN_ID freed=${TOTAL_FREED}KB integrity=ok" 2>/dev/null || true
fi

echo "════════════════════════════════════════════════════════════════"
exit $EXIT_CODE
