#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — TNA Student Cluster Deploy
# Provisions a true TNA (2 CP + 1 arbiter) OpenShift cluster on AWS
# using CloudFormation for infrastructure and agent-based installer
# for OpenShift.
#
# Called by deploy.sh Phase 3 for each student cluster.
#
# Usage:
#   ./agnosticd/deploy-tna.sh --guid linbit-s1 \
#     --account sandbox2530 --region us-east-2
#
# Environment / config.yml variables:
#   BASE_DOMAIN, PULL_SECRET_PATH, SSH_KEY_PATH,
#   CP_INSTANCE_TYPE, ARBITER_INSTANCE_TYPE,
#   OCP_VERSION, AGNOSTICD_ROOT
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_TEMPLATE="${SCRIPT_DIR}/cloudformation/tna-student.yaml"

# ─── Defaults (overridable via env or config.yml) ────────────────────────────

GUID=""
ACCOUNT="${ACCOUNT:-}"
AWS_REGION="${AWS_REGION:-us-east-2}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
PULL_SECRET_PATH="${PULL_SECRET_PATH:-$HOME/pull-secret.json}"
if [[ -z "${SSH_KEY_PATH:-}" ]]; then
  for _key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
    [[ -f "$_key" ]] && SSH_KEY_PATH="$_key" && break
  done
fi
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/id_rsa.pub}"
CP_INSTANCE_TYPE="${CP_INSTANCE_TYPE:-m7a.4xlarge}"
ARBITER_INSTANCE_TYPE="${ARBITER_INSTANCE_TYPE:-m7a.xlarge}"
OCP_VERSION="${OCP_VERSION:-4.22}"
OWNER="${OWNER:-tosin@redhat.com}"
MACHINE_CIDR="${MACHINE_CIDR:-10.0.0.0/16}"
SUBNET_CIDR="${SUBNET_CIDR:-10.0.1.0/24}"

# Where generated assets and kubeconfigs are stored
OUTPUT_ROOT="${OUTPUT_ROOT:-$HOME/Development/agnosticd-v2-output}"

# S3 bucket for agent ISOs (created if missing)
S3_BUCKET="${S3_BUCKET:-linbit-workshop-agent-isos}"

# ─── CLI args ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case "$1" in
    --guid)       GUID="$2"; shift 2 ;;
    --account)    ACCOUNT="$2"; shift 2 ;;
    --region)     AWS_REGION="$2"; shift 2 ;;
    --domain)     BASE_DOMAIN="$2"; shift 2 ;;
    --ocp-version) OCP_VERSION="$2"; shift 2 ;;
    --cp-type)    CP_INSTANCE_TYPE="$2"; shift 2 ;;
    --arb-type)   ARBITER_INSTANCE_TYPE="$2"; shift 2 ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$GUID" ]]; then
  echo "ERROR: --guid is required (e.g. linbit-s1)"
  exit 1
fi

# Load config.yml if env vars are empty (standalone invocation)
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS=': ' read -r key value; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${value%\"}" ; value="${value#\"}"
    upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    if [[ -z "${!upper_key:-}" ]]; then
      export "$upper_key=$value"
    fi
  done < "$CONFIG_FILE"
fi

[[ -n "$BASE_DOMAIN" ]] || fail "BASE_DOMAIN must be set (via env, --domain, or config.yml)"
[[ -n "$ACCOUNT" ]] || ACCOUNT="${BASE_DOMAIN%%.*}"

CLUSTER_NAME="$GUID"
STACK_NAME="tna-${CLUSTER_NAME}"
ASSETS_DIR="${OUTPUT_ROOT}/${GUID}/agent-assets"
KUBECONFIG_OUT="${OUTPUT_ROOT}/${GUID}/auth/kubeconfig"

mkdir -p "$ASSETS_DIR" "${OUTPUT_ROOT}/${GUID}/auth"

# ─── Helpers ─────────────────────────────────────────────────────────────────

info()  { echo "[INFO]  $*"; }
ok()    { echo "[OK]    $*"; }
fail()  { echo "[FAIL]  $*"; exit 1; }
warn()  { echo "[WARN]  $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || fail "$1 is required but not found"
}

get_stack_output() {
  local key="$1"
  aws cloudformation describe-stacks \
    --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
    --output text
}

get_mac_address() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].NetworkInterfaces[0].MacAddress' \
    --output text
}

# ─── Preflight ───────────────────────────────────────────────────────────────

for cmd in aws oc jq openshift-install python3; do
  require_cmd "$cmd"
done

[[ -f "$PULL_SECRET_PATH" ]] || fail "Pull secret not found at $PULL_SECRET_PATH"
[[ -f "$SSH_KEY_PATH" ]] || fail "SSH key not found at $SSH_KEY_PATH"
[[ -f "$CFN_TEMPLATE" ]] || fail "CloudFormation template not found at $CFN_TEMPLATE"

PULL_SECRET="$(cat "$PULL_SECRET_PATH" | tr -d '\n')"
SSH_KEY="$(cat "$SSH_KEY_PATH")"

# ─── Resolve Route53 Hosted Zone ─────────────────────────────────────────────

info "Resolving Route53 hosted zone for ${BASE_DOMAIN} ..."
HOSTED_ZONE_ID="$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" \
  --output text | sed 's|/hostedzone/||')"

[[ -n "$HOSTED_ZONE_ID" ]] || fail "No Route53 hosted zone found for ${BASE_DOMAIN}"
info "Hosted zone: $HOSTED_ZONE_ID"

# =================================================================
# Phase 1: Create or reuse AMI from agent-based ISO
# =================================================================

info "============================================================"
info "Phase 1: Prepare agent-based installer ISO -> AMI"
info "============================================================"

ensure_s3_bucket() {
  if ! aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" 2>/dev/null; then
    info "Creating S3 bucket: $S3_BUCKET"
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION"
    else
      aws s3api create-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" \
        --create-bucket-configuration LocationConstraint="$AWS_REGION"
    fi
  fi
}

ensure_vmimport_role() {
  if ! aws iam get-role --role-name vmimport 2>/dev/null; then
    info "Creating vmimport IAM role for EC2 image import ..."
    aws iam create-role --role-name vmimport \
      --assume-role-policy-document '{
        "Version": "2012-10-17",
        "Statement": [{"Effect": "Allow","Principal": {"Service": "vmie.amazonaws.com"},"Action": "sts:AssumeRole","Condition": {"StringEquals": {"sts:Externalid": "vmimport"}}}]
      }'
    aws iam put-role-policy --role-name vmimport --policy-name vmimport \
      --policy-document "{
        \"Version\": \"2012-10-17\",
        \"Statement\": [{\"Effect\": \"Allow\",\"Action\": [\"s3:GetBucketLocation\",\"s3:GetObject\",\"s3:ListBucket\"],\"Resource\": [\"arn:aws:s3:::${S3_BUCKET}\",\"arn:aws:s3:::${S3_BUCKET}/*\"]},{\"Effect\": \"Allow\",\"Action\": [\"ec2:ModifySnapshotAttribute\",\"ec2:CopySnapshot\",\"ec2:RegisterImage\",\"ec2:Describe*\"],\"Resource\": \"*\"}]
      }"
  fi
}

# Check for cached AMI tagged with our OCP version
AGENT_AMI_ID=""
CACHED_AMI="$(aws ec2 describe-images --region "$AWS_REGION" --owners self \
  --filters "Name=tag:ocp-version,Values=${OCP_VERSION}" "Name=tag:purpose,Values=linbit-agent-iso" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text 2>/dev/null || true)"

if [[ -n "$CACHED_AMI" && "$CACHED_AMI" != "None" ]]; then
  info "Reusing cached agent AMI: $CACHED_AMI (OCP ${OCP_VERSION})"
  AGENT_AMI_ID="$CACHED_AMI"
else
  info "No cached AMI found for OCP ${OCP_VERSION}. Building agent ISO ..."

  # Render install-config and agent-config for ISO generation.
  # The ISO is generic (no node-specific MACs) — we re-render configs
  # after CFN stack is up with real IPs/MACs.
  ISO_BUILD_DIR="${ASSETS_DIR}/iso-build"
  rm -rf "$ISO_BUILD_DIR"
  mkdir -p "$ISO_BUILD_DIR"

  # install-config for TNA (Two-Node with Arbiter)
  cat > "${ISO_BUILD_DIR}/install-config.yaml" <<INSTALLEOF
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
controlPlane:
  architecture: amd64
  name: master
  replicas: 2
  platform: {}
arbiter:
  architecture: amd64
  name: arbiter
  replicas: 1
  platform: {}
compute:
  - architecture: amd64
    name: worker
    replicas: 0
    platform: {}
networking:
  networkType: OVNKubernetes
  clusterNetwork:
    - cidr: 10.128.0.0/14
      hostPrefix: 23
  serviceNetwork:
    - 172.30.0.0/16
  machineNetwork:
    - cidr: ${MACHINE_CIDR}
platform:
  none: {}
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
INSTALLEOF

  # agent-config with 3 hosts: 2 masters + 1 arbiter
  cat > "${ISO_BUILD_DIR}/agent-config.yaml" <<AGENTEOF
apiVersion: v1beta1
metadata:
  name: ${CLUSTER_NAME}
rendezvousIP: 10.0.1.10
hosts:
  - hostname: master-0
    role: master
    interfaces:
      - name: enX0
        macAddress: 00:00:00:00:00:01
  - hostname: master-1
    role: master
    interfaces:
      - name: enX0
        macAddress: 00:00:00:00:00:02
  - hostname: arbiter-0
    role: arbiter
    interfaces:
      - name: enX0
        macAddress: 00:00:00:00:00:03
AGENTEOF

  info "Generating agent ISO ..."
  openshift-install agent create image --dir "$ISO_BUILD_DIR" --log-level info

  ISO_PATH="${ISO_BUILD_DIR}/agent.x86_64.iso"
  [[ -f "$ISO_PATH" ]] || fail "Agent ISO not generated at $ISO_PATH"

  ensure_s3_bucket
  ensure_vmimport_role

  # Convert ISO to raw disk image — AWS import-snapshot needs a disk
  # format, not ISO 9660. The agent ISO is a hybrid image that can be
  # written directly to a disk.
  RAW_PATH="${ISO_BUILD_DIR}/agent.raw"
  info "Converting ISO to raw disk image ..."
  cp "$ISO_PATH" "$RAW_PATH"
  # Pad to 16 GiB so the root volume has enough space for the
  # in-place CoreOS install that the agent-based installer performs.
  truncate -s 16G "$RAW_PATH"

  S3_KEY="agent-iso/agent-${OCP_VERSION}-${CLUSTER_NAME}.raw"
  info "Uploading raw image to s3://${S3_BUCKET}/${S3_KEY} ..."
  aws s3 cp "$RAW_PATH" "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION"

  # Use import-snapshot (not import-image) — it does not try to detect
  # an OS, which avoids the "Unknown OS / Missing OS files" error.
  info "Importing raw image as EBS snapshot (10-20 min) ..."
  SNAP_IMPORT_ID="$(aws ec2 import-snapshot --region "$AWS_REGION" \
    --description "LINBIT Agent ISO OCP ${OCP_VERSION}" \
    --disk-container "{\"Description\":\"agent-iso\",\"Format\":\"RAW\",\"UserBucket\":{\"S3Bucket\":\"${S3_BUCKET}\",\"S3Key\":\"${S3_KEY}\"}}" \
    --query 'ImportTaskId' --output text)"

  info "Snapshot import task: $SNAP_IMPORT_ID — waiting ..."
  SNAPSHOT_ID=""
  while true; do
    SNAP_JSON="$(aws ec2 describe-import-snapshot-tasks --region "$AWS_REGION" \
      --import-task-ids "$SNAP_IMPORT_ID" \
      --query 'ImportSnapshotTasks[0].SnapshotTaskDetail' --output json)"
    SNAP_STATUS="$(echo "$SNAP_JSON" | jq -r '.Status')"
    case "$SNAP_STATUS" in
      completed)
        SNAPSHOT_ID="$(echo "$SNAP_JSON" | jq -r '.SnapshotId')"
        break
        ;;
      active)
        SNAP_PROGRESS="$(echo "$SNAP_JSON" | jq -r '.Progress // "?"')"
        info "  Snapshot import: ${SNAP_STATUS} (${SNAP_PROGRESS}%) ..."
        sleep 30
        ;;
      *)
        SNAP_MSG="$(echo "$SNAP_JSON" | jq -r '.StatusMessage // "unknown"')"
        fail "Snapshot import failed: ${SNAP_STATUS} — ${SNAP_MSG}"
        ;;
    esac
  done

  ok "Snapshot created: $SNAPSHOT_ID"

  # Register an AMI from the snapshot
  info "Registering AMI from snapshot ..."
  AGENT_AMI_ID="$(aws ec2 register-image --region "$AWS_REGION" \
    --name "linbit-agent-ocp${OCP_VERSION}-$(date +%Y%m%d%H%M)" \
    --description "LINBIT Agent-based Installer OCP ${OCP_VERSION}" \
    --architecture x86_64 \
    --root-device-name /dev/sda1 \
    --virtualization-type hvm \
    --ena-support \
    --boot-mode uefi-preferred \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"${SNAPSHOT_ID}\",\"VolumeSize\":16,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --query 'ImageId' --output text)"

  # Tag for reuse
  aws ec2 create-tags --region "$AWS_REGION" --resources "$AGENT_AMI_ID" "$SNAPSHOT_ID" \
    --tags Key=ocp-version,Value="${OCP_VERSION}" Key=purpose,Value=linbit-agent-iso Key=Name,Value="linbit-agent-ocp${OCP_VERSION}"

  ok "Agent AMI created: $AGENT_AMI_ID (snapshot: $SNAPSHOT_ID)"

  # Clean up S3 object (raw image is large)
  rm -f "$RAW_PATH"
  aws s3 rm "s3://${S3_BUCKET}/${S3_KEY}" --region "$AWS_REGION" 2>/dev/null || true
fi

# =================================================================
# Phase 2: CloudFormation — provision VPC + EC2 + NLB + DNS
# =================================================================

info "============================================================"
info "Phase 2: CloudFormation stack (${STACK_NAME})"
info "============================================================"

STACK_EXISTS="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo 'NONE')"

if [[ "$STACK_EXISTS" == "NONE" || "$STACK_EXISTS" == "DELETE_COMPLETE" ]]; then
  info "Creating CloudFormation stack ..."
  aws cloudformation create-stack \
    --region "$AWS_REGION" \
    --stack-name "$STACK_NAME" \
    --template-body "file://${CFN_TEMPLATE}" \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameters \
      ParameterKey=ClusterName,ParameterValue="${CLUSTER_NAME}" \
      ParameterKey=BaseDomain,ParameterValue="${BASE_DOMAIN}" \
      ParameterKey=HostedZoneId,ParameterValue="${HOSTED_ZONE_ID}" \
      ParameterKey=AmiId,ParameterValue="${AGENT_AMI_ID}" \
      ParameterKey=CPInstanceType,ParameterValue="${CP_INSTANCE_TYPE}" \
      ParameterKey=ArbiterInstanceType,ParameterValue="${ARBITER_INSTANCE_TYPE}" \
      ParameterKey=Owner,ParameterValue="${OWNER}" \
      ParameterKey=VpcCidr,ParameterValue="${MACHINE_CIDR}" \
      ParameterKey=SubnetCidr,ParameterValue="${SUBNET_CIDR}" \
    --tags Key=owner,Value="${OWNER}" Key=guid,Value="${CLUSTER_NAME}" Key=Purpose,Value=linbit-workshop-student

  info "Waiting for stack creation (5-10 min) ..."
  aws cloudformation wait stack-create-complete \
    --region "$AWS_REGION" --stack-name "$STACK_NAME"
  ok "Stack created."
elif [[ "$STACK_EXISTS" == "CREATE_COMPLETE" || "$STACK_EXISTS" == "UPDATE_COMPLETE" ]]; then
  info "Stack ${STACK_NAME} already exists (${STACK_EXISTS}). Reusing."
else
  fail "Stack ${STACK_NAME} is in unexpected state: ${STACK_EXISTS}"
fi

# Extract outputs
CP0_ID="$(get_stack_output ControlPlane0InstanceId)"
CP1_ID="$(get_stack_output ControlPlane1InstanceId)"
ARB_ID="$(get_stack_output Arbiter0InstanceId)"
CP0_IP="$(get_stack_output ControlPlane0PrivateIp)"
CP1_IP="$(get_stack_output ControlPlane1PrivateIp)"
ARB_IP="$(get_stack_output Arbiter0PrivateIp)"
API_URL="$(get_stack_output APIURL)"
CONSOLE_URL="$(get_stack_output ConsoleURL)"

info "Instance IDs: CP0=$CP0_ID CP1=$CP1_ID ARB=$ARB_ID"
info "Private IPs:  CP0=$CP0_IP CP1=$CP1_IP ARB=$ARB_IP"
info "API URL:      $API_URL"

# =================================================================
# Phase 3: Verify host registration (generic ISO is sufficient)
# =================================================================
# The generic AMI uses dummy MAC addresses in agent-config.yaml.
# However, the assisted-installer auto-assigns roles based on
# host resources: larger instances → master, smallest → arbiter.
# With m7a.4xlarge (CP) vs m7a.xlarge (arbiter), role assignment
# is deterministic without MAC matching.
#
# We still collect MAC addresses here for reference/debugging.

info "============================================================"
info "Phase 3: Collecting instance metadata"
info "============================================================"

CP0_MAC="$(get_mac_address "$CP0_ID")"
CP1_MAC="$(get_mac_address "$CP1_ID")"
ARB_MAC="$(get_mac_address "$ARB_ID")"

info "MAC addresses: CP0=$CP0_MAC CP1=$CP1_MAC ARB=$ARB_MAC"

# Save MAC info for debugging
cat > "${ASSETS_DIR}/instance-macs.txt" <<EOF
CP0: instance=$CP0_ID ip=$CP0_IP mac=$CP0_MAC
CP1: instance=$CP1_ID ip=$CP1_IP mac=$CP1_MAC
ARB: instance=$ARB_ID ip=$ARB_IP mac=$ARB_MAC
EOF

# The WAIT_DIR for openshift-install commands uses the initial ISO build
# (which contains the .openshift_install_state.json needed by wait-for).
WAIT_DIR="${ASSETS_DIR}/iso-build"

# =================================================================
# Phase 4: Wait for coreos-installer, then volume swap
# =================================================================
# On EC2, the instance always boots from /dev/sda1 (the root device).
# coreos-installer writes RHCOS to the second disk (/dev/xvdb → nvme1n1).
# After writing, nodes reboot — but boot BACK into the ISO.
# We must: detect write complete → stop instances → swap disks → restart.

info "============================================================"
info "Phase 4: Monitor install + post-write volume swap"
info "============================================================"

SSH_KEY_PRIV="${SSH_KEY_PATH%.pub}"

# Get CP0 public IP for API access
CP0_PUBLIC_IP="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --instance-ids "$CP0_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

info "Rendezvous host public IP: $CP0_PUBLIC_IP"
info "Waiting for assisted-service API to be available ..."

for _wait in $(seq 1 90); do
  if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PRIV" \
     core@"$CP0_PUBLIC_IP" "curl -sf http://10.0.1.10:8090/api/assisted-install/v2/clusters" &>/dev/null; then
    break
  fi
  sleep 10
done

# Retrieve auth token and IDs from the rendezvous host
AUTH_TOKEN="$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PRIV" core@"$CP0_PUBLIC_IP" \
  'grep USER_AUTH_TOKEN /etc/assisted/rendezvous-host.env | cut -d= -f2')"

INFRA_ENV_ID="$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PRIV" core@"$CP0_PUBLIC_IP" \
  "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs -H 'Authorization: ${AUTH_TOKEN}' | jq -r '.[0].id'")"

CLUSTER_ID="$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PRIV" core@"$CP0_PUBLIC_IP" \
  "curl -s http://10.0.1.10:8090/api/assisted-install/v2/clusters -H 'Authorization: ${AUTH_TOKEN}' | jq -r '.[0].id'")"

info "Cluster ID: $CLUSTER_ID  Infra Env: $INFRA_ENV_ID"

# Wait for all hosts to register and pass validation
info "Waiting for all hosts to be ready ..."
for _wait in $(seq 1 120); do
  KNOWN_COUNT="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PRIV" \
    core@"$CP0_PUBLIC_IP" \
    "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs/${INFRA_ENV_ID}/hosts \
    -H 'Authorization: ${AUTH_TOKEN}' | jq '[.[] | select(.status==\"known\")] | length'" 2>/dev/null || echo 0)"
  [[ "$KNOWN_COUNT" -ge 3 ]] && break
  info "  Known hosts: ${KNOWN_COUNT}/3 ..."
  sleep 15
done
[[ "$KNOWN_COUNT" -ge 3 ]] || fail "Timeout: only ${KNOWN_COUNT}/3 hosts ready after 30 min"
ok "All 3 hosts registered and validated."

# Trigger installation
info "Triggering cluster installation ..."
INSTALL_HTTP="$(ssh -o StrictHostKeyChecking=no -i "$SSH_KEY_PRIV" core@"$CP0_PUBLIC_IP" \
  "curl -s -X POST 'http://10.0.1.10:8090/api/assisted-install/v2/clusters/${CLUSTER_ID}/actions/install' \
  -H 'Authorization: ${AUTH_TOKEN}' -w '%{http_code}' -o /dev/null")"
[[ "$INSTALL_HTTP" == "202" ]] || fail "Failed to trigger installation (HTTP $INSTALL_HTTP)"
ok "Installation triggered (HTTP 202)."

# Poll host progress until all finish writing (reach "Rebooting" or API drops)
info "Monitoring coreos-installer progress ..."
WRITE_COMPLETE=false
for _poll in $(seq 1 180); do
  HOST_JSON="$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$SSH_KEY_PRIV" \
    core@"$CP0_PUBLIC_IP" \
    "curl -s http://10.0.1.10:8090/api/assisted-install/v2/infra-envs/${INFRA_ENV_ID}/hosts \
    -H 'Authorization: ${AUTH_TOKEN}'" 2>/dev/null || echo "UNREACHABLE")"

  if [[ "$HOST_JSON" == "UNREACHABLE" || -z "$HOST_JSON" ]]; then
    info "  API unreachable — rendezvous host likely rebooting."
    WRITE_COMPLETE=true
    break
  fi

  STAGES="$(echo "$HOST_JSON" | jq -r '.[].progress.current_stage // "unknown"' 2>/dev/null || echo "error")"
  REBOOTING=$(echo "$STAGES" | grep -c "Rebooting" || true)
  WRITING=$(echo "$STAGES" | grep -c "Writing" || true)
  CONFIGURING=$(echo "$STAGES" | grep -c "Configuring" || true)
  DONE=$(echo "$STAGES" | grep -c "Done" || true)

  info "  Stages: writing=$WRITING configuring=$CONFIGURING rebooting=$REBOOTING done=$DONE"

  # If at least 2 hosts have moved past writing, we're close
  if [[ $((REBOOTING + DONE)) -ge 2 ]]; then
    info "  Majority past writing stage. Waiting 30s for final host ..."
    sleep 30
    WRITE_COMPLETE=true
    break
  fi

  # Check for errors
  ERRORS=$(echo "$HOST_JSON" | jq -r '[.[] | select(.status=="error")] | length' 2>/dev/null || echo 0)
  if [[ "$ERRORS" -gt 0 ]]; then
    ERROR_INFO="$(echo "$HOST_JSON" | jq -r '.[] | select(.status=="error") | "\(.requested_hostname): \(.status_info)"' 2>/dev/null)"
    fail "Host(s) in error state:\n$ERROR_INFO"
  fi

  sleep 10
done

[[ "$WRITE_COMPLETE" == "true" ]] || fail "Timeout waiting for coreos-installer to finish"
ok "coreos-installer completed on all hosts."

# Wait for instances to finish rebooting back into ISO
info "Waiting 60s for reboot cycle to complete ..."
sleep 60

# Post-install volume swap: move RHCOS disk to root device position
info "Stopping instances for post-install volume swap ..."
aws ec2 stop-instances --region "$AWS_REGION" \
  --instance-ids "$CP0_ID" "$CP1_ID" "$ARB_ID" >/dev/null
aws ec2 wait instance-stopped --region "$AWS_REGION" \
  --instance-ids "$CP0_ID" "$CP1_ID" "$ARB_ID"
ok "All instances stopped."

post_install_swap() {
  local instance_id="$1"
  local label="$2"

  info "  Swapping volumes on $label ($instance_id) ..."

  # Find current root volume (/dev/sda1 or /dev/xvda — the old ISO)
  local old_root_vol
  old_root_vol="$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=attachment.instance-id,Values=$instance_id" \
    --query 'Volumes[?Attachments[0].Device==`/dev/sda1` || Attachments[0].Device==`/dev/xvda`].VolumeId' \
    --output text | head -1)"

  # Find the RHCOS volume (/dev/xvdb — where coreos-installer wrote)
  local rhcos_vol
  rhcos_vol="$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=attachment.instance-id,Values=$instance_id" \
    --query 'Volumes[?Attachments[0].Device==`/dev/xvdb`].VolumeId' \
    --output text | head -1)"

  if [[ -z "$rhcos_vol" || "$rhcos_vol" == "None" ]]; then
    fail "Cannot find RHCOS volume (/dev/xvdb) on $label"
  fi

  # Detach old root (ISO)
  if [[ -n "$old_root_vol" && "$old_root_vol" != "None" ]]; then
    aws ec2 detach-volume --region "$AWS_REGION" --volume-id "$old_root_vol" --force >/dev/null 2>&1 || true
  fi

  # Detach RHCOS volume from /dev/xvdb
  aws ec2 detach-volume --region "$AWS_REGION" --volume-id "$rhcos_vol" --force >/dev/null 2>&1 || true

  # Wait for both to detach
  sleep 8

  # Attach RHCOS volume as root device (/dev/sda1)
  aws ec2 attach-volume --region "$AWS_REGION" \
    --instance-id "$instance_id" \
    --volume-id "$rhcos_vol" \
    --device /dev/sda1 >/dev/null

  # Wait for attachment
  for _ in $(seq 1 30); do
    local att_state
    att_state="$(aws ec2 describe-volumes --region "$AWS_REGION" \
      --volume-ids "$rhcos_vol" \
      --query 'Volumes[0].Attachments[0].State' --output text)"
    [[ "$att_state" == "attached" ]] && break
    sleep 2
  done

  # Delete old ISO volume
  if [[ -n "$old_root_vol" && "$old_root_vol" != "None" ]]; then
    aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$old_root_vol" 2>/dev/null || true
  fi

  info "  $label: RHCOS volume $rhcos_vol now at /dev/sda1"
}

post_install_swap "$CP0_ID" "cp-0"
post_install_swap "$CP1_ID" "cp-1"
post_install_swap "$ARB_ID" "arbiter-0"

info "Starting instances with RHCOS as root device ..."
aws ec2 start-instances --region "$AWS_REGION" \
  --instance-ids "$CP0_ID" "$CP1_ID" "$ARB_ID" >/dev/null
aws ec2 wait instance-running --region "$AWS_REGION" \
  --instance-ids "$CP0_ID" "$CP1_ID" "$ARB_ID"
ok "All instances booting into installed RHCOS."

# =================================================================
# Phase 5: Wait for OpenShift bootstrap + install completion
# =================================================================

info "============================================================"
info "Phase 5: Waiting for OpenShift bootstrap and install"
info "============================================================"

openshift-install agent wait-for bootstrap-complete \
  --dir "$WAIT_DIR" --log-level info 2>&1 | while IFS= read -r line; do
  echo "  [bootstrap] $line"
done || warn "Bootstrap wait returned non-zero (may already be complete)"

openshift-install agent wait-for install-complete \
  --dir "$WAIT_DIR" --log-level info 2>&1 | while IFS= read -r line; do
  echo "  [install] $line"
done

# Extract kubeconfig
if [[ -f "${WAIT_DIR}/auth/kubeconfig" ]]; then
  cp "${WAIT_DIR}/auth/kubeconfig" "$KUBECONFIG_OUT"
  ok "Kubeconfig saved to $KUBECONFIG_OUT"
else
  fail "Kubeconfig not found after installation"
fi

if [[ -f "${WAIT_DIR}/auth/kubeadmin-password" ]]; then
  cp "${WAIT_DIR}/auth/kubeadmin-password" "${OUTPUT_ROOT}/${GUID}/auth/kubeadmin-password"
fi

export KUBECONFIG="$KUBECONFIG_OUT"

info "Waiting for cluster API ..."
for _retry in $(seq 1 30); do
  if oc get nodes &>/dev/null; then
    ok "Cluster API is reachable."
    break
  fi
  sleep 10
done

# =================================================================
# Phase 6: Post-install — labels, taints, workloads
# =================================================================

info "============================================================"
info "Phase 6: Post-install configuration"
info "============================================================"

# Label control-plane nodes as primary storage nodes
info "Labeling control-plane nodes as LINBIT primary storage ..."
for node in $(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}'); do
  # Skip the arbiter node (smallest instance, no data disk)
  NODE_INSTANCE_ID="$(oc get node "$node" -o jsonpath='{.spec.providerID}' | awk -F'/' '{print $NF}')"
  if [[ "$NODE_INSTANCE_ID" == "$ARB_ID" ]]; then
    info "  Arbiter node: $node — labeling as arbiter + taint"
    oc label node "$node" linbit.com/storage-role=arbiter --overwrite
    oc adm taint nodes "$node" linbit.com/arbiter=true:NoSchedule --overwrite 2>/dev/null || true
  else
    info "  Primary node: $node — labeling as primary"
    oc label node "$node" linbit.com/storage-role=primary --overwrite
  fi
done

# Allow scheduling workloads on control-plane nodes (no dedicated workers)
info "Allowing workload scheduling on control-plane nodes ..."
oc patch schedulers.config.openshift.io cluster --type=merge \
  -p '{"spec":{"mastersSchedulable":true}}' || true

ok "Node labels and scheduling configured."

# =================================================================
# Phase 7: Install and configure LINSTOR storage
# =================================================================

info "============================================================"
info "Phase 7: LINSTOR Operator + storage pools"
info "============================================================"

# Load LINBIT registry credentials from secrets
SECRETS_FILE="${SECRETS_FILE:-$HOME/Development/agnosticd-v2-secrets/secrets.yml}"
if [[ -f "$SECRETS_FILE" ]]; then
  LINBIT_USER="$(grep 'linbit_registry_username' "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')"
  LINBIT_PASS="$(grep 'linbit_registry_password' "$SECRETS_FILE" | awk '{print $2}' | tr -d '"')"
else
  warn "Secrets file not found at $SECRETS_FILE"
  LINBIT_USER="${LINBIT_REGISTRY_USERNAME:-}"
  LINBIT_PASS="${LINBIT_REGISTRY_PASSWORD:-}"
fi

if [[ -z "$LINBIT_USER" || -z "$LINBIT_PASS" ]]; then
  warn "LINBIT registry credentials not available — skipping LINSTOR install."
  warn "Set LINBIT_REGISTRY_USERNAME/LINBIT_REGISTRY_PASSWORD or provide secrets.yml"
else
  info "Creating linbit-sds namespace and operator resources ..."
  oc create namespace linbit-sds 2>/dev/null || true

  # OperatorGroup
  cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: linbit-sds-og
  namespace: linbit-sds
spec:
  targetNamespaces:
    - linbit-sds
EOF

  # Pull secret for drbd.io registry
  oc create secret docker-registry drbdio-pull-secret \
    --namespace linbit-sds \
    --docker-server=drbd.io \
    --docker-username="$LINBIT_USER" \
    --docker-password="$LINBIT_PASS" \
    2>/dev/null || true

  # LINSTOR Operator Subscription
  cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: linstor-operator
  namespace: linbit-sds
spec:
  channel: stable-v2
  name: linstor-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

  # Wait for CSV
  info "Waiting for LINSTOR Operator CSV to succeed ..."
  for _csv_wait in $(seq 1 60); do
    CSV_NAME="$(oc get csv -n linbit-sds -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$CSV_NAME" ]]; then
      CSV_PHASE="$(oc get csv "$CSV_NAME" -n linbit-sds -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "$CSV_PHASE" == "Succeeded" ]]; then
        ok "LINSTOR Operator installed: $CSV_NAME"
        break
      fi
      info "  CSV: $CSV_NAME Phase: $CSV_PHASE"
    fi
    sleep 10
  done

  if [[ "${CSV_PHASE:-}" != "Succeeded" ]]; then
    fail "LINSTOR Operator CSV did not reach Succeeded state"
  fi

  # LinstorCluster CR with imagePullSecrets and arbiter toleration
  info "Creating LinstorCluster ..."
  cat <<'EOF' | oc apply -f -
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata:
  name: linstorcluster
  namespace: linbit-sds
spec:
  tolerations:
    - key: node-role.kubernetes.io/arbiter
      operator: Exists
      effect: NoSchedule
    - key: linbit.com/arbiter
      operator: Exists
      effect: NoSchedule
  controller:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
  csiController:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
  csiNode:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
  highAvailabilityController:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
  affinityController:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
  nfsServer:
    podTemplate:
      spec:
        imagePullSecrets:
          - name: drbdio-pull-secret
EOF

  # LinstorSatelliteConfiguration for primary (storage) nodes
  info "Creating SatelliteConfiguration for primary nodes ..."
  cat <<'EOF' | oc apply -f -
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: storage-pool-config
  namespace: linbit-sds
spec:
  nodeSelector:
    linbit.com/storage-role: primary
  podTemplate:
    spec:
      imagePullSecrets:
        - name: drbdio-pull-secret
  storagePools:
    - name: lvm-thin
      lvmThinPool:
        volumeGroup: linstor_lvm-thin
      source:
        hostDevices:
          - /dev/nvme2n1
EOF

  # LinstorSatelliteConfiguration for arbiter node (diskless)
  info "Creating SatelliteConfiguration for arbiter ..."
  cat <<'EOF' | oc apply -f -
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata:
  name: arbiter-config
  namespace: linbit-sds
spec:
  nodeSelector:
    linbit.com/storage-role: arbiter
  podTemplate:
    spec:
      imagePullSecrets:
        - name: drbdio-pull-secret
EOF

  # Wait for satellites to come online
  info "Waiting for LINSTOR satellites ..."
  for _sat_wait in $(seq 1 60); do
    SAT_ONLINE="$(oc exec -n linbit-sds deploy/linstor-controller -- \
      linstor node list 2>/dev/null | grep -c "Online" || echo 0)"
    if [[ "$SAT_ONLINE" -ge 3 ]]; then
      ok "All 3 LINSTOR satellites are Online."
      break
    fi
    info "  Satellites online: $SAT_ONLINE/3"
    sleep 10
  done

  # Create StorageClasses
  info "Creating StorageClasses ..."
  cat <<'EOF' | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: linbit-rwo-locality
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: linstor.csi.linbit.com
parameters:
  autoPlace: "2"
  storagePool: lvm-thin
  csi.storage.k8s.io/fstype: xfs
  property.linstor.csi.linbit.com/DrbdOptions/auto-quorum: majority
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-no-quorum: io-error
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
allowVolumeExpansion: true
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: linbit-rwx-virt
provisioner: linstor.csi.linbit.com
parameters:
  autoPlace: "2"
  storagePool: lvm-thin
  property.linstor.csi.linbit.com/DrbdOptions/Net/allow-two-primaries: "yes"
  property.linstor.csi.linbit.com/DrbdOptions/auto-quorum: majority
  property.linstor.csi.linbit.com/DrbdOptions/Resource/on-no-quorum: io-error
volumeBindingMode: Immediate
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

  # Set encryption passphrase (needed for S3 backup remotes)
  info "Setting LINSTOR encryption passphrase ..."
  oc exec -n linbit-sds deploy/linstor-controller -- \
    linstor encryption create-passphrase --passphrase workshop-lab-2024 2>/dev/null || true

  ok "LINSTOR storage stack fully configured."
fi

# =================================================================
# Phase 8: Apply workloads via ansible/manual
# =================================================================

info "============================================================"
info "Phase 8: Applying workloads"
info "============================================================"

info "Cluster $CLUSTER_NAME is ready for workload deployment."
info "  KUBECONFIG=$KUBECONFIG_OUT"
info "  API:     $API_URL"
info "  Console: $CONSOLE_URL"

# Save deployment info
cat > "${OUTPUT_ROOT}/${GUID}/deployment_info.txt" <<EOF
cluster_name=${CLUSTER_NAME}
api_url=${API_URL}
console_url=${CONSOLE_URL}
kubeconfig=${KUBECONFIG_OUT}
cp0_instance_id=${CP0_ID}
cp1_instance_id=${CP1_ID}
arbiter_instance_id=${ARB_ID}
cp0_private_ip=${CP0_IP}
cp1_private_ip=${CP1_IP}
arbiter_private_ip=${ARB_IP}
stack_name=${STACK_NAME}
aws_region=${AWS_REGION}
deploy_method=agent-based
ocp_version=${OCP_VERSION}
EOF

ok "TNA student cluster $CLUSTER_NAME deployed successfully."
echo ""
echo "  API:       $API_URL"
echo "  Console:   $CONSOLE_URL"
echo "  Kubeconfig: $KUBECONFIG_OUT"
