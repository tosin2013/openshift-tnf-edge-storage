#!/usr/bin/env bash
# Temporary workaround until rhpds/agnosticd-v2 accepts el family distros
# (CentOS Stream / Rocky / AlmaLinux). Does NOT modify upstream bin/agd on disk —
# see https://github.com/tosin2013/openshift-tnf-edge-storage/issues/2
#
# Usage (from any cwd):
#   ./agnosticd/run-agd.sh provision -g GUID -c CONFIG -a ACCOUNT
#   AGNOSTICD_ROOT=/path ./agnosticd/run-agd.sh status -g ... -c ... -a ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

resolve_root() {
  if [[ -n "${AGNOSTICD_ROOT:-}" ]]; then
    echo "${AGNOSTICD_ROOT/#\~/$HOME}"
    return
  fi

  local config_file="${SCRIPT_DIR}/config.yml"
  if [[ -f "$config_file" ]]; then
    local line val
    line="$(grep -E '^[[:space:]]*agnosticd_root:' "$config_file" | head -1 || true)"
    if [[ -n "$line" ]]; then
      val="${line#*:}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      val="${val#\"}"; val="${val%\"}"
      val="${val#\'}"; val="${val%\'}"
      val="${val/#\~/$HOME}"
      if [[ -n "$val" ]]; then
        echo "$val"
        return
      fi
    fi
  fi

  echo "${HOME}/Development/agnosticd-v2"
}

AGNOSTICD_ROOT="$(resolve_root)"
AGD="${AGNOSTICD_ROOT}/bin/agd"

if [[ ! -f "$AGD" ]]; then
  echo "ERROR: agd not found at ${AGD}"
  exit 1
fi

cd "$AGNOSTICD_ROOT"

# Relax OS allowlist in-memory only (centos/rocky/almalinux + bare VERSION_ID=10)
exec bash <(sed \
  -e 's/\[\[ "\$ID" == "rhel" \]\]/[[ "$ID" =~ ^(rhel|centos|rocky|almalinux)$ ]]/' \
  -e 's/\[\[ "\$VERSION_ID" =~ \^9\\\. \]\]/[[ "${VERSION_ID%%.*}" == "9" ]]/' \
  -e 's/\[\[ "\$VERSION_ID" =~ \^10\\\. \]\]/[[ "${VERSION_ID%%.*}" == "10" ]]/' \
  "$AGD") "$@"
