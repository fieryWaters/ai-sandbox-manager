#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

name="${INSTANCE:-youart-agent-base}"
mode="--quick"
case "${1:-${SCOPE:-quick}}" in
  quick|--quick|'') mode="--quick" ;;
  full|all|--full) mode="--full" ;;
  *) printf '[agent-verify][error] Use quick or full.\n' >&2; exit 1 ;;
esac

printf '[agent-verify] Delegating to canonical doctor for %s (%s)\n' "$name" "$mode"
exec "${REPO_ROOT}/sandbox" doctor "$name" "$mode"
