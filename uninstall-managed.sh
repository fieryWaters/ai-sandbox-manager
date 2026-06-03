#!/usr/bin/env bash
set -euo pipefail

log() { printf '[ai-sandbox-uninstall] %s\n' "$*"; }
die() { printf '[ai-sandbox-uninstall][error] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run uninstall-managed.sh as root"

log "Stopping managed services"
systemctl disable --now youart-cua-server.service youart-novnc.service youart-vnc.service >/dev/null 2>&1 || true
systemctl stop youart-cua-server.service youart-novnc.service youart-vnc.service >/dev/null 2>&1 || true

log "Removing managed service units and scripts"
rm -f \
  /etc/systemd/system/youart-cua-server.service \
  /etc/systemd/system/youart-novnc.service \
  /etc/systemd/system/youart-vnc.service \
  /usr/local/bin/youart-start-cua-server \
  /usr/local/bin/youart-start-novnc \
  /usr/local/bin/youart-start-vnc \
  /usr/local/bin/youart-xstartup

systemctl daemon-reload

log "Removing managed noVNC and CUA fallback installs"
rm -rf /opt/noVNC /opt/cua-computer-server

log "Removing managed browser wrapper"
rm -f /usr/local/bin/chromium

log "Removing managed sudoers/env files"
rm -f /etc/sudoers.d/90-ai-sandbox /etc/youart-agent.env

log "Preserving user state"
printf '%s\n' \
  'preserved: Chromium profiles, Codex auth/config, SSH keys, git-repos, workspace, box.env, logs'

log "Uninstall-managed complete"
