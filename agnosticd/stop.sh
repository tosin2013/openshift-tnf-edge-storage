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
# Copy, not symlink — EE containers cannot follow host symlinks
cp "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"
cp "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/linbit-student.yml"

AWS_REGION="${AWS_REGION:-us-east-2}"

cd "$AGNOSTICD_ROOT"

# Detect deploy method for a student guid
student_deploy_method() {
  local guid="$1"
  local status
  status="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
    --stack-name "tna-${guid}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo 'NONE')"
  [[ "$status" != "NONE" && "$status" != "DELETE_COMPLETE" ]] && echo "agent-based" || echo "ipi"
}

stop_tna_instances() {
  local guid="$1"
  echo "==> Stopping TNA instances for $guid ..."
  local instance_ids
  instance_ids="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:guid,Values=${guid}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$instance_ids" && "$instance_ids" != "None" ]]; then
    aws ec2 stop-instances --region "$AWS_REGION" --instance-ids $instance_ids || \
      echo "WARNING: Failed to stop instances for $guid"
    echo "  Stopped: $instance_ids"
  else
    echo "  No running instances found for $guid"
  fi
}

# Stop student clusters first
echo "Stopping student cluster(s) ..."

stop_one() {
  local guid="$1"
  local method
  method="$(student_deploy_method "$guid")"
  if [[ "$method" == "agent-based" ]]; then
    stop_tna_instances "$guid"
  else
    local student_num="${guid##*-s}"
    local config_name="linbit-student-${student_num}"
    [[ -f "${AGNOSTICD_VARS}/${config_name}.yml" ]] || config_name="linbit-student"
    echo "==> Stopping $guid ..."
    AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" stop -g "$guid" -c "$config_name" -a "$ACCOUNT" || \
      echo "WARNING: Failed to stop $guid"
  fi
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
  AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" stop -g "$HUB_GUID" -c linbit-hub -a "$ACCOUNT"
fi

echo "All clusters stopped."
