#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
  printf '[agent-bootstrap][error] This compatibility wrapper must run inside the VM as root.\n' >&2
  printf '[agent-bootstrap][error] From Spark, use: sandbox update ${INSTANCE:-NAME}\n' >&2
  exit 1
fi

printf '[agent-bootstrap] Delegating to canonical VM install: %s/install.sh\n' "$REPO_ROOT"
exec "${REPO_ROOT}/install.sh"
