#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTANCE="${INSTANCE:-youart-agent-base}"
IMAGE="${IMAGE:-ubuntu:24.04}"
PROFILE="${PROFILE:-ai-macvlan}"
GPU_ID="${GPU_ID:-nvidia.com/gpu=0}"
NOVNC_HOST_PORT="${NOVNC_HOST_PORT:-16901}"
CUA_HOST_PORT="${CUA_HOST_PORT:-28000}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
BOOTSTRAP="${BOOTSTRAP:-${SCRIPT_DIR}/bootstrap_agent_workstation.sh}"

log() { printf '[agent-lxc] %s\n' "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

add_device_once() {
  local name="$1"
  shift
  if lxc config device get "${INSTANCE}" "${name}" type >/dev/null 2>&1; then
    log "Device ${name} already exists"
    return
  fi
  lxc config device add "${INSTANCE}" "${name}" "$@"
}

require lxc

if [ ! -f "${BOOTSTRAP}" ]; then
  printf 'Bootstrap script not found: %s\n' "${BOOTSTRAP}" >&2
  exit 1
fi

if lxc info "${INSTANCE}" >/dev/null 2>&1; then
  log "Using existing instance ${INSTANCE}"
else
  log "Launching ${INSTANCE} from ${IMAGE}"
  if [ -n "${PROFILE}" ]; then
    lxc launch "${IMAGE}" "${INSTANCE}" --profile "${PROFILE}"
  else
    lxc launch "${IMAGE}" "${INSTANCE}"
  fi
fi

log "Configuring nesting, autostart, and GPU"
lxc config set "${INSTANCE}" security.nesting true
lxc config set "${INSTANCE}" security.syscalls.intercept.mknod true
lxc config set "${INSTANCE}" security.syscalls.intercept.setxattr true
lxc config set "${INSTANCE}" boot.autostart true
add_device_once gpu0 gpu gputype=physical id="${GPU_ID}"

log "Configuring host proxy ports"
add_device_once host-novnc proxy \
  listen="tcp:0.0.0.0:${NOVNC_HOST_PORT}" \
  connect="tcp:127.0.0.1:6901"
add_device_once host-cua proxy \
  listen="tcp:0.0.0.0:${CUA_HOST_PORT}" \
  connect="tcp:127.0.0.1:8000"
add_device_once host-ssh proxy \
  listen="tcp:0.0.0.0:${SSH_HOST_PORT}" \
  connect="tcp:127.0.0.1:22"

log "Starting ${INSTANCE}"
lxc start "${INSTANCE}" >/dev/null 2>&1 || true

log "Pushing and running workstation bootstrap"
lxc file push "${BOOTSTRAP}" "${INSTANCE}/root/bootstrap_agent_workstation.sh"
lxc exec "${INSTANCE}" -- bash /root/bootstrap_agent_workstation.sh

log "Ready"
printf 'noVNC: http://127.0.0.1:%s/\n' "${NOVNC_HOST_PORT}"
printf 'CUA:    http://127.0.0.1:%s/\n' "${CUA_HOST_PORT}"
printf 'SSH:    ssh -p %s agent@127.0.0.1\n' "${SSH_HOST_PORT}"
