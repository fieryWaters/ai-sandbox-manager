#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

name="${1:-${INSTANCE:-youart-agent-base}}"

printf '[agent-verify] Delegating to canonical doctor for %s\n' "$name"
exec "${REPO_ROOT}/sandbox" doctor "$name"
