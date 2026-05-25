#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

AGENT_USER="${AGENT_USER:-agent}"
AGENT_PASS="${AGENT_PASS:-agent}"
VNC_PW="${VNC_PW:-agent-desktop}"
VNC_RESOLUTION="${VNC_RESOLUTION:-1280x800}"
VNC_COL_DEPTH="${VNC_COL_DEPTH:-24}"
VNC_PORT="${VNC_PORT:-5901}"
NOVNC_PORT="${NOVNC_PORT:-6901}"
API_PORT="${API_PORT:-8000}"
DOCKER_DNS1="${DOCKER_DNS1:-1.1.1.1}"
DOCKER_DNS2="${DOCKER_DNS2:-8.8.8.8}"

log() { printf '[agent-bootstrap] %s\n' "$*"; }

log "Adding NodeSource Node.js 22 repository"
install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
fi
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' \
  >/etc/apt/sources.list.d/nodesource.list

log "Installing workstation packages"
apt-get update
apt-get install -y \
  ca-certificates curl wget git gnupg gpg lsb-release software-properties-common \
  sudo jq unzip zip net-tools netcat-openbsd xdg-utils dbus-x11 x11-utils xterm \
  openssh-server \
  xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common \
  gnome-screenshot xdotool xclip wmctrl ffmpeg \
  python3 python3-dev python3-venv python3-pip python3-tk build-essential \
  nodejs docker.io docker-compose-v2

log "Creating ${AGENT_USER} user"
if ! id "${AGENT_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo,docker "${AGENT_USER}"
  echo "${AGENT_USER}:${AGENT_PASS}" | chpasswd
fi
usermod -aG sudo,docker "${AGENT_USER}"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${AGENT_USER}" >/etc/sudoers.d/90-youart-agent
chmod 0440 /etc/sudoers.d/90-youart-agent

log "Configuring Docker"
systemctl enable --now docker

log "Configuring SSH"
systemctl enable --now ssh

log "Installing NVIDIA container toolkit"
if [ ! -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
fi
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
  >/etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
sed -i 's/^#\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
tmp_daemon="$(mktemp)"
if [ -s /etc/docker/daemon.json ]; then
  jq --arg dns1 "${DOCKER_DNS1}" --arg dns2 "${DOCKER_DNS2}" \
    '.dns = [$dns1, $dns2]' /etc/docker/daemon.json >"${tmp_daemon}"
else
  jq -n --arg dns1 "${DOCKER_DNS1}" --arg dns2 "${DOCKER_DNS2}" \
    '{dns: [$dns1, $dns2]}' >"${tmp_daemon}"
fi
install -m 0644 "${tmp_daemon}" /etc/docker/daemon.json
rm -f "${tmp_daemon}"
systemctl restart docker

log "Installing noVNC from TryCua fork"
rm -rf /opt/noVNC
git clone --depth 1 https://github.com/trycua/noVNC.git /opt/noVNC
git clone --depth 1 https://github.com/novnc/websockify /opt/noVNC/utils/websockify
ln -sf /opt/noVNC/vnc.html /opt/noVNC/index.html

log "Installing CUA computer-server with VNC backend"
python3 -m venv /opt/cua-computer-server
/opt/cua-computer-server/bin/pip install --upgrade pip setuptools wheel
/opt/cua-computer-server/bin/pip install 'cua-computer-server[vnc]'

log "Installing Codex CLI"
npm install -g @openai/codex
rm -f /usr/local/bin/codex-yolo
runuser -u "${AGENT_USER}" -- bash -lc '
  touch ~/.bashrc
  sed -i \
    -e "/^alias yolo=codex-yolo$/d" \
    -e "/^alias cy=codex-yolo$/d" \
    -e "/^alias codex=codex-yolo$/d" \
    -e "/^alias codex='\''command codex --dangerously-bypass-approvals-and-sandbox'\''$/d" \
    ~/.bashrc
  grep -qxF "# Run Codex without approval prompts or sandboxing." ~/.bashrc || printf "\n# Run Codex without approval prompts or sandboxing.\n" >> ~/.bashrc
  printf "%s\n" "alias codex='\''command codex --dangerously-bypass-approvals-and-sandbox'\''" >> ~/.bashrc
'

log "Installing Playwright Chromium and wrapper"
npm install -g playwright
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install --with-deps chromium
cat >/usr/local/bin/chromium <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
chrome="$(find /opt/ms-playwright -path '*/chrome-linux/chrome' -type f | sort | tail -n 1)"
if [ -z "$chrome" ]; then
  echo "Playwright Chromium executable not found under /opt/ms-playwright" >&2
  exit 1
fi
profile="${CHROMIUM_USER_DATA_DIR:-$HOME/.config/chromium}"
mkdir -p "$profile"
exec "$chrome" \
  --no-sandbox \
  --disable-dev-shm-usage \
  --password-store=basic \
  --user-data-dir="$profile" \
  "$@"
EOF
chmod +x /usr/local/bin/chromium
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/chromium 100
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/chromium 100

log "Writing agent environment"
cat >/etc/youart-agent.env <<EOF
AGENT_USER=${AGENT_USER}
HOME=/home/${AGENT_USER}
USER=${AGENT_USER}
DISPLAY=:1
VNC_PW=${VNC_PW}
VNC_RESOLUTION=${VNC_RESOLUTION}
VNC_COL_DEPTH=${VNC_COL_DEPTH}
VNC_PORT=${VNC_PORT}
NOVNC_PORT=${NOVNC_PORT}
API_PORT=${API_PORT}
CUA_VNC_HOST=127.0.0.1
CUA_VNC_PORT=${VNC_PORT}
CUA_VNC_PASSWORD=${VNC_PW}
EOF
chmod 0644 /etc/youart-agent.env

log "Writing VNC/XFCE startup scripts"
cat >/usr/local/bin/youart-xstartup <<'EOF'
#!/usr/bin/env bash
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export XKL_XMODMAP_DISABLE=1
exec startxfce4
EOF
chmod +x /usr/local/bin/youart-xstartup

cat >/usr/local/bin/youart-start-vnc <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/youart-agent.env
rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1
mkdir -p "$HOME/.vnc"
echo "$VNC_PW" | vncpasswd -f > "$HOME/.vnc/passwd"
chmod 600 "$HOME/.vnc/passwd"
vncserver :1 \
  -geometry "${VNC_RESOLUTION:-1280x800}" \
  -depth "${VNC_COL_DEPTH:-24}" \
  -rfbport "${VNC_PORT:-5901}" \
  -localhost no \
  -SecurityTypes VncAuth \
  -rfbauth "$HOME/.vnc/passwd" \
  -AlwaysShared \
  -AcceptPointerEvents \
  -AcceptKeyEvents \
  -AcceptCutText \
  -SendCutText \
  -xstartup /usr/local/bin/youart-xstartup
tail -F "$HOME"/.vnc/*.log
EOF
chmod +x /usr/local/bin/youart-start-vnc

cat >/usr/local/bin/youart-start-novnc <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/youart-agent.env
until nc -z 127.0.0.1 "${VNC_PORT:-5901}"; do
  sleep 1
done
cd /opt/noVNC
exec /opt/noVNC/utils/novnc_proxy \
  --vnc "127.0.0.1:${VNC_PORT:-5901}" \
  --listen "0.0.0.0:${NOVNC_PORT:-6901}"
EOF
chmod +x /usr/local/bin/youart-start-novnc

cat >/usr/local/bin/youart-start-cua-server <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source /etc/youart-agent.env
until xdpyinfo -display :1 >/dev/null 2>&1; do
  sleep 1
done
exec /opt/cua-computer-server/bin/python -m computer_server \
  --host 0.0.0.0 \
  --port "${API_PORT:-8000}" \
  --backend vnc \
  --vnc-host "${CUA_VNC_HOST:-127.0.0.1}" \
  --vnc-port "${CUA_VNC_PORT:-5901}" \
  --vnc-password "${CUA_VNC_PASSWORD:-agent-desktop}" \
  --log-level info
EOF
chmod +x /usr/local/bin/youart-start-cua-server

log "Writing systemd services"
cat >/etc/systemd/system/youart-vnc.service <<EOF
[Unit]
Description=YouArt Agent XFCE VNC Desktop
After=network-online.target

[Service]
User=${AGENT_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=/home/${AGENT_USER}
ExecStart=/usr/local/bin/youart-start-vnc
ExecStop=-/usr/bin/vncserver -kill :1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/youart-novnc.service <<EOF
[Unit]
Description=YouArt Agent noVNC Web Desktop
After=youart-vnc.service
Requires=youart-vnc.service

[Service]
User=${AGENT_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=/home/${AGENT_USER}
ExecStart=/usr/local/bin/youart-start-novnc
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/youart-cua-server.service <<EOF
[Unit]
Description=YouArt Agent CUA Computer Server
After=youart-vnc.service
Requires=youart-vnc.service

[Service]
User=${AGENT_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=/home/${AGENT_USER}
ExecStart=/usr/local/bin/youart-start-cua-server
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "Preparing agent home"
install -d -o "${AGENT_USER}" -g "${AGENT_USER}" "/home/${AGENT_USER}/workspace" "/home/${AGENT_USER}/.config/chromium" "/home/${AGENT_USER}/.vnc"
cat >"/home/${AGENT_USER}/cua-test.html" <<'EOF'
<!doctype html>
<html>
  <head><title>CUA Smoke Test</title></head>
  <body style="font-family:sans-serif;padding:40px">
    <h1>CUA Smoke Test</h1>
    <input id="smoke" style="font-size:24px;width:520px" placeholder="type here" autofocus>
  </body>
</html>
EOF
chown -R "${AGENT_USER}:${AGENT_USER}" "/home/${AGENT_USER}"

log "Enabling services"
systemctl daemon-reload
systemctl enable --now youart-vnc.service youart-novnc.service youart-cua-server.service

log "Bootstrap complete"
