#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

name="${INSTANCE:-youart-agent-base}"
user="${SANDBOX_USER:-${AGENT_USER:-agent}}"
args=(create "$name" --user "$user")

if [ -n "${PORT_BASE:-}" ]; then
  args+=(--port-base "$PORT_BASE")
elif [ -n "${SSH_HOST_PORT:-}" ]; then
  args+=(--port-base "$SSH_HOST_PORT")
fi

if [ -n "${SSH_BIND:-}" ]; then args+=(--ssh-bind "$SSH_BIND"); fi
if [ -n "${NOVNC_BIND:-}" ]; then args+=(--novnc-bind "$NOVNC_BIND"); fi
if [ -n "${CUA_BIND:-}" ]; then args+=(--cua-bind "$CUA_BIND"); fi

exec "${REPO_ROOT}/sandbox" "${args[@]}"
