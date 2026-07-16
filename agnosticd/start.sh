#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Start (resume from hibernate)
# Starts the hub first, then student clusters.
#
# Usage:
#   ./agnosticd/start.sh
#   START_HUB=false ./agnosticd/start.sh  # students only
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_VARS="${AGNOSTICD_ROOT}/../agnosticd-v2-vars"
ACCOUNT="${ACCOUNT:-sandbox2530}"

START_HUB="${START_HUB:-true}"
HUB_GUID="${HUB_GUID:-linbit-hub}"

BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

STATE_DIR="${SCRIPT_DIR}/.state"
MANIFEST="${STATE_DIR}/students.txt"

# Ensure symlinks exist
ln -sf "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"
ln -sf "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/linbit-student.yml"

cd "$AGNOSTICD_ROOT"

# Start hub first (RHACM + Showroom must be up before students reconnect)
if [[ "$START_HUB" == "true" ]]; then
  echo "==> Starting hub ($HUB_GUID) ..."
  ./bin/agd start -g "$HUB_GUID" -c linbit-hub -a "$ACCOUNT"
  echo "Hub started. Waiting 60s for RHACM to stabilize..."
  sleep 60
fi

# Start student clusters
echo "Starting student cluster(s) ..."

start_one() {
  local guid="$1"
  local student_num="${guid##*-s}"
  local config_name="linbit-student-${student_num}"
  [[ -f "${AGNOSTICD_VARS}/${config_name}.yml" ]] || config_name="linbit-student"
  echo "==> Starting $guid ..."
  ./bin/agd start -g "$guid" -c "$config_name" -a "$ACCOUNT" || \
    echo "WARNING: Failed to start $guid"
}

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r guid; do
    [[ -z "$guid" ]] && continue
    start_one "$guid"
  done < "$MANIFEST"
else
  for i in $(seq 1 "$NUM_STUDENTS"); do
    start_one "${BASE_GUID}-s${i}"
  done
fi

echo "All clusters started."
