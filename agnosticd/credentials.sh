#!/usr/bin/env bash
# ===================================================================
# LINBIT Edge Storage Workshop — Cluster Credentials
# Displays consolidated access information for hub and student clusters.
# Read-only: does not connect to clusters or modify any state.
#
# Usage:
#   ./agnosticd/credentials.sh           # show all credentials
#   ./agnosticd/credentials.sh --save    # also write to deployment_info.txt
#   make credentials                     # same (via Makefile)
#   make credentials ARGS=--save         # save to file
# ===================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SAVE_TO_FILE=false

for arg in "$@"; do
  case "$arg" in
    --save|-s) SAVE_TO_FILE=true ;;
    *)
      echo "ERROR: Unknown argument: $arg" >&2
      echo "Usage: $0 [--save|-s]" >&2
      exit 1
      ;;
  esac
done

# -----------------------------------------------------------------
# Read config.yml (same pattern as deploy.sh / status.sh)
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
else
  echo "WARNING: No config.yml found. Run 'make setup' first." >&2
fi

AGNOSTICD_ROOT="${AGNOSTICD_ROOT:-$HOME/Development/agnosticd-v2}"
AGNOSTICD_ROOT="${AGNOSTICD_ROOT/#\~/$HOME}"
ACCOUNT="${ACCOUNT:-sandbox2530}"
BASE_DOMAIN="${BASE_DOMAIN:-${ACCOUNT}.opentlc.com}"
HUB_GUID="${HUB_GUID:-linbit-hub}"
BASE_GUID="${BASE_GUID:-linbit}"
NUM_STUDENTS="${NUM_STUDENTS:-2}"

STATE_DIR="${SCRIPT_DIR}/.state"
OUTPUT_ROOT="${AGNOSTICD_ROOT}/../agnosticd-v2-output"
SAVE_FILE="${REPO_ROOT}/deployment_info.txt"

# -----------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------
find_kubeconfig() {
  local guid="$1"
  local output_dir="${OUTPUT_ROOT}/${guid}"
  local candidates=(
    "${output_dir}/openshift-cluster_${guid}_kubeconfig"
    "${output_dir}/kubeconfig"
    "${output_dir}/ocp4-cluster/auth/kubeconfig"
    "${output_dir}/auth/kubeconfig"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  if [[ -d "$output_dir" ]]; then
    local found
    found="$(find "$output_dir" -maxdepth 2 -type f \( -name "*_kubeconfig" -o -name "kubeconfig" \) 2>/dev/null | head -1 || true)"
    if [[ -n "$found" ]]; then
      printf '%s' "$found"
      return 0
    fi
  fi
  return 1
}

find_kubeadmin_password() {
  local guid="$1"
  local output_dir="${OUTPUT_ROOT}/${guid}"
  local candidates=(
    "${output_dir}/openshift-cluster_${guid}_kubeadmin-password"
    "${output_dir}/ocp4-cluster/auth/kubeadmin-password"
    "${output_dir}/auth/kubeadmin-password"
  )
  for candidate in "${candidates[@]}"; do
    if [[ -f "$candidate" ]]; then
      cat "$candidate"
      return 0
    fi
  done
  if [[ -d "$output_dir" ]]; then
    local found
    found="$(find "$output_dir" -maxdepth 2 -type f -name "*kubeadmin-password*" 2>/dev/null | head -1 || true)"
    if [[ -n "$found" ]]; then
      cat "$found"
      return 0
    fi
  fi
  return 1
}

# Read a scalar key from AgnosticD user-data (prefer provision-user-data.yaml).
# Usage: user_data_get GUID KEY
user_data_get() {
  local guid="$1" key="$2"
  local output_dir="${OUTPUT_ROOT}/${guid}"
  local f val
  for f in \
    "${output_dir}/provision-user-data.yaml" \
    "${output_dir}/user-data.yaml"; do
    [[ -f "$f" ]] || continue
    val="$(python3 - "$key" "$f" <<'PY'
import sys
key, path = sys.argv[1], sys.argv[2]
with open(path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if line.startswith("#") or ":" not in line:
            continue
        k, _, v = line.partition(":")
        if k.strip() != key:
            continue
        val = v.strip().strip("\"'")
        if val:
            print(val)
            raise SystemExit(0)
raise SystemExit(1)
PY
)" || true
    if [[ -n "$val" ]]; then
      printf '%s' "$val"
      return 0
    fi
  done
  return 1
}

# Showroom / lab UI URL from user-data (lab_ui_url or showroom_primary_view_url)
find_showroom_url() {
  local guid="$1" url=""
  url="$(user_data_get "$guid" lab_ui_url 2>/dev/null || true)"
  if [[ -z "$url" ]]; then
    url="$(user_data_get "$guid" showroom_primary_view_url 2>/dev/null || true)"
  fi
  if [[ -n "$url" ]]; then
    printf '%s' "$url"
    return 0
  fi
  return 1
}

# -----------------------------------------------------------------
# Build output (capture for optional file save)
# -----------------------------------------------------------------
generate_output() {
  echo "============================================================"
  echo "LINBIT Edge Storage Workshop — Cluster Credentials"
  echo "============================================================"

  if [[ ! -d "$STATE_DIR" ]] || [[ ! -f "${STATE_DIR}/hub_api_url" && ! -f "${STATE_DIR}/students.txt" ]]; then
    echo ""
    echo "  No deployment state found."
    echo "  Run 'make deploy' first to provision clusters."
    echo ""
    echo "============================================================"
    return
  fi

  # --- Hub Cluster ---
  echo ""
  echo "Hub Cluster:"
  echo "  GUID:          $HUB_GUID"

  HUB_API_URL="$(user_data_get "$HUB_GUID" openshift_api_url 2>/dev/null || true)"
  if [[ -z "$HUB_API_URL" && -f "${STATE_DIR}/hub_api_url" ]]; then
    HUB_API_URL="$(cat "${STATE_DIR}/hub_api_url")"
  fi
  if [[ -n "$HUB_API_URL" ]]; then
    echo "  API URL:       $HUB_API_URL"
  else
    echo "  API URL:       (not available — hub not deployed?)"
  fi

  HUB_CONSOLE="$(user_data_get "$HUB_GUID" openshift_console_url 2>/dev/null || true)"
  if [[ -z "$HUB_CONSOLE" ]]; then
    HUB_CONSOLE="$(user_data_get "$HUB_GUID" openshift_cluster_console_url 2>/dev/null || true)"
  fi
  if [[ -z "$HUB_CONSOLE" ]]; then
    HUB_CONSOLE="https://console-openshift-console.apps.${HUB_GUID}.${BASE_DOMAIN}"
  fi
  echo "  Console:       $HUB_CONSOLE"

  if HUB_SHOWROOM="$(find_showroom_url "$HUB_GUID")"; then
    echo "  Showroom:      $HUB_SHOWROOM"
  else
    echo "  Showroom:      (not found — showroom workload may not be deployed)"
  fi

  HUB_KUBECONFIG=""
  if HUB_KUBECONFIG="$(find_kubeconfig "$HUB_GUID")"; then
    echo "  Kubeconfig:    $HUB_KUBECONFIG"
  else
    echo "  Kubeconfig:    (not found under ${OUTPUT_ROOT}/${HUB_GUID}/)"
  fi

  if HUB_PASSWORD="$(find_kubeadmin_password "$HUB_GUID")"; then
    echo "  Kubeadmin pw:  $HUB_PASSWORD"
  else
    echo "  Kubeadmin pw:  (not found)"
  fi

  # Prefer htpasswd admin from user-data when present
  HUB_ADMIN_USER="$(user_data_get "$HUB_GUID" openshift_cluster_admin_username 2>/dev/null || true)"
  HUB_ADMIN_PW="$(user_data_get "$HUB_GUID" openshift_cluster_admin_password 2>/dev/null || true)"
  if [[ -n "$HUB_ADMIN_USER" && -n "$HUB_ADMIN_PW" ]]; then
    echo "  Admin user:    $HUB_ADMIN_USER / $HUB_ADMIN_PW"
  fi

  if [[ -f "${STATE_DIR}/hub_token" ]]; then
    HUB_TOKEN="$(cat "${STATE_DIR}/hub_token")"
    echo "  RHACM token:   $HUB_TOKEN"
  else
    echo "  RHACM token:   (not available — run deploy to generate)"
  fi

  # --- Student Clusters ---
  echo ""

  STUDENTS=()
  if [[ -f "${STATE_DIR}/students.txt" ]]; then
    while IFS= read -r guid; do
      [[ -z "$guid" ]] && continue
      STUDENTS+=("$guid")
    done < "${STATE_DIR}/students.txt"
  else
    for i in $(seq 1 "$NUM_STUDENTS"); do
      STUDENTS+=("${BASE_GUID}-s${i}")
    done
  fi

  echo "Student Clusters (${#STUDENTS[@]}):"

  for guid in "${STUDENTS[@]}"; do
    echo "  ${guid}:"

    STUDENT_API="$(user_data_get "$guid" openshift_api_url 2>/dev/null || true)"
    if [[ -z "$STUDENT_API" ]]; then
      STUDENT_API="https://api.${guid}.${BASE_DOMAIN}:6443"
    fi
    echo "    API URL:     $STUDENT_API"

    STUDENT_CONSOLE="$(user_data_get "$guid" openshift_console_url 2>/dev/null || true)"
    if [[ -z "$STUDENT_CONSOLE" ]]; then
      STUDENT_CONSOLE="https://console-openshift-console.apps.${guid}.${BASE_DOMAIN}"
    fi
    echo "    Console:     $STUDENT_CONSOLE"

    if STUDENT_SHOWROOM="$(find_showroom_url "$guid")"; then
      echo "    Showroom:    $STUDENT_SHOWROOM"
    fi

    if kc="$(find_kubeconfig "$guid")"; then
      echo "    Kubeconfig:  $kc"
    else
      echo "    Kubeconfig:  (not found)"
    fi

    if pw="$(find_kubeadmin_password "$guid")"; then
      echo "    Kubeadmin:   $pw"
    else
      echo "    Kubeadmin:   (not found)"
    fi
    echo ""
  done

  # --- Quick Commands ---
  echo "Quick commands:"
  if [[ -n "$HUB_KUBECONFIG" ]]; then
    echo "  export KUBECONFIG=$HUB_KUBECONFIG"
    echo "  oc get managedclusters"
    echo "  oc get nodes"
  else
    echo "  (deploy hub first to get kubeconfig path)"
  fi
  echo "============================================================"
}

# -----------------------------------------------------------------
# Main
# -----------------------------------------------------------------
OUTPUT="$(generate_output)"
echo "$OUTPUT"

if [[ "$SAVE_TO_FILE" == "true" ]]; then
  echo "$OUTPUT" > "$SAVE_FILE"
  echo ""
  echo "Saved to: $SAVE_FILE"
fi
