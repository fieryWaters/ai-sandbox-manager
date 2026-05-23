#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_NAME="${1:-default}"
CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_NAME}.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "Config not found: ${CONFIG_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

if [[ -z "${CONTAINER:-}" ]]; then
  echo "Invalid config: CONTAINER is missing in ${CONFIG_FILE}" >&2
  exit 1
fi

sudo lxc start "${CONTAINER}" >/dev/null 2>&1 || true
exec sudo lxc exec "${CONTAINER}" -- bash
