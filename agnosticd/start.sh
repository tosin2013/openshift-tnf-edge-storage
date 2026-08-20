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

start_tna_instances() {
  local guid="$1"
  echo "==> Starting TNA instances for $guid ..."

  # Wait for any instances still transitioning (stopping→stopped)
  local all_ids
  all_ids="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:guid,Values=${guid}" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$all_ids" && "$all_ids" != "None" ]]; then
    local stopping
    stopping="$(aws ec2 describe-instances --region "$AWS_REGION" \
      --filters "Name=tag:guid,Values=${guid}" "Name=instance-state-name,Values=stopping" \
      --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
    if [[ -n "$stopping" && "$stopping" != "None" ]]; then
      echo "  Waiting for instances to finish stopping ..."
      aws ec2 wait instance-stopped --region "$AWS_REGION" --instance-ids $stopping
    fi
  fi

  local instance_ids
  instance_ids="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:guid,Values=${guid}" "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)"
  if [[ -n "$instance_ids" && "$instance_ids" != "None" ]]; then
    aws ec2 start-instances --region "$AWS_REGION" --instance-ids $instance_ids || \
      echo "WARNING: Failed to start instances for $guid"
    echo "  Started: $instance_ids"
    echo "  Waiting for instances to reach running state ..."
    aws ec2 wait instance-running --region "$AWS_REGION" --instance-ids $instance_ids
    echo "  Instances running. Waiting 60s for OpenShift nodes to rejoin ..."
    sleep 60
  else
    echo "  No stopped instances found for $guid"
  fi
}

# Start hub first (RHACM + Showroom must be up before students reconnect)
if [[ "$START_HUB" == "true" ]]; then
  echo "==> Starting hub ($HUB_GUID) ..."
  AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" start -g "$HUB_GUID" -c linbit-hub -a "$ACCOUNT"
  echo "Hub started. Waiting 60s for RHACM to stabilize..."
  sleep 60
fi

# Start student clusters
echo "Starting student cluster(s) ..."

start_one() {
  local guid="$1"
  local method
  method="$(student_deploy_method "$guid")"
  if [[ "$method" == "agent-based" ]]; then
    start_tna_instances "$guid"
  else
    local student_num="${guid##*-s}"
    local config_name="linbit-student-${student_num}"
    [[ -f "${AGNOSTICD_VARS}/${config_name}.yml" ]] || config_name="linbit-student"
    echo "==> Starting $guid ..."
    AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" start -g "$guid" -c "$config_name" -a "$ACCOUNT" || \
      echo "WARNING: Failed to start $guid"
  fi
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
