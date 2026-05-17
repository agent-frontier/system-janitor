#!/usr/bin/env bash
# tests/capabilities-check.sh — assert each tool's --version --json
# capabilities[] matches the registry at docs/agents/capabilities.md.
#
# The registry is the source of truth. The script's hardcoded
# capabilities[] and the per-tool smoke probes must stay in sync with
# it. This check is the cross-tool collision guard the per-tool
# smokes can't provide on their own.
#
# Exit codes:
#   0  all tools' capabilities[] match the registry
#   1  drift detected (registry vs script disagree) or registry is
#      missing a tool that exists in the repo
#   2  usage / environment problem (script not executable, no python3,
#      registry file missing)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$REPO_ROOT/docs/agents/capabilities.md"

pass()  { echo "ok: $*"; }
fail()  { echo "FAIL: $*" >&2; exit 1; }
abort() { echo "ABORT: $*" >&2; exit 2; }

[ -f "$REGISTRY" ] || abort "registry not found: $REGISTRY"
command -v python3 >/dev/null || abort "python3 required"

# Extract the first ```json fenced block from the registry.
REGISTRY_JSON="$(python3 - "$REGISTRY" <<'PY'
import re, sys
with open(sys.argv[1]) as f:
    text = f.read()
m = re.search(r"```json\n(.*?)\n```", text, re.DOTALL)
if not m:
    sys.stderr.write("no ```json fenced block in registry\n")
    sys.exit(3)
print(m.group(1))
PY
)" || abort "could not extract JSON block from $REGISTRY"

# Validate JSON parses + has the expected shape.
python3 - <<PY || abort "registry JSON is malformed"
import json, sys
d = json.loads('''$REGISTRY_JSON''')
assert isinstance(d, dict), "top-level must be object"
for tool, caps in d.items():
    assert isinstance(caps, list), f"{tool}: capabilities must be array"
    assert caps == sorted(caps), f"{tool}: capabilities not alphabetical"
    assert len(caps) == len(set(caps)), f"{tool}: duplicate capability"
PY

echo "── capabilities registry check ──────────────────────────────"

# Map registry tool names to script paths.
declare -A SCRIPTS=(
  ["system-janitor"]="$REPO_ROOT/system-janitor.sh"
  ["system-updater"]="$REPO_ROOT/system-updater.sh"
)

# Read registry tools.
REGISTRY_TOOLS="$(python3 -c "
import json
d = json.loads(r'''$REGISTRY_JSON''')
print('\n'.join(sorted(d.keys())))
")"

# Every script with --version --json in the repo must appear in the registry.
for tool in "${!SCRIPTS[@]}"; do
  script="${SCRIPTS[$tool]}"
  [ -x "$script" ] || abort "script not executable: $script"
  echo "$REGISTRY_TOOLS" | grep -qx "$tool" \
    || fail "script exists but tool '$tool' missing from registry"
done

# Every registry tool must have a matching script.
while IFS= read -r tool; do
  [ -n "${SCRIPTS[$tool]:-}" ] \
    || fail "registry lists '$tool' but no script mapping known to this check"
done <<< "$REGISTRY_TOOLS"

# For each tool, --version --json must match the registry exactly.
for tool in "${!SCRIPTS[@]}"; do
  script="${SCRIPTS[$tool]}"

  REGISTRY_CAPS="$(python3 -c "
import json
d = json.loads(r'''$REGISTRY_JSON''')
print('\n'.join(d['$tool']))
")"

  RUNTIME_CAPS="$("$script" --version --json | python3 -c '
import json, sys
print("\n".join(json.load(sys.stdin)["capabilities"]))
')" || fail "$tool: --version --json failed"

  if [ "$REGISTRY_CAPS" = "$RUNTIME_CAPS" ]; then
    n=$(echo "$REGISTRY_CAPS" | wc -l)
    pass "$tool: ${n} capabilities match registry"
  else
    echo "FAIL: $tool: capabilities drift between registry and script" >&2
    echo "--- registry ($REGISTRY) ---" >&2
    echo "$REGISTRY_CAPS" >&2
    echo "--- runtime ($script --version --json) ---" >&2
    echo "$RUNTIME_CAPS" >&2
    echo "--- diff (< registry, > runtime) ---" >&2
    diff <(echo "$REGISTRY_CAPS") <(echo "$RUNTIME_CAPS") >&2 || true
    exit 1
  fi
done

# Cross-tool: every capability that appears in 2+ tools must be
# documented in the "Shared capabilities" table of the registry.
echo "── shared-capability semantics check ────────────────────────"
SHARED_DOC="$(python3 - "$REGISTRY" <<'PY'
import re, sys
with open(sys.argv[1]) as f:
    text = f.read()
# Extract the Shared-capabilities markdown table.
m = re.search(
    r"## Shared capabilities.*?\n\n(\| Capability \|.*?)(?=\n##|\Z)",
    text, re.DOTALL)
if not m:
    sys.stderr.write("could not locate 'Shared capabilities' table\n")
    sys.exit(3)
# Collect capability strings from the first column.
caps = re.findall(r"\n\| `([^`]+)` \|", m.group(1))
print("\n".join(sorted(set(caps))))
PY
)" || abort "could not parse 'Shared capabilities' table"

SHARED_REGISTRY="$(python3 -c "
import json, collections
d = json.loads(r'''$REGISTRY_JSON''')
counts = collections.Counter()
for caps in d.values():
    for c in caps:
        counts[c] += 1
shared = sorted(c for c, n in counts.items() if n >= 2)
print('\n'.join(shared))
")"

drift=0
while IFS= read -r cap; do
  [ -z "$cap" ] && continue
  if ! echo "$SHARED_DOC" | grep -qx "$cap"; then
    echo "FAIL: capability '$cap' is in 2+ tools' arrays but missing from the 'Shared capabilities' table in registry" >&2
    drift=1
  fi
done <<< "$SHARED_REGISTRY"

while IFS= read -r cap; do
  [ -z "$cap" ] && continue
  if ! echo "$SHARED_REGISTRY" | grep -qx "$cap"; then
    echo "FAIL: capability '$cap' is in the 'Shared capabilities' table but appears in fewer than 2 tools' arrays" >&2
    drift=1
  fi
done <<< "$SHARED_DOC"

[ "$drift" -eq 0 ] || exit 1

n_shared=$(echo "$SHARED_REGISTRY" | grep -c . || true)
pass "${n_shared} shared capabilities have semantics rows"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  capabilities-check: PASS"
echo "════════════════════════════════════════════════════════════════"
