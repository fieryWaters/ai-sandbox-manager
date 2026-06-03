#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

die() { printf '[ai-sandbox-install][error] %s\n' "$*" >&2; exit 1; }
log() { printf '[ai-sandbox-install] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Run install.sh as root"

apt_get() {
  local attempt=1
  local max_attempts=60
  local delay=5
  local output
  local status

  # Keep Ubuntu's automatic security update path enabled. These boxes may be
  # exposed beyond localhost, so do not "fix" apt lock races by disabling
  # apt-daily, apt-daily-upgrade, or unattended-upgrades.
  #
  # Ubuntu's apt-daily.service can wake up during VM provisioning and briefly
  # hold /var/lib/apt/lists/lock between our apt phases. This is the same class
  # of race as Ubuntu/cloud-init bug 1693361. DPkg::Lock::Timeout helps install
  # waits, but apt-get update can still fail immediately on the lists lock, so
  # retry known lock errors instead of deleting locks or disabling security jobs.
  while true; do
    output="$(mktemp)"
    log "Running apt-get $*"
    set +e
    apt-get -o DPkg::Lock::Timeout=600 "$@" 2>&1 | tee "$output"
    status="${PIPESTATUS[0]}"
    set -e

    if [ "$status" -eq 0 ]; then
      rm -f "$output"
      return 0
    fi

    if grep -Eq 'Could not get lock|Unable to lock|Unable to acquire.*lock|Could not open lock' "$output" &&
      [ "$attempt" -lt "$max_attempts" ]; then
      rm -f "$output"
      log "apt is busy; waiting ${delay}s before retrying ($attempt/$max_attempts)"
      sleep "$delay"
      attempt=$((attempt + 1))
      continue
    fi

    rm -f "$output"
    return "$status"
  done
}

validate_user() {
  [[ "$1" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || die "Invalid SANDBOX_USER in box.env: $1"
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "Invalid PORT_BASE in box.env: $1"
}

find_box_env() {
  if [ -n "${SANDBOX_USER:-}" ] && [ -f "/home/${SANDBOX_USER}/.ai-sandbox/box.env" ]; then
    printf '/home/%s/.ai-sandbox/box.env' "$SANDBOX_USER"
    return
  fi
  for path in /home/*/.ai-sandbox/box.env; do
    if [ -f "$path" ]; then
      printf '%s' "$path"
      return
    fi
  done
  die "No /home/<user>/.ai-sandbox/box.env found"
}

load_box_env() {
  local path="$1"
  SANDBOX_USER=""
  PORT_BASE=""
  VNC_PASSWORD=""
  local line key value
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*)
        key="${line%%=*}"
        value="${line#*=}"
        case "$key" in
          SANDBOX_USER|PORT_BASE|VNC_PASSWORD)
            printf -v "$key" '%s' "$value"
            ;;
        esac
        ;;
    esac
  done <"$path"

  SANDBOX_USER="${SANDBOX_USER:-agent}"
  PORT_BASE="${PORT_BASE:-2230}"
  VNC_PASSWORD="${VNC_PASSWORD:-youart-agent}"
  validate_user "$SANDBOX_USER"
  validate_port "$PORT_BASE"
}

BOX_ENV="$(find_box_env)"
load_box_env "$BOX_ENV"

if ! id "$SANDBOX_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$SANDBOX_USER"
fi

USER_HOME="$(getent passwd "$SANDBOX_USER" | cut -d: -f6)"
[ -n "$USER_HOME" ] || die "Could not resolve home for ${SANDBOX_USER}"

SANDBOX_DIR="${USER_HOME}/.ai-sandbox"
LOG_DIR="${SANDBOX_DIR}/logs"
REPO_DIR="${SANDBOX_DIR}/ai-sandbox-manager"
install -d -m 700 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$SANDBOX_DIR" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Installing managed tooling for ${SANDBOX_USER}"

install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
fi
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' \
  >/etc/apt/sources.list.d/nodesource.list

apt_get update
apt_get install -y \
  ca-certificates curl wget git gnupg gpg lsb-release software-properties-common \
  sudo jq unzip zip net-tools netcat-openbsd xdg-utils dbus-x11 x11-utils xterm \
  openssh-server \
  xfce4 xfce4-terminal tigervnc-standalone-server tigervnc-common \
  xclip wmctrl xpra file \
  python3 python3-dev python3-venv python3-pip python3-tk build-essential \
  nodejs docker.io docker-compose-v2

usermod -aG sudo,docker "$SANDBOX_USER" || usermod -aG sudo "$SANDBOX_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SANDBOX_USER" >/etc/sudoers.d/90-ai-sandbox
chmod 0440 /etc/sudoers.d/90-ai-sandbox

systemctl enable --now ssh
systemctl enable --now docker || true

log "Configuring NVIDIA container runtime when available"
if curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg.tmp; then
  mv /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg.tmp /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt_get update
  apt_get install -y nvidia-container-toolkit || true
  if command -v nvidia-ctk >/dev/null 2>&1; then
    nvidia-ctk runtime configure --runtime=docker || true
    [ ! -f /etc/nvidia-container-runtime/config.toml ] || \
      sed -i 's/^#\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
    systemctl restart docker || true
  fi
else
  rm -f /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg.tmp
  log "Skipping NVIDIA container runtime setup"
fi

log "Installing noVNC"
rm -rf /opt/noVNC
git clone --depth 1 https://github.com/trycua/noVNC.git /opt/noVNC
git clone --depth 1 https://github.com/novnc/websockify /opt/noVNC/utils/websockify
ln -sf /opt/noVNC/vnc.html /opt/noVNC/index.html

log "Installing CUA computer-server fallback"
rm -rf /opt/cua-computer-server
python3 -m venv /opt/cua-computer-server
/opt/cua-computer-server/bin/pip install --upgrade pip setuptools wheel
/opt/cua-computer-server/bin/pip install 'cua-computer-server[vnc]'

log "Installing Codex, Playwright, and cuabot"
npm install -g @openai/codex playwright cuabot@latest
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install --with-deps chromium

runuser -u "$SANDBOX_USER" -- bash -lc '
  install -d -m 700 "$HOME/.cuabot"
  cat > "$HOME/.cuabot/settings.json" <<EOF
{
  "telemetryEnabled": false,
  "aliasIgnored": true
}
EOF
  chmod 600 "$HOME/.cuabot/settings.json"
  cuabot_root="$(npm root -g)/cuabot"
  if [ -x "${cuabot_root}/node_modules/.bin/playwright" ]; then
    "${cuabot_root}/node_modules/.bin/playwright" install chromium || true
  elif command -v playwright >/dev/null 2>&1; then
    playwright install chromium || true
  fi
'

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

log "Writing managed service environment"
cat >/etc/youart-agent.env <<EOF
AGENT_USER=${SANDBOX_USER}
HOME=${USER_HOME}
USER=${SANDBOX_USER}
DISPLAY=:1
VNC_PW=${VNC_PASSWORD}
VNC_RESOLUTION=1280x800
VNC_COL_DEPTH=24
VNC_PORT=5901
NOVNC_PORT=6901
API_PORT=8000
CUA_VNC_HOST=127.0.0.1
CUA_VNC_PORT=5901
CUA_VNC_PASSWORD=${VNC_PASSWORD}
EOF
chmod 0644 /etc/youart-agent.env

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
  --vnc-password "${CUA_VNC_PASSWORD:-youart-agent}" \
  --log-level info
EOF
chmod +x /usr/local/bin/youart-start-cua-server

cat >/etc/systemd/system/youart-vnc.service <<EOF
[Unit]
Description=AI Sandbox XFCE VNC Desktop
After=network-online.target

[Service]
User=${SANDBOX_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=${USER_HOME}
ExecStart=/usr/local/bin/youart-start-vnc
ExecStop=-/usr/bin/vncserver -kill :1
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/youart-novnc.service <<EOF
[Unit]
Description=AI Sandbox noVNC Web Desktop
After=youart-vnc.service
Requires=youart-vnc.service

[Service]
User=${SANDBOX_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=${USER_HOME}
ExecStart=/usr/local/bin/youart-start-novnc
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/youart-cua-server.service <<EOF
[Unit]
Description=AI Sandbox CUA Computer Server
After=youart-vnc.service
Requires=youart-vnc.service

[Service]
User=${SANDBOX_USER}
EnvironmentFile=/etc/youart-agent.env
WorkingDirectory=${USER_HOME}
ExecStart=/usr/local/bin/youart-start-cua-server
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

log "Preparing persistent user state directories"
install -d -o "$SANDBOX_USER" -g "$SANDBOX_USER" \
  "$USER_HOME/.config/chromium" \
  "$USER_HOME/.codex" \
  "$USER_HOME/.ssh" \
  "$USER_HOME/git-repos" \
  "$USER_HOME/workspace" \
  "$USER_HOME/.vnc"

cat >"$USER_HOME/cua-test.html" <<'EOF'
<!doctype html>
<html>
  <head><title>AI Sandbox Smoke Test</title></head>
  <body style="font-family:sans-serif;padding:40px">
    <h1>AI Sandbox Smoke Test</h1>
    <input id="smoke" style="font-size:24px;width:520px" placeholder="type here" autofocus>
  </body>
</html>
EOF
chown "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/cua-test.html"

if [ -d "$REPO_DIR/codex/skills" ]; then
  log "Installing repo Codex skills"
  install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.codex/skills"
  tar -C "$REPO_DIR/codex/skills" -cf - . \
    | tar -C "$USER_HOME/.codex/skills" -xf -
  chown -R "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.codex"
fi

runuser -u "$SANDBOX_USER" -- bash -lc '
  touch ~/.bashrc
  sed -i \
    -e "/^alias yolo=codex-yolo$/d" \
    -e "/^alias cy=codex-yolo$/d" \
    -e "/^alias codex=codex-yolo$/d" \
    -e "/^alias codex='\''command codex --dangerously-bypass-approvals-and-sandbox'\''$/d" \
    ~/.bashrc
  grep -qxF "# Run Codex without approval prompts or sandboxing." ~/.bashrc || printf "\n# Run Codex without approval prompts or sandboxing.\n" >> ~/.bashrc
  printf "%s\n" "alias codex='\''command codex --dangerously-bypass-approvals-and-sandbox'\''" >> ~/.bashrc
  mkdir -p ~/.codex
  touch ~/.codex/config.toml
  for path in "$HOME" "$HOME/git-repos" "$HOME/.ai-sandbox/ai-sandbox-manager"; do
    if ! grep -Fq "[projects.\"${path}\"]" ~/.codex/config.toml; then
      printf "\n[projects.\"%s\"]\ntrust_level = \"trusted\"\n" "$path" >> ~/.codex/config.toml
    fi
  done
'

systemctl daemon-reload
systemctl enable --now youart-vnc.service youart-novnc.service youart-cua-server.service

log "Caching cuabot Docker image when Docker is available"
if systemctl is-active --quiet docker; then
  docker pull trycua/cuabot:latest || true
fi

log "Install complete"
