#!/usr/bin/env bash
set -euo pipefail

log() { printf '[ai-sandbox-uninstall] %s\n' "$*"; }
die() { printf '[ai-sandbox-uninstall][error] %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Run uninstall-managed.sh as root"

log "Stopping managed services"
systemctl disable --now \
  sandbox-cua-server.service sandbox-novnc.service sandbox-vnc.service \
  youart-cua-server.service youart-novnc.service youart-vnc.service \
  >/dev/null 2>&1 || true

log "Removing managed service units and scripts"
rm -f \
  /etc/systemd/system/sandbox-cua-server.service \
  /etc/systemd/system/sandbox-novnc.service \
  /etc/systemd/system/sandbox-vnc.service \
  /etc/systemd/system/youart-cua-server.service \
  /etc/systemd/system/youart-novnc.service \
  /etc/systemd/system/youart-vnc.service \
  /usr/local/bin/sandbox-cua-server \
  /usr/local/bin/sandbox-novnc \
  /usr/local/bin/sandbox-vnc \
  /usr/local/bin/sandbox-xstartup \
  /usr/local/bin/youart-start-cua-server \
  /usr/local/bin/youart-start-novnc \
  /usr/local/bin/youart-start-vnc \
  /usr/local/bin/youart-xstartup

systemctl daemon-reload

log "Killing stale managed desktop processes"
# Stopping the units is not enough: boxes that predate the current unit names
# can have desktop processes leaked from old units (or from a boot under
# since-deleted units) still squatting on 5901/6901/8000, which makes the new
# services crash-loop with "Address already in use".
pkill -TERM -f '/usr/local/bin/youart-start-' 2>/dev/null || true
pkill -TERM -f '/usr/local/bin/sandbox-(vnc|novnc|cua-server)' 2>/dev/null || true
pkill -TERM -f 'novnc_proxy' 2>/dev/null || true
pkill -TERM -f 'websockify' 2>/dev/null || true
pkill -TERM -f 'computer_server' 2>/dev/null || true
pkill -TERM -f 'Xtigervnc :1' 2>/dev/null || true
pkill -TERM -f 'vncserver :1' 2>/dev/null || true
sleep 2
pkill -KILL -f 'websockify' 2>/dev/null || true
pkill -KILL -f 'computer_server' 2>/dev/null || true
pkill -KILL -f 'Xtigervnc :1' 2>/dev/null || true

log "Removing managed noVNC and computer-server installs"
rm -rf /opt/noVNC /opt/cua-computer-server

log "Removing managed browser/desktop wrappers"
rm -f /usr/local/bin/chromium /usr/local/bin/deskbot /usr/local/bin/cuabot

log "Removing legacy nested cuabot desktop state"
for home in /home/*; do
  [ -d "$home" ] || continue
  user="$(basename "$home")"
  if id "$user" >/dev/null 2>&1; then
    runuser -u "$user" -- bash -lc '
      pkill -TERM -f "[n]pm exec cuabot --serve" >/dev/null 2>&1 || true
      pkill -TERM -f "[s]h -c cuabot --serve" >/dev/null 2>&1 || true
      pkill -TERM -f "[n]ode /usr/bin/cuabot --serve" >/dev/null 2>&1 || true
      pkill -TERM -f "[h]eadless_shell" >/dev/null 2>&1 || true
    ' || true
  fi
done
if command -v docker >/dev/null 2>&1; then
  docker ps -a --format "{{.Names}}" \
    | awk '/^cuabot-xpra($|-)/ { print }' \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
fi
for home in /home/*; do
  [ -d "$home/.cuabot" ] || continue
  rm -f "$home"/.cuabot/server*.pid "$home"/.cuabot/server*.port "$home"/.cuabot/server*.log
done

log "Removing managed sudoers/env files"
rm -f /etc/sudoers.d/90-ai-sandbox /etc/ai-sandbox.env /etc/youart-agent.env

log "Preserving user state"
printf '%s\n' \
  'preserved: Chromium profiles, Codex auth/config, Claude auth/config, SSH keys, git-repos, workspace, box.env, logs'

log "Uninstall-managed complete"
