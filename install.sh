#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# install.sh — runs inside the VM as root. Called by the host's sandbox CLI.

die() { printf '[install][error] %s\n' "$*" >&2; exit 1; }
log() { printf '[install] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Run as root"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Read box.env (written by host's sandbox CLI) ──────────────────────────────
# One-line parser — box.env is trusted (host-written, chmod 600).
for p in "/home/${SANDBOX_USER:-}/.ai-sandbox/box.env" /home/*/.ai-sandbox/box.env; do
  [ -f "$p" ] && { BOX_ENV="$p"; break; }
done
[ -n "${BOX_ENV:-}" ] || die "No box.env found"
while IFS= read -r line; do
  case "$line" in
    SANDBOX_USER=*) SANDBOX_USER="${line#*=}" ;;
    PORT_BASE=*)    PORT_BASE="${line#*=}" ;;
    VNC_PASSWORD=*) VNC_PASSWORD="${line#*=}" ;;
  esac
done < "$BOX_ENV"
SANDBOX_USER="${SANDBOX_USER:-agent}"
[ -n "${VNC_PASSWORD:-}" ] || die "box.env missing VNC_PASSWORD"

# ── User + logging ────────────────────────────────────────────────────────────

id "$SANDBOX_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SANDBOX_USER"
USER_HOME="$(getent passwd "$SANDBOX_USER" | cut -d: -f6)"
runuser -u "$SANDBOX_USER" -- mkdir -p -m 700 "$USER_HOME/.ai-sandbox/logs"
exec > >(tee -a "$USER_HOME/.ai-sandbox/logs/install-$(date -u +%Y%m%dT%H%M%SZ).log") 2>&1
log "Installing managed tooling for ${SANDBOX_USER}"

# ── apt with retry against apt-daily lock ────────────────────────────────────
# Keep Ubuntu's security updates enabled; retry on the lock race instead.

apt_get() {
  for _ in $(seq 1 60); do
    apt-get -o DPkg::Lock::Timeout=600 "$@" && return 0
    sleep 5
  done
  apt-get -o DPkg::Lock::Timeout=600 "$@"
}

install -d -m 0755 /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/nodesource.gpg ]; then
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --batch --dearmor -o /etc/apt/keyrings/nodesource.gpg
fi
printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main\n' >/etc/apt/sources.list.d/nodesource.list

apt_get update
apt_get install -y \
  ca-certificates curl wget git gnupg gpg lsb-release software-properties-common \
  sudo jq unzip zip net-tools netcat-openbsd xdg-utils dbus-x11 x11-utils x11-apps xterm \
  openssh-server tigervnc-standalone-server tigervnc-common \
  xclip wmctrl xdotool netpbm file python3 python3-dev python3-venv python3-pip \
  python3-tk build-essential python3-pil nodejs docker.io docker-compose-v2

# The desktop runs inside tigervnc, so xfce4's recommends are skipped: they pull
# a display manager (lightdm) and Xorg, which take the host's monitor through the
# GPU device. The theme, icons, and SVG loader are the recommends xfce looks for.
apt_get install -y --no-install-recommends \
  xfce4 xfce4-terminal greybird-gtk-theme elementary-xfce-icon-theme librsvg2-common
apt_get purge -y lightdm light-locker
systemctl set-default multi-user.target

usermod -aG sudo,docker "$SANDBOX_USER" || usermod -aG sudo "$SANDBOX_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$SANDBOX_USER" >/etc/sudoers.d/90-ai-sandbox
chmod 0440 /etc/sudoers.d/90-ai-sandbox
systemctl enable --now ssh docker || true

# ── NVIDIA container runtime (optional, ARM64 needs nvidia-ctk) ──────────────

if curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    >/etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt_get update && apt_get install -y nvidia-container-toolkit || true
  if command -v nvidia-ctk >/dev/null 2>&1; then
    nvidia-ctk runtime configure --runtime=docker || true
    [ -f /etc/nvidia-container-runtime/config.toml ] && sed -i 's/^#\?no-cgroups.*/no-cgroups = true/' /etc/nvidia-container-runtime/config.toml
    systemctl restart docker || true
  fi
fi

# ── Desktop stack: noVNC, cua computer-server, Playwright Chromium ────────────

sync_git_repo() {
  if [ -d "$2/.git" ]; then
    git -C "$2" fetch --depth 1 origin
    git -C "$2" reset --hard "$(git -C "$2" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)" && git -C "$2" clean -fdx
  else rm -rf "$2" && git clone --depth 1 "$1" "$2"; fi
}
sync_git_repo https://github.com/trycua/noVNC.git /opt/noVNC
sync_git_repo https://github.com/novnc/websockify /opt/noVNC/utils/websockify
ln -sf /opt/noVNC/vnc.html /opt/noVNC/index.html

[ -x /opt/cua-computer-server/bin/python ] || { rm -rf /opt/cua-computer-server; python3 -m venv /opt/cua-computer-server; }
# cua-computer-server passes websocket_max_size to FastAPI(), which FastAPI 0.162 rejects.
/opt/cua-computer-server/bin/pip install --upgrade pip setuptools wheel 'cua-computer-server[vnc]' 'fastapi==0.142.1'

npm install -g playwright
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install --with-deps chromium

# ── Managed files: env, executables, systemd units ───────────────────────────

cat >/etc/ai-sandbox.env <<EOF
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
EOF
chmod 0600 /etc/ai-sandbox.env

install -m 0755 "$REPO_DIR"/vm/bin/* /usr/local/bin/
for unit in "$REPO_DIR"/vm/systemd/*.service; do
  sed -e "s|@AGENT_USER@|${SANDBOX_USER}|g" -e "s|@AGENT_HOME@|${USER_HOME}|g" "$unit" >"/etc/systemd/system/$(basename "$unit")"
done
update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/chromium 100 || true
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/chromium 100 || true

# ── User state directories ───────────────────────────────────────────────────

# Created as the user so every parent directory (.config, .local) is user-owned too.
runuser -u "$SANDBOX_USER" -- mkdir -p \
  "$USER_HOME"/{.config/chromium,.config/opencode,.codex,.claude,.ssh,git-repos,workspace,.vnc,.local/bin,.local/share,.local/state,.npm-global/bin}

# ── User-owned CLIs: Codex, Claude Code, OpenCode ─────────────────────────────

runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$HOME/.local/bin" sh
  command -v codex >/dev/null 2>&1 && timeout 300 codex update </dev/null || true
'
rm -f /etc/claude-code/managed-settings.d/90-ai-sandbox-updates.json 2>/dev/null || true
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://claude.ai/install.sh | bash -s -- latest
  command -v claude >/dev/null 2>&1 && timeout 300 claude update </dev/null || true
'
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail; export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://opencode.ai/install | bash
'

# ── OpenCode config: NeuralWatt provider + full-auto ──────────────────────────

cat >"$USER_HOME/.config/opencode/opencode.jsonc" <<'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "neuralwatt/glm-5.2",
  "permission": { "*": "allow", "websearch": "allow", "webfetch": "allow" },
  "provider": {
    "neuralwatt": {
      "name": "Neuralwatt",
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "https://api.neuralwatt.com/v1", "apiKey": "{env:NEURALWATT_API_KEY}" },
      "models": { "glm-5.2": { "name": "GLM-5.2", "limit": { "context": 1048576, "output": 131072 } } }
    }
  }
}
EOF
chown "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.config/opencode/opencode.jsonc"

# ── Skills + hooks (shared source for codex and claude) ───────────────────────

install_skills() {
  local dest="$1"
  [ -d "$REPO_DIR/codex/skills" ] || return
  install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/$dest/skills"
  for skill in "$REPO_DIR"/codex/skills/*; do
    [ -d "$skill" ] || continue
    local name; name="$(basename "$skill")"
    rm -rf "$USER_HOME/$dest/skills/$name"
    install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/$dest/skills/$name"
    tar -C "$skill" -cf - . | tar -C "$USER_HOME/$dest/skills/$name" -xf -
  done
  chown -R "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/$dest/skills"
}
install_skills .codex
install_skills .claude

# Codex hooks (host-synced hooks take precedence)
if [ ! -f "$USER_HOME/.codex/hooks.json" ] && [ -f "$REPO_DIR/codex/hooks.json" ]; then
  install -m 644 "$REPO_DIR/codex/hooks.json" "$USER_HOME/.codex/hooks.json"
  install -d -m 755 "$USER_HOME/.codex/hooks"
  install -m 755 "$REPO_DIR"/codex/hooks/*.py "$USER_HOME/.codex/hooks/"
fi
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.codex"

# ── Codex config: full access + trusted paths ────────────────────────────────

runuser -u "$SANDBOX_USER" -- bash -c '
  set -e; mkdir -p ~/.codex; touch ~/.codex/config.toml
  sed -i -e "/^approval_policy *=/d" -e "/^sandbox_mode *=/d" ~/.codex/config.toml
  printf "approval_policy = \"never\"\nsandbox_mode = \"danger-full-access\"\n" | cat - ~/.codex/config.toml > ~/.codex/config.toml.new
  mv ~/.codex/config.toml.new ~/.codex/config.toml
  for p in "$HOME" "$HOME/git-repos" "$HOME/.ai-sandbox/ai-sandbox-manager"; do
    grep -Fq "[projects.\"$p\"]" ~/.codex/config.toml || printf "\n[projects.\"%s\"]\ntrust_level = \"trusted\"\n" "$p" >> ~/.codex/config.toml
  done
'

# ── Claude onboarding ─────────────────────────────────────────────────────────

runuser -u "$SANDBOX_USER" -- bash -c '
  set -e
  if [ ! -f ~/.claude.json ]; then
    printf "{\"hasCompletedOnboarding\": true, \"bypassPermissionsModeAccepted\": true}\n" > ~/.claude.json
  else
    jq ".hasCompletedOnboarding = true | .bypassPermissionsModeAccepted = true" ~/.claude.json > ~/.claude.json.new
    mv ~/.claude.json.new ~/.claude.json
  fi
'

# ── PATH management ───────────────────────────────────────────────────────────

runuser -u "$SANDBOX_USER" -- bash -lc '
  npm config set prefix "$HOME/.npm-global" >/dev/null
  for f in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$f"
    sed -i "/^# >>> ai-sandbox managed PATH$/,/^# <<< ai-sandbox managed PATH$/d" "$f"
    printf "\n# >>> ai-sandbox managed PATH\ncase \":\$PATH:\" in *\":\$HOME/.local/bin:\"*) ;; *) PATH=\"\$HOME/.local/bin:\$PATH\" ;; esac\ncase \":\$PATH:\" in *\":\$HOME/.npm-global/bin:\"*) ;; *) PATH=\"\$HOME/.npm-global/bin:\$PATH\" ;; esac\nexport PATH\n# <<< ai-sandbox managed PATH\n" >> "$f"
  done
'

# ── Smoke test page ───────────────────────────────────────────────────────────

printf '<!doctype html><title>AI Sandbox Smoke Test</title><body style="font-family:sans-serif;padding:40px"><h1>AI Sandbox Smoke Test</h1><input style="font-size:24px;width:520px" autofocus></body>' > "$USER_HOME/cua-test.html"
chown "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/cua-test.html"

# ── Legacy cleanup + service activation ──────────────────────────────────────

systemctl disable --now youart-cua-server.service youart-novnc.service youart-vnc.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/youart-*.service /usr/local/bin/youart-* /etc/youart-agent.env
systemctl daemon-reload
systemctl enable --now sandbox-vnc.service sandbox-novnc.service sandbox-cua-server.service
systemctl restart sandbox-vnc.service sandbox-novnc.service sandbox-cua-server.service
log "Install complete"
