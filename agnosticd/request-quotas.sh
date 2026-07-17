#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — AWS Quota Request
# Checks current AWS service quotas against workshop requirements and
# submits increase requests for any that are insufficient.
#
# Usage:
#   ./agnosticd/request-quotas.sh               # use config.yml or defaults
#   AWS_REGION=us-west-2 ./agnosticd/request-quotas.sh  # override region
#   NUM_STUDENTS=4 ./agnosticd/request-quotas.sh        # recalculate needs
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Read config.yml if it exists ────────────────────────────────────────────

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

AWS_REGION="${AWS_REGION:-us-east-2}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

# ─── Calculate requirements ──────────────────────────────────────────────────

# Hub HA cluster: 3 CP (m6i.xlarge = 4 vCPUs) + 2 workers (m6i.2xlarge = 8 vCPUs) + bastion ≈ 30
# Each TNA student: 2 primary (8 vCPUs) + 1 arbiter (4 vCPUs) + bastion ≈ 22
HUB_VCPUS=30
STUDENT_VCPUS=22
VCPU_NEEDED=$(( HUB_VCPUS + STUDENT_VCPUS * NUM_STUDENTS ))
# Request with headroom: round up to next 50 or at least double
VCPU_REQUEST=$(( VCPU_NEEDED * 2 ))
(( VCPU_REQUEST < 150 )) && VCPU_REQUEST=150

# OpenShift uses ~5 EIPs per cluster (3 AZ NAT + bastion/API headroom)
EIP_NEEDED=$(( 5 * (1 + NUM_STUDENTS) ))
# Request with headroom: at least 20, or 2x needed
EIP_REQUEST=20
(( EIP_REQUEST < EIP_NEEDED * 2 )) && EIP_REQUEST=$(( EIP_NEEDED * 2 ))

# Bastion/CFN VPC + OpenShift installer VPC per cluster
VPC_NEEDED=$(( 2 * (1 + NUM_STUDENTS) ))
VPC_REQUEST=10
(( VPC_REQUEST < VPC_NEEDED * 2 )) && VPC_REQUEST=$(( VPC_NEEDED * 2 ))

# ─── Quota definitions ───────────────────────────────────────────────────────

declare -a QUOTA_LABELS=("EC2 vCPUs (On-Demand Standard)" "Elastic IPs" "VPCs")
declare -a QUOTA_SERVICES=("ec2" "ec2" "vpc")
declare -a QUOTA_CODES=("L-1216C47A" "L-0263D0A3" "L-F678F1CE")
declare -a QUOTA_NEEDED=("$VCPU_NEEDED" "$EIP_NEEDED" "$VPC_NEEDED")
declare -a QUOTA_REQUEST=("$VCPU_REQUEST" "$EIP_REQUEST" "$VPC_REQUEST")

# ─── Colors ──────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

info()  { echo -e "${BLUE}[INFO]${RESET} $*"; }
ok()    { echo -e "  ${GREEN}[OK]${RESET}       $*"; }
req()   { echo -e "  ${YELLOW}[REQUEST]${RESET}  $*"; }
fail()  { echo -e "  ${RED}[FAIL]${RESET}     $*"; }
skip()  { echo -e "  ${GREEN}[SKIP]${RESET}     $*"; }

# ─── Preflight ───────────────────────────────────────────────────────────────

if ! command -v aws &>/dev/null; then
  echo "ERROR: aws CLI not found. Run: make setup"
  exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS credentials not configured. Run: aws configure"
  exit 1
fi

CALLER_ID=$(aws sts get-caller-identity --query 'Arn' --output text)

echo ""
echo -e "${BOLD}=== AWS Quota Request — LINBIT Edge Storage Workshop ===${RESET}"
echo ""
info "Region:       ${AWS_REGION}"
info "Students:     ${NUM_STUDENTS}"
info "AWS Identity: ${CALLER_ID}"
echo ""

# ─── Check and request ───────────────────────────────────────────────────────

requested=0
sufficient=0
failed=0

for i in "${!QUOTA_LABELS[@]}"; do
  label="${QUOTA_LABELS[$i]}"
  service="${QUOTA_SERVICES[$i]}"
  code="${QUOTA_CODES[$i]}"
  needed="${QUOTA_NEEDED[$i]}"
  desired="${QUOTA_REQUEST[$i]}"

  current=$(aws service-quotas get-service-quota \
    --service-code "$service" \
    --quota-code "$code" \
    --region "$AWS_REGION" \
    --query 'Quota.Value' --output json 2>/dev/null |
    python3 -c "import sys,json; v=json.load(sys.stdin); print(int(v) if v else 0)" 2>/dev/null || echo 0)

  if (( current >= needed )); then
    ok "${label}: current ${current} >= needed ${needed}"
    sufficient=$((sufficient + 1))
    continue
  fi

  # Check for an existing open request
  open_request=$(aws service-quotas list-requested-service-quota-change-history-by-quota \
    --service-code "$service" \
    --quota-code "$code" \
    --region "$AWS_REGION" \
    --query "RequestedQuotas[?Status=='PENDING'].[Id,DesiredValue]" \
    --output text 2>/dev/null || echo "")

  if [[ -n "$open_request" ]]; then
    skip "${label}: increase already pending (${open_request})"
    sufficient=$((sufficient + 1))
    continue
  fi

  req "${label}: current ${current} < needed ${needed}, requesting ${desired}..."

  request_output=$(aws service-quotas request-service-quota-increase \
    --service-code "$service" \
    --quota-code "$code" \
    --desired-value "$desired" \
    --region "$AWS_REGION" \
    --output json 2>&1) || {
      fail "${label}: request failed"
      echo "      ${request_output}"
      failed=$((failed + 1))
      continue
    }

  request_id=$(echo "$request_output" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('RequestedQuota', {}).get('Id', 'unknown'))
" 2>/dev/null || echo "unknown")

  ok "${label}: increase requested (ID: ${request_id}, target: ${desired})"
  requested=$((requested + 1))
done

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}--- Summary ---${RESET}"
echo ""
info "Sufficient: ${sufficient}"
info "Requested:  ${requested}"
if (( failed > 0 )); then
  fail "Failed:     ${failed}"
fi
echo ""

if (( requested > 0 )); then
  info "Quota increases typically take 1-15 minutes for small increases."
  info "Large increases (e.g., vCPUs > 256) may require AWS support review (up to 24h)."
  echo ""
  info "Check status:  aws service-quotas list-requested-service-quota-change-history --region ${AWS_REGION}"
  info "Re-validate:   make check"
fi

if (( failed > 0 )); then
  echo ""
  fail "Some requests failed. You may need to submit them manually at:"
  fail "https://console.aws.amazon.com/servicequotas/home/services/ec2/quotas"
  exit 1
fi
