#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Status
# Reports the status of the hub and all student clusters.
#
# Usage:
#   ./agnosticd/status.sh
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_VARS="${AGNOSTICD_ROOT}/../agnosticd-v2-vars"
ACCOUNT="${ACCOUNT:-sandbox2530}"

HUB_GUID="${HUB_GUID:-linbit-hub}"

BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

STATE_DIR="${SCRIPT_DIR}/.state"
MANIFEST="${STATE_DIR}/students.txt"

# Ensure symlinks exist
# Copy, not symlink — EE containers cannot follow host symlinks
cp "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"
cp "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/linbit-student.yml"

cd "$AGNOSTICD_ROOT"

echo "============================================================"
echo "LINBIT Edge Storage Workshop — Cluster Status"
echo "============================================================"
echo ""

echo "--- Hub Cluster: $HUB_GUID ---"
AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" status -g "$HUB_GUID" -c linbit-hub -a "$ACCOUNT" 2>/dev/null || \
  echo "  Status: UNKNOWN (not deployed or not reachable)"
echo ""

echo "--- Student Clusters ---"

status_one() {
  local guid="$1"
  local student_num="${guid##*-s}"
  local config_name="linbit-student-${student_num}"
  [[ -f "${AGNOSTICD_VARS}/${config_name}.yml" ]] || config_name="linbit-student"
  echo "  $guid:"
  AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" status -g "$guid" -c "$config_name" -a "$ACCOUNT" 2>/dev/null || \
    echo "    Status: UNKNOWN"
}

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r guid; do
    [[ -z "$guid" ]] && continue
    status_one "$guid"
  done < "$MANIFEST"
else
  for i in $(seq 1 "$NUM_STUDENTS"); do
    status_one "${BASE_GUID}-s${i}"
  done
fi

# If hub is running, show RHACM managed clusters
HUB_OUTPUT="${AGNOSTICD_ROOT}/../agnosticd-v2-output/${HUB_GUID}"
for candidate in \
  "${HUB_OUTPUT}/kubeconfig" \
  "${HUB_OUTPUT}/ocp4-cluster/auth/kubeconfig" \
  "${HUB_OUTPUT}/auth/kubeconfig"; do
  if [[ -f "$candidate" ]]; then
    echo ""
    echo "--- RHACM Managed Clusters ---"
    KUBECONFIG="$candidate" oc get managedclusters 2>/dev/null || \
      echo "  Could not query RHACM (hub may be stopped)"
    break
  fi
done
