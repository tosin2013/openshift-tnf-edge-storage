#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Config-aware Teardown
# Loads agnosticd/config.yml, destroys student clusters then hub via
# AgnosticD, then sweeps leftover AWS VPCs / NATs / EIPs for this
# workshop (linbit / BASE_GUID).
#
# Usage:
#   make teardown                         # full cleanup from config.yml
#   DESTROY_HUB=false make teardown       # students + orphans only
#   DRY_RUN=true make teardown            # inventory + planned actions
#   make dry-run                          # same (passes --dry-run)
#   make destroy                          # scaffold alias for teardown
#   YES=true make teardown                # non-interactive destroy
#   make teardown ARGS=--yes              # same
#   ./agnosticd/teardown.sh --dry-run
#   ./agnosticd/teardown.sh --yes
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCK_FILE="${SCRIPT_DIR}/.workshop-lock"

# -----------------------------------------------------------------
# Read config.yml (env vars take precedence)
# -----------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/config.yml"
if [[ -f "$CONFIG_FILE" ]]; then
  while IFS=': ' read -r key value; do
    key=$(echo "$key" | tr -d ' ')
    value=$(echo "$value" | tr -d '"' | tr -d "'")
    [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
    upper_key=$(echo "$key" | tr '[:lower:]' '[:upper:]')
    if [[ -z "${!upper_key:-}" ]]; then
      export "$upper_key=$value"
    fi
  done < "$CONFIG_FILE"
fi

AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT/#\~/$HOME}"
AGNOSTICD_VARS="${AGNOSTICD_ROOT}/../agnosticd-v2-vars"
ACCOUNT="${ACCOUNT:-sandbox2530}"
AWS_REGION="${AWS_REGION:-us-east-2}"
HUB_GUID="${HUB_GUID:-linbit-hub}"
BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"
DRY_RUN="${DRY_RUN:-false}"
YES="${YES:-false}"

# CLI flags (env DRY_RUN / YES still work)
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) YES=true ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo "Usage: $0 [--dry-run] [--yes|-y]" >&2
      exit 1
      ;;
  esac
done

# DESTROY_HUB: explicit env wins; else follow deploy_hub from config; else true
if [[ -z "${DESTROY_HUB:-}" ]]; then
  case "${DEPLOY_HUB:-true}" in
    true|True|TRUE|yes|Yes|YES|1) DESTROY_HUB=true ;;
    *) DESTROY_HUB=false ;;
  esac
fi

STATE_DIR="${SCRIPT_DIR}/.state"
MANIFEST="${STATE_DIR}/students.txt"

# -----------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------
info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
ok()    { echo "[OK]   $*"; }
fail()  { echo "[FAIL] $*"; }

acquire_lock() {
  if ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
    trap 'rm -f "$LOCK_FILE"' EXIT
  else
    local holder
    holder="$(cat "$LOCK_FILE" 2>/dev/null || echo unknown)"
    fail "Another lifecycle operation holds the lock ($LOCK_FILE, pid=$holder)"
    exit 1
  fi
}

confirm_destroy() {
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  case "${YES}" in
    true|True|TRUE|yes|Yes|YES|1) return 0 ;;
  esac
  if [[ -t 0 ]]; then
    local ans
    read -r -p "Destroy workshop resources? [y/N] " ans
    [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Aborted."; exit 1; }
  else
    fail "Refusing non-interactive destroy without YES=true or --yes"
    exit 1
  fi
}

run_or_echo() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] $*"
    return 0
  fi
  "$@"
}

guid_is_hub() {
  [[ "$1" == "$HUB_GUID" ]]
}

guid_is_student() {
  local g="$1"
  [[ "$g" == "${BASE_GUID}-s"* ]] && ! guid_is_hub "$g"
}

# -----------------------------------------------------------------
# Stop in-flight linbit provisions that would race teardown
# -----------------------------------------------------------------
stop_inflight_provisions() {
  echo "============================================================"
  echo "Phase 0: Stopping in-flight linbit provision processes"
  echo "============================================================"

  local pids
  pids="$(pgrep -f "guid=${BASE_GUID}|guid=linbit-|output_dir_root/${BASE_GUID}" 2>/dev/null || true)"
  # Also match ansible-navigator / podman for our guids
  local more
  more="$(pgrep -f "ansible-navigator.*guid=${BASE_GUID}|ansible-navigator.*linbit-s|podman run.*linbit-s|deploy\\.sh" 2>/dev/null || true)"
  pids="$(printf '%s\n%s\n' "$pids" "$more" | sort -u | grep -v '^$' || true)"

  if [[ -z "$pids" ]]; then
    ok "No in-flight provision processes found"
    return 0
  fi

  echo "$pids" | while read -r pid; do
    [[ -z "$pid" ]] && continue
    info "Stopping PID $pid: $(ps -p "$pid" -o args= 2>/dev/null | head -c 120 || true)"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY-RUN] kill $pid"
    else
      kill "$pid" 2>/dev/null || true
    fi
  done

  if [[ "$DRY_RUN" != "true" ]]; then
    sleep 2
    # Force-kill stubborn podman/ansible-navigator children
    pids="$(pgrep -f "ansible-navigator.*linbit-|podman run.*linbit-|deploy\\.sh" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
      echo "$pids" | xargs -r kill -9 2>/dev/null || true
    fi
  fi
  ok "In-flight stop attempted"
}

# -----------------------------------------------------------------
# Discover student + hub guids (union, de-duped)
# -----------------------------------------------------------------
declare -a STUDENT_GUIDS=()
declare -A SEEN_GUIDS=()

add_student_guid() {
  local g="$1"
  [[ -z "$g" ]] && return
  guid_is_hub "$g" && return
  if [[ -z "${SEEN_GUIDS[$g]:-}" ]]; then
    SEEN_GUIDS[$g]=1
    STUDENT_GUIDS+=("$g")
  fi
}

discover_guids() {
  # 1) Manifest
  if [[ -f "$MANIFEST" ]]; then
    while IFS= read -r guid; do
      [[ -z "$guid" ]] && continue
      add_student_guid "$guid"
    done < "$MANIFEST"
  fi

  # 2) Config num_students sequence
  local i
  for i in $(seq 1 "$NUM_STUDENTS"); do
    add_student_guid "${BASE_GUID}-s${i}"
  done

  # 3) CloudFormation stacks openshift-cluster-${BASE_GUID}-* (students)
  #    and openshift-cluster-${HUB_GUID}
  if command -v aws &>/dev/null; then
    local stacks
    stacks="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
      --query "Stacks[?starts_with(StackName, 'openshift-cluster-${BASE_GUID}')].StackName" \
      --output text 2>/dev/null || true)"
    local stack name guid
    for stack in $stacks; do
      name="${stack#openshift-cluster-}"
      # student: linbit-s1 ; hub: linbit-hub
      if [[ "$name" == "${BASE_GUID}-s"* ]]; then
        add_student_guid "$name"
      fi
    done
  fi
}

# -----------------------------------------------------------------
# AgnosticD destroy helpers
# -----------------------------------------------------------------
destroy_student() {
  local guid="$1"
  local student_num="${guid##*-s}"
  local config_name="linbit-student-${student_num}"

  mkdir -p "$AGNOSTICD_VARS"
  if [[ ! -f "${AGNOSTICD_VARS}/${config_name}.yml" ]]; then
    config_name="linbit-student"
    cp "$SCRIPT_DIR/vars/student/linbit-student.yaml" "$AGNOSTICD_VARS/${config_name}.yml"
  fi

  echo "==> Destroying student cluster ($guid) [config=$config_name] ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] run-agd.sh destroy -g $guid -c $config_name -a $ACCOUNT"
    return 0
  fi

  AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" destroy \
    -g "$guid" \
    -c "$config_name" \
    -a "$ACCOUNT" || \
    warn "Failed to destroy $guid, continuing..."
}

destroy_hub() {
  mkdir -p "$AGNOSTICD_VARS"
  cp "$SCRIPT_DIR/vars/hub/linbit-hub.yaml" "$AGNOSTICD_VARS/linbit-hub.yml"

  echo "==> Destroying hub cluster ($HUB_GUID) ..."
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] run-agd.sh destroy -g $HUB_GUID -c linbit-hub -a $ACCOUNT"
    return 0
  fi

  AGNOSTICD_ROOT="$AGNOSTICD_ROOT" "$SCRIPT_DIR/run-agd.sh" destroy \
    -g "$HUB_GUID" \
    -c linbit-hub \
    -a "$ACCOUNT"
  ok "Hub cluster destroy finished"
}

# -----------------------------------------------------------------
# AWS orphan sweep — delete leftover linbit / BASE_GUID resources
# -----------------------------------------------------------------
vpc_matches_workshop() {
  local name="${1:-}"
  [[ -z "$name" || "$name" == "None" ]] && return 1
  [[ "$name" == *"${BASE_GUID}"* || "$name" == *linbit* ]]
}

delete_vpc_deep() {
  local vpc_id="$1"
  local name="${2:-}"
  info "Sweeping VPC $vpc_id ($name)"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "  [DRY-RUN] delete VPC resources for $vpc_id"
    return 0
  fi

  # NAT gateways
  local nat_ids
  nat_ids="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available,pending,deleting" \
    --query 'NatGateways[].NatGatewayId' --output text 2>/dev/null || true)"
  local nat
  for nat in $nat_ids; do
    [[ -z "$nat" || "$nat" == "None" ]] && continue
    info "  Deleting NAT $nat"
    aws ec2 delete-nat-gateway --region "$AWS_REGION" --nat-gateway-id "$nat" >/dev/null || true
  done

  # Wait for NATs to release EIPs
  if [[ -n "${nat_ids// /}" && "$nat_ids" != "None" ]]; then
    info "  Waiting for NAT gateways to delete..."
    local waited=0
    while (( waited < 300 )); do
      local left
      left="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available,pending,deleting" \
        --query 'length(NatGateways)' --output text 2>/dev/null || echo 0)"
      [[ "$left" == "0" || "$left" == "None" ]] && break
      sleep 10
      waited=$((waited + 10))
    done
  fi

  # Detach & delete IGWs
  local igws
  igws="$(aws ec2 describe-internet-gateways --region "$AWS_REGION" \
    --filters "Name=attachment.vpc-id,Values=${vpc_id}" \
    --query 'InternetGateways[].InternetGatewayId' --output text 2>/dev/null || true)"
  local igw
  for igw in $igws; do
    [[ -z "$igw" || "$igw" == "None" ]] && continue
    info "  Detaching/deleting IGW $igw"
    aws ec2 detach-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$igw" --vpc-id "$vpc_id" 2>/dev/null || true
    aws ec2 delete-internet-gateway --region "$AWS_REGION" --internet-gateway-id "$igw" 2>/dev/null || true
  done

  # Delete non-main route table associations + custom route tables
  local rtbs
  rtbs="$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[?Associations[?Main!=`true`] || length(Associations)==`0`].RouteTableId' \
    --output text 2>/dev/null || true)"
  # Simpler: all route tables, skip main
  rtbs="$(aws ec2 describe-route-tables --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'RouteTables[].{Id:RouteTableId,Main:Associations[?Main==`true`]|[0].Main}' \
    --output json 2>/dev/null | python3 -c '
import sys, json
for r in json.load(sys.stdin):
    if r.get("Main") is True:
        continue
    print(r["Id"])
' 2>/dev/null || true)"
  local rtb
  for rtb in $rtbs; do
    [[ -z "$rtb" || "$rtb" == "None" ]] && continue
    # Disassociate
    local assocs
    assocs="$(aws ec2 describe-route-tables --region "$AWS_REGION" --route-table-ids "$rtb" \
      --query 'RouteTables[].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null || true)"
    local a
    for a in $assocs; do
      [[ -z "$a" || "$a" == "None" ]] && continue
      aws ec2 disassociate-route-table --region "$AWS_REGION" --association-id "$a" 2>/dev/null || true
    done
    info "  Deleting route table $rtb"
    aws ec2 delete-route-table --region "$AWS_REGION" --route-table-id "$rtb" 2>/dev/null || true
  done

  # Subnets
  local subnets
  subnets="$(aws ec2 describe-subnets --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'Subnets[].SubnetId' --output text 2>/dev/null || true)"
  local sn
  for sn in $subnets; do
    [[ -z "$sn" || "$sn" == "None" ]] && continue
    info "  Deleting subnet $sn"
    aws ec2 delete-subnet --region "$AWS_REGION" --subnet-id "$sn" 2>/dev/null || true
  done

  # Security groups (non-default)
  local sgs
  sgs="$(aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text 2>/dev/null || true)"
  # Revoke cross-refs then delete (two passes)
  local pass sg
  for pass in 1 2; do
    for sg in $sgs; do
      [[ -z "$sg" || "$sg" == "None" ]] && continue
      aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" 2>/dev/null || true
    done
  done

  # Network interfaces (force detach leftovers)
  local enis
  enis="$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)"
  local eni
  for eni in $enis; do
    [[ -z "$eni" || "$eni" == "None" ]] && continue
    info "  Deleting ENI $eni"
    aws ec2 delete-network-interface --region "$AWS_REGION" --network-interface-id "$eni" 2>/dev/null || true
  done

  info "  Deleting VPC $vpc_id"
  aws ec2 delete-vpc --region "$AWS_REGION" --vpc-id "$vpc_id" 2>/dev/null || \
    warn "Could not delete VPC $vpc_id (may still have dependencies)"
}

release_workshop_eips() {
  echo "============================================================"
  echo "Phase 3b: Releasing workshop Elastic IPs"
  echo "============================================================"

  aws ec2 describe-addresses --region "$AWS_REGION" --output json 2>/dev/null \
    | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
for a in json.load(sys.stdin).get("Addresses", []):
    tags = {t["Key"]: t["Value"] for t in a.get("Tags", [])}
    name = tags.get("Name", "") or ""
    guid = tags.get("guid", "") or ""
    if not ((base in name) or ("linbit" in name.lower()) or (base in guid) or ("linbit" in guid.lower())):
        continue
    print("%s\t%s\t%s" % (a["AllocationId"], name or "None", a.get("AssociationId") or ""))
' | while IFS=$'\t' read -r alloc name assoc; do
    [[ -z "$alloc" || "$alloc" == "None" ]] && continue
    info "EIP $alloc ($name) assoc=${assoc:-none}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  [DRY-RUN] release-address $alloc"
      continue
    fi
    if [[ -n "$assoc" ]]; then
      aws ec2 disassociate-address --region "$AWS_REGION" --association-id "$assoc" 2>/dev/null || true
    fi
    aws ec2 release-address --region "$AWS_REGION" --allocation-id "$alloc" 2>/dev/null || \
      warn "Could not release $alloc"
  done
}

sweep_aws_orphans() {
  echo "============================================================"
  echo "Phase 3: AWS orphan sweep (${AWS_REGION}, prefix=${BASE_GUID})"
  echo "============================================================"

  if ! command -v aws &>/dev/null; then
    warn "aws CLI not found; skipping orphan sweep"
    return 0
  fi

  # Remaining CFN stacks for this workshop
  local remaining_stacks
  remaining_stacks="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
    --query "Stacks[?contains(StackName, '${BASE_GUID}')].StackName" \
    --output text 2>/dev/null || true)"
  if [[ -n "${remaining_stacks// /}" && "$remaining_stacks" != "None" ]]; then
    warn "CloudFormation stacks still present: $remaining_stacks"
    warn "Orphan sweep will still try to remove detached OCP VPCs/EIPs"
  fi

  # VPCs matching workshop naming
  local vpcs_json
  vpcs_json="$(aws ec2 describe-vpcs --region "$AWS_REGION" --output json)"
  local vpc_lines
  vpc_lines="$(echo "$vpcs_json" | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
for v in json.load(sys.stdin).get("Vpcs", []):
    tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
    name = tags.get("Name", "") or ""
    guid = tags.get("guid", "") or ""
    if v.get("IsDefault"):
        continue
    if base in name or "linbit" in name.lower() or base in guid or "linbit" in guid.lower():
        print("%s\t%s" % (v["VpcId"], name or "None"))
')"

  if [[ -z "$vpc_lines" ]]; then
    ok "No workshop VPCs found"
  else
    while IFS=$'\t' read -r vpc_id name; do
      [[ -z "$vpc_id" ]] && continue
      delete_vpc_deep "$vpc_id" "$name"
    done <<< "$vpc_lines"
  fi

  release_workshop_eips

  # Leftover CFN stacks (force delete if agd missed them)
  if [[ -n "${remaining_stacks// /}" && "$remaining_stacks" != "None" ]]; then
    local st
    for st in $remaining_stacks; do
      [[ -z "$st" || "$st" == "None" ]] && continue
      # Skip the hub stack when DESTROY_HUB=false
      if [[ "$DESTROY_HUB" == "false" && "$st" == *"${HUB_GUID}"* ]]; then
        info "Skipping hub stack $st (DESTROY_HUB=false)"
        continue
      fi
      warn "Force-deleting leftover stack $st"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY-RUN] aws cloudformation delete-stack --stack-name $st"
      else
        aws cloudformation delete-stack --region "$AWS_REGION" --stack-name "$st" || true
      fi
    done
  fi
}

# -----------------------------------------------------------------
# Final inventory / readiness
# -----------------------------------------------------------------
print_inventory() {
  echo "============================================================"
  echo "Final AWS inventory (${AWS_REGION})"
  echo "============================================================"

  if ! command -v aws &>/dev/null; then
    warn "aws CLI not found"
    return 1
  fi

  echo ""
  echo "--- CloudFormation (linbit) ---"
  aws cloudformation describe-stacks --region "$AWS_REGION" \
    --query "Stacks[?contains(StackName, '${BASE_GUID}')].{Name:StackName,Status:StackStatus}" \
    --output table 2>/dev/null || echo "(none)"

  echo ""
  echo "--- VPCs (linbit / ${BASE_GUID}) ---"
  aws ec2 describe-vpcs --region "$AWS_REGION" --output json | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
rows = []
for v in json.load(sys.stdin).get("Vpcs", []):
    tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if base in name or "linbit" in name.lower():
        rows.append((v["VpcId"], name))
if not rows:
    print("(none)")
else:
    for vid, name in rows:
        print("  %s  %s" % (vid, name))
'

  echo ""
  echo "--- NAT Gateways (linbit) ---"
  aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter Name=state,Values=available,pending,deleting \
    --output json | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
found = False
for n in json.load(sys.stdin).get("NatGateways", []):
    tags = {t["Key"]: t["Value"] for t in n.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if base in name or "linbit" in name.lower():
        found = True
        print("  %s  %s  %s" % (n["NatGatewayId"], name, n["State"]))
if not found:
    print("(none)")
'

  echo ""
  echo "--- Elastic IPs (linbit) ---"
  aws ec2 describe-addresses --region "$AWS_REGION" --output json | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
found = False
for a in json.load(sys.stdin).get("Addresses", []):
    tags = {t["Key"]: t["Value"] for t in a.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if base in name or "linbit" in name.lower():
        found = True
        print("  %s  %s  alloc=%s" % (a.get("PublicIp"), name, a.get("AllocationId")))
if not found:
    print("(none)")
'
}

leftovers_remain() {
  local stacks vpcs nats eips
  local hub_exclude=""
  if [[ "$DESTROY_HUB" == "false" ]]; then
    hub_exclude="$HUB_GUID"
  fi
  stacks="$(aws cloudformation describe-stacks --region "$AWS_REGION" \
    --query "length(Stacks[?contains(StackName, '${BASE_GUID}') && !contains(StackName, '${hub_exclude:-__NOMATCH__}')])" --output text 2>/dev/null || echo 0)"
  vpcs="$(aws ec2 describe-vpcs --region "$AWS_REGION" --output json | BASE_GUID="$BASE_GUID" HUB_EXCLUDE="$hub_exclude" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
hub_ex = os.environ.get("HUB_EXCLUDE", "")
n = 0
for v in json.load(sys.stdin).get("Vpcs", []):
    tags = {t["Key"]: t["Value"] for t in v.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if (base in name or "linbit" in name.lower()) and (not hub_ex or hub_ex not in name):
        n += 1
print(n)
' 2>/dev/null || echo 0)"
  nats="$(aws ec2 describe-nat-gateways --region "$AWS_REGION" \
    --filter Name=state,Values=available,pending,deleting --output json | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
n = 0
for g in json.load(sys.stdin).get("NatGateways", []):
    tags = {t["Key"]: t["Value"] for t in g.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if base in name or "linbit" in name.lower():
        n += 1
print(n)
' 2>/dev/null || echo 0)"
  eips="$(aws ec2 describe-addresses --region "$AWS_REGION" --output json | BASE_GUID="$BASE_GUID" python3 -c '
import json, sys, os
base = os.environ["BASE_GUID"]
n = 0
for a in json.load(sys.stdin).get("Addresses", []):
    tags = {t["Key"]: t["Value"] for t in a.get("Tags", [])}
    name = tags.get("Name", "") or ""
    if base in name or "linbit" in name.lower():
        n += 1
print(n)
' 2>/dev/null || echo 0)"

  [[ "${stacks:-0}" =~ ^[0-9]+$ ]] || stacks=0
  [[ "${vpcs:-0}" =~ ^[0-9]+$ ]] || vpcs=0
  [[ "${nats:-0}" =~ ^[0-9]+$ ]] || nats=0
  [[ "${eips:-0}" =~ ^[0-9]+$ ]] || eips=0

  info "Leftover counts — stacks=${stacks} vpcs=${vpcs} nats=${nats} eips=${eips}"
  (( stacks + vpcs + nats + eips > 0 ))
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------
main() {
  acquire_lock
  confirm_destroy

  echo ""
  echo "============================================================"
  echo "LINBIT Edge Storage Workshop — Teardown"
  echo "============================================================"
  info "Config:        ${CONFIG_FILE:-"(none)"}"
  info "Region:        ${AWS_REGION}"
  info "Account:       ${ACCOUNT}"
  info "AgnosticD:     ${AGNOSTICD_ROOT}"
  info "Hub GUID:      ${HUB_GUID}"
  info "Base GUID:     ${BASE_GUID}"
  info "Num students:  ${NUM_STUDENTS}"
  info "Destroy hub:   ${DESTROY_HUB}"
  info "Dry run:       ${DRY_RUN}"
  echo ""

  if [[ ! -d "$AGNOSTICD_ROOT" ]]; then
    fail "AgnosticD not found at $AGNOSTICD_ROOT"
    exit 1
  fi

  stop_inflight_provisions
  discover_guids

  echo ""
  echo "============================================================"
  echo "Phase 1: Destroying student cluster(s)"
  echo "============================================================"
  if ((${#STUDENT_GUIDS[@]} == 0)); then
    warn "No student guids discovered"
  else
    info "Student guids: ${STUDENT_GUIDS[*]}"
    local g
    for g in "${STUDENT_GUIDS[@]}"; do
      destroy_student "$g"
    done
  fi

  if [[ "$DESTROY_HUB" == "true" ]]; then
    echo ""
    echo "============================================================"
    echo "Phase 2: Destroying hub cluster ($HUB_GUID)"
    echo "============================================================"
    destroy_hub
  else
    info "Skipping hub destroy (DESTROY_HUB=false)"
  fi

  # Clear local state
  if [[ "$DRY_RUN" != "true" ]]; then
    if [[ "$DESTROY_HUB" == "true" ]]; then
      rm -f "$MANIFEST" "$STATE_DIR/hub_api_url" "$STATE_DIR/hub_token"
    else
      # Keep hub creds; clear destroyed students from manifest
      : > "$MANIFEST"
    fi
  else
    echo "  [DRY-RUN] clear state files under $STATE_DIR"
  fi

  sweep_aws_orphans
  print_inventory

  echo ""
  echo "============================================================"
  if [[ "$DRY_RUN" == "true" ]]; then
    ok "Dry run complete — no resources were deleted"
    exit 0
  fi

  if leftovers_remain; then
    # Give CFN/NAT a moment and re-sweep once
    warn "Leftovers remain; waiting 60s and re-sweeping once..."
    sleep 60
    sweep_aws_orphans
    print_inventory
    if leftovers_remain; then
      fail "Teardown incomplete — linbit leftovers still present in ${AWS_REGION}"
      exit 1
    fi
  fi

  ok "Teardown complete — no linbit leftovers in ${AWS_REGION}"
  echo "============================================================"
}

main "$@"
