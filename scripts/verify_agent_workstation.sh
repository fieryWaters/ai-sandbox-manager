#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTANCE="${INSTANCE:-youart-agent-base}"
NOVNC_HOST_PORT="${NOVNC_HOST_PORT:-16901}"
CUA_HOST_PORT="${CUA_HOST_PORT:-28000}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
PYTORCH_IMAGE="${PYTORCH_IMAGE:-nvcr.io/nvidia/pytorch:25.11-py3}"

log() { printf '\n[agent-verify] %s\n' "$*"; }

inside() {
  lxc exec "${INSTANCE}" -- bash -lc "$1"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

require lxc
require curl

log "Baseline tools"
inside 'hostname; getent hosts example.com | head -1; git --version; python3 --version; node --version; npm --version; codex --version; chromium --version'

log "Services"
inside 'systemctl is-active docker ssh youart-vnc youart-novnc youart-cua-server'

log "SSH host proxy"
timeout 5 bash -c "</dev/tcp/127.0.0.1/${SSH_HOST_PORT}"
printf 'SSH proxy ok on 127.0.0.1:%s\n' "${SSH_HOST_PORT}"

log "noVNC host proxy"
curl -fsS "http://127.0.0.1:${NOVNC_HOST_PORT}/" | grep -q noVNC
printf 'noVNC ok on http://127.0.0.1:%s/\n' "${NOVNC_HOST_PORT}"

log "CUA host proxy"
curl -fsS "http://127.0.0.1:${CUA_HOST_PORT}/status" | grep -q '"status":"ok"\|"status": "ok"'
curl -fsS -X POST "http://127.0.0.1:${CUA_HOST_PORT}/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"get_screen_size","params":{}}' \
  | grep -Eq '"success": true.*"width": [0-9]+.*"height": [0-9]+'
printf 'CUA ok on http://127.0.0.1:%s/\n' "${CUA_HOST_PORT}"

log "Chromium persistent profile"
inside 'rm -f /tmp/check_chromium_persistence.py'
lxc file push "${SCRIPT_DIR}/check_chromium_persistence.py" "${INSTANCE}/tmp/check_chromium_persistence.py"
inside 'chown agent:agent /tmp/check_chromium_persistence.py'
inside 'rm -rf /tmp/chromium-verify-profile'
lxc exec "${INSTANCE}" -- su - agent -c 'CHROMIUM_PROFILE=/tmp/chromium-verify-profile /opt/cua-computer-server/bin/python /tmp/check_chromium_persistence.py' | grep -q persist-ok
printf 'Chromium persistence ok\n'

log "Docker"
inside 'docker run --rm hello-world | grep "Hello from Docker"'

log "Direct GPU"
inside 'nvidia-smi | grep "NVIDIA GB10"'

log "PyTorch Docker GPU matmul"
inside 'rm -f /tmp/pytorch_matmul.py'
lxc file push "${SCRIPT_DIR}/pytorch_matmul.py" "${INSTANCE}/tmp/pytorch_matmul.py"
inside 'chown root:root /tmp/pytorch_matmul.py'
lxc exec "${INSTANCE}" -- docker run --rm --gpus all \
  -v /tmp/pytorch_matmul.py:/tmp/pytorch_matmul.py:ro \
  "${PYTORCH_IMAGE}" \
  python /tmp/pytorch_matmul.py | tee /tmp/youart-pytorch-matmul.log
grep -q pytorch-matmul-ok /tmp/youart-pytorch-matmul.log

log "All checks passed"
