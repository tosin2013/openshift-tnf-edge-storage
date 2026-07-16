#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Stop (hibernate)
# Stops all student clusters, then the hub. Saves AWS costs.
#
# Usage:
#   ./agnosticd/stop.sh
#   STOP_HUB=false ./agnosticd/stop.sh   # students only
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_VARS="${AGNOSTICD_ROOT}/../agnosticd-v2-vars"
ACCOUNT="${ACCOUNT:-sandbox2530}"

STOP_HUB="${STOP_HUB:-true}"
HUB_GUID="${HUB_GUID:-linbit-hub}"

BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

STATE_DIR="${SCRIPT_DIR}/.state"
MANIFEST="${STATE_DIR}/students.txt"

# Ensure symlinks exist
ln -sf "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"
ln -sf "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/linbit-student.yml"

cd "$AGNOSTICD_ROOT"

# Stop student clusters first
echo "Stopping student cluster(s) ..."

stop_one() {
  local guid="$1"
  local student_num="${guid##*-s}"
  local config_name="linbit-student-${student_num}"
  [[ -f "${AGNOSTICD_VARS}/${config_name}.yml" ]] || config_name="linbit-student"
  echo "==> Stopping $guid ..."
  ./bin/agd stop -g "$guid" -c "$config_name" -a "$ACCOUNT" || \
    echo "WARNING: Failed to stop $guid"
}

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r guid; do
    [[ -z "$guid" ]] && continue
    stop_one "$guid"
  done < "$MANIFEST"
else
  for i in $(seq 1 "$NUM_STUDENTS"); do
    stop_one "${BASE_GUID}-s${i}"
  done
fi

# Stop hub
if [[ "$STOP_HUB" == "true" ]]; then
  echo "==> Stopping hub ($HUB_GUID) ..."
  ./bin/agd stop -g "$HUB_GUID" -c linbit-hub -a "$ACCOUNT"
fi

echo "All clusters stopped."
