#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Full Teardown
# Destroys student clusters first (deregisters from RHACM), then hub.
#
# Usage:
#   ./agnosticd/teardown.sh                    # destroy everything
#   DESTROY_HUB=false ./agnosticd/teardown.sh  # students only
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_VARS="${AGNOSTICD_ROOT}/../agnosticd-v2-vars"
ACCOUNT="${ACCOUNT:-sandbox2530}"

DESTROY_HUB="${DESTROY_HUB:-true}"
HUB_GUID="${HUB_GUID:-linbit-hub}"

BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

STATE_DIR="${SCRIPT_DIR}/.state"
MANIFEST="${STATE_DIR}/students.txt"

cd "$AGNOSTICD_ROOT"

# -----------------------------------------------------------------
# Phase 1: Destroy student clusters
# -----------------------------------------------------------------
echo "============================================================"
echo "Phase 1: Destroying student cluster(s)"
echo "============================================================"

destroy_student() {
  local guid="$1"
  local student_num="${guid##*-s}"
  local config_name="linbit-student-${student_num}"

  if [[ ! -f "${AGNOSTICD_VARS}/${config_name}.yml" ]]; then
    config_name="linbit-student"
    ln -sf "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/${config_name}.yml"
  fi

  echo "==> Destroying student cluster ($guid) ..."
  ./bin/agd destroy \
    -g "$guid" \
    -c "$config_name" \
    -a "$ACCOUNT" || \
    echo "WARNING: Failed to destroy $guid, continuing..."
}

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r guid; do
    [[ -z "$guid" ]] && continue
    destroy_student "$guid"
  done < "$MANIFEST"
else
  for i in $(seq 1 "$NUM_STUDENTS"); do
    destroy_student "${BASE_GUID}-s${i}"
  done
fi

# -----------------------------------------------------------------
# Phase 2: Destroy hub cluster
# -----------------------------------------------------------------
if [[ "$DESTROY_HUB" == "true" ]]; then
  echo "============================================================"
  echo "Phase 2: Destroying hub cluster ($HUB_GUID)"
  echo "============================================================"

  ln -sf "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"

  ./bin/agd destroy \
    -g "$HUB_GUID" \
    -c linbit-hub \
    -a "$ACCOUNT"
  echo "Hub cluster destroyed."
fi

# Clean up state
rm -f "$MANIFEST" "$STATE_DIR/hub_api_url" "$STATE_DIR/hub_token"

echo ""
echo "============================================================"
echo "Teardown Complete"
echo "============================================================"
