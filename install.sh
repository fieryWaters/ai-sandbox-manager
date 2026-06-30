#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

die() { printf '[ai-sandbox-install][error] %s\n' "$*" >&2; exit 1; }
log() { printf '[ai-sandbox-install] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "Run install.sh as root"
[ "$#" -eq 0 ] || die "install.sh does not accept arguments"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

sync_git_repo() {
  local url="$1"
  local dir="$2"
  local ref
  if [ -d "$dir/.git" ]; then
    git -C "$dir" remote set-url origin "$url" >/dev/null 2>&1 || true
    git -C "$dir" fetch --depth 1 origin
    git -C "$dir" remote set-head origin -a >/dev/null 2>&1 || true
    ref="$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [ -z "$ref" ]; then
      if git -C "$dir" rev-parse --verify origin/main >/dev/null 2>&1; then
        ref="origin/main"
      else
        ref="origin/master"
      fi
    fi
    git -C "$dir" reset --hard "$ref"
    git -C "$dir" clean -fdx
  else
    rm -rf "$dir"
    git clone --depth 1 "$url" "$dir"
  fi
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
  [ -n "$VNC_PASSWORD" ] || die "box.env is missing VNC_PASSWORD"
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
install -d -m 700 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$SANDBOX_DIR" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/install-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Installing managed tooling for ${SANDBOX_USER}"

# ---------------------------------------------------------------------------
# Packages: apt, NodeSource node, NVIDIA container runtime
# ---------------------------------------------------------------------------

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
  xclip wmctrl xdotool netpbm file \
  python3 python3-dev python3-venv python3-pip python3-tk build-essential \
  python3-pil \
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

# ---------------------------------------------------------------------------
# Desktop stack: noVNC, cua computer-server, agent CLIs, Playwright Chromium
# ---------------------------------------------------------------------------

log "Installing/updating noVNC"
sync_git_repo https://github.com/trycua/noVNC.git /opt/noVNC
sync_git_repo https://github.com/novnc/websockify /opt/noVNC/utils/websockify
ln -sf /opt/noVNC/vnc.html /opt/noVNC/index.html

log "Installing/updating cua computer-server"
if [ ! -x /opt/cua-computer-server/bin/python ]; then
  rm -rf /opt/cua-computer-server
  python3 -m venv /opt/cua-computer-server
fi
/opt/cua-computer-server/bin/pip install --upgrade pip setuptools wheel
/opt/cua-computer-server/bin/pip install --upgrade 'cua-computer-server[vnc]'

log "Installing/updating Playwright browser dependencies"
# Claude and Codex are user-owned so agents can auto-update them. Remove stale
# root npm globals from older boxes so /usr/bin does not shadow ~/.local/bin.
npm uninstall -g @openai/codex @anthropic-ai/claude-code >/dev/null 2>&1 || true
rm -f /usr/local/bin/codex /usr/local/bin/claude
rm -rf /usr/local/lib/node_modules/@openai/codex /usr/local/lib/node_modules/@anthropic-ai/claude-code
for cli in /usr/bin/codex /usr/bin/claude; do
  target="$(readlink "$cli" 2>/dev/null || true)"
  case "$target" in
    *node_modules/@openai/codex*|*node_modules/@anthropic-ai/claude-code*)
      rm -f "$cli"
      ;;
  esac
done
npm install -g playwright
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install --with-deps chromium

# ---------------------------------------------------------------------------
# Managed files: env, executables, systemd units (all checked in under vm/)
# ---------------------------------------------------------------------------

log "Writing managed service environment"
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

log "Installing managed executables and services from vm/"
install -m 0755 "$REPO_DIR"/vm/bin/* /usr/local/bin/
for unit in "$REPO_DIR"/vm/systemd/*.service; do
  sed -e "s|@AGENT_USER@|${SANDBOX_USER}|g" \
      -e "s|@AGENT_HOME@|${USER_HOME}|g" \
      "$unit" >"/etc/systemd/system/$(basename "$unit")"
done

update-alternatives --install /usr/bin/x-www-browser x-www-browser /usr/local/bin/chromium 100
update-alternatives --install /usr/bin/gnome-www-browser gnome-www-browser /usr/local/bin/chromium 100

# ---------------------------------------------------------------------------
# User state and agent profiles (Codex + Claude)
# ---------------------------------------------------------------------------

log "Preparing persistent user state directories"
install -d -o "$SANDBOX_USER" -g "$SANDBOX_USER" \
  "$USER_HOME/.config/chromium" \
  "$USER_HOME/.codex" \
  "$USER_HOME/.claude" \
  "$USER_HOME/.ssh" \
  "$USER_HOME/git-repos" \
  "$USER_HOME/workspace" \
  "$USER_HOME/.vnc" \
  "$USER_HOME/.local" \
  "$USER_HOME/.local/bin" \
  "$USER_HOME/.local/share" \
  "$USER_HOME/.npm-global" \
  "$USER_HOME/.npm-global/bin"

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

log "Configuring user-owned CLI paths"
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail
  mkdir -p "$HOME/.local/bin" "$HOME/.npm-global/bin"
  npm config set prefix "$HOME/.npm-global" >/dev/null
  for file in "$HOME/.profile" "$HOME/.bashrc"; do
    touch "$file"
    sed -i "/^# >>> ai-sandbox managed PATH$/,/^# <<< ai-sandbox managed PATH$/d" "$file"
    printf "\n# >>> ai-sandbox managed PATH\ncase \":\$PATH:\" in *\":\$HOME/.local/bin:\"*) ;; *) PATH=\"\$HOME/.local/bin:\$PATH\" ;; esac\ncase \":\$PATH:\" in *\":\$HOME/.npm-global/bin:\"*) ;; *) PATH=\"\$HOME/.npm-global/bin:\$PATH\" ;; esac\nexport PATH\n# <<< ai-sandbox managed PATH\n" >>"$file"
  done
'

log "Installing/updating user-owned Codex CLI"
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://chatgpt.com/codex/install.sh \
    | CODEX_NON_INTERACTIVE=1 CODEX_INSTALL_DIR="$HOME/.local/bin" sh
  if command -v codex >/dev/null 2>&1; then
    if ! timeout 300 codex update </dev/null; then
      printf "[ai-sandbox-install][warn] codex update failed; continuing\n" >&2
    fi
  fi
'

log "Installing/updating user-owned Claude Code CLI"
rm -f /etc/claude-code/managed-settings.d/90-ai-sandbox-updates.json
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://claude.ai/install.sh | bash -s -- latest
  if command -v claude >/dev/null 2>&1; then
    if ! timeout 300 claude update </dev/null; then
      printf "[ai-sandbox-install][warn] claude update failed; continuing\n" >&2
    fi
  fi
'

log "Installing/updating user-owned OpenCode CLI"
runuser -u "$SANDBOX_USER" -- bash -lc '
  set -euo pipefail
  export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:$PATH"
  curl -fsSL https://opencode.ai/install | bash
'

# OpenCode config: NeuralWatt provider + full-auto permissions. The API key
# is resolved from the environment via {env:NEURALWATT_API_KEY}, which is
# synced from the host by the sandbox CLI (sync_host_opencode_profile).
log "Writing OpenCode config"
install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.config/opencode"
cat >"$USER_HOME/.config/opencode/opencode.jsonc" <<'OPENCODE_JSONC'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "neuralwatt/glm-5.2",
  "permission": {
    "*": "allow",
    "websearch": "allow",
    "webfetch": "allow"
  },
  "provider": {
    "neuralwatt": {
      "name": "Neuralwatt",
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "https://api.neuralwatt.com/v1",
        "apiKey": "{env:NEURALWATT_API_KEY}"
      },
      "models": {
        "glm-5.2": {
          "name": "GLM-5.2",
          "limit": {
            "context": 1048576,
            "output": 131072
          }
        }
      }
    }
  }
}
OPENCODE_JSONC
chown "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.config/opencode/opencode.jsonc"

if [ -d "$REPO_DIR/codex/skills" ]; then
  log "Installing repo Codex skills"
  install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.codex/skills"
  for skill in "$REPO_DIR"/codex/skills/*; do
    [ -d "$skill" ] || continue
    skill_name="$(basename "$skill")"
    rm -rf "$USER_HOME/.codex/skills/$skill_name"
    install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.codex/skills/$skill_name"
    tar -C "$skill" -cf - . \
      | tar -C "$USER_HOME/.codex/skills/$skill_name" -xf -
  done
fi

if [ -d "$REPO_DIR/codex/skills" ]; then
  log "Installing repo Claude skills"
  install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.claude/skills"
  for skill in "$REPO_DIR"/codex/skills/*; do
    [ -d "$skill" ] || continue
    skill_name="$(basename "$skill")"
    rm -rf "$USER_HOME/.claude/skills/$skill_name"
    install -d -m 755 -o "$SANDBOX_USER" -g "$SANDBOX_USER" "$USER_HOME/.claude/skills/$skill_name"
    tar -C "$skill" -cf - . \
      | tar -C "$USER_HOME/.claude/skills/$skill_name" -xf -
  done
  chown -R "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.claude/skills"
fi

# The git push guard is hook-based. Host-synced hooks win; otherwise install
# the repo defaults so every box has the guard.
if [ ! -f "$USER_HOME/.codex/hooks.json" ] && [ -f "$REPO_DIR/codex/hooks.json" ]; then
  log "Installing repo default Codex hooks"
  install -m 644 "$REPO_DIR/codex/hooks.json" "$USER_HOME/.codex/hooks.json"
  install -d -m 755 "$USER_HOME/.codex/hooks"
  install -m 755 "$REPO_DIR"/codex/hooks/*.py "$USER_HOME/.codex/hooks/"
fi
chown -R "$SANDBOX_USER:$SANDBOX_USER" "$USER_HOME/.codex"

# Codex runs without approval prompts or sandboxing inside the box. This is
# config, not a shell alias, so it applies to non-interactive sessions too.
runuser -u "$SANDBOX_USER" -- bash -c '
  set -e
  mkdir -p ~/.codex
  touch ~/.codex/config.toml
  # Top-level TOML keys must precede any [table], so prepend.
  sed -i \
    -e "/^approval_policy *=/d" \
    -e "/^sandbox_mode *=/d" \
    -e "/^check_for_update_on_startup *=/d" \
    ~/.codex/config.toml
  printf "approval_policy = \"never\"\nsandbox_mode = \"danger-full-access\"\n" \
    | cat - ~/.codex/config.toml > ~/.codex/config.toml.new
  mv ~/.codex/config.toml.new ~/.codex/config.toml
  for path in "$HOME" "$HOME/git-repos" "$HOME/.ai-sandbox/ai-sandbox-manager"; do
    if ! grep -Fq "[projects.\"${path}\"]" ~/.codex/config.toml; then
      printf "\n[projects.\"%s\"]\ntrust_level = \"trusted\"\n" "$path" >> ~/.codex/config.toml
    fi
  done
  # Remove the legacy bashrc alias surgery; config.toml replaces it.
  if [ -f ~/.bashrc ]; then
    sed -i \
      -e "/^alias yolo=codex-yolo$/d" \
      -e "/^alias cy=codex-yolo$/d" \
      -e "/^alias codex=codex-yolo$/d" \
      -e "/^alias codex='"'"'command codex --dangerously-bypass-approvals-and-sandbox'"'"'$/d" \
      -e "/^# Run Codex without approval prompts or sandboxing\.$/d" \
      ~/.bashrc
  fi
'

# Claude Code: mark onboarding done so non-interactive use works. Credentials
# and settings are synced from the host by the sandbox CLI.
runuser -u "$SANDBOX_USER" -- bash -c '
  set -e
  if [ ! -f ~/.claude.json ]; then
    printf "{\"hasCompletedOnboarding\": true, \"bypassPermissionsModeAccepted\": true}\n" > ~/.claude.json
  else
    jq ".hasCompletedOnboarding = true | .bypassPermissionsModeAccepted = true" ~/.claude.json > ~/.claude.json.new
    mv ~/.claude.json.new ~/.claude.json
  fi
'

# ---------------------------------------------------------------------------
# Legacy cleanup and service activation
# ---------------------------------------------------------------------------

log "Removing legacy managed tooling"
systemctl disable --now youart-cua-server.service youart-novnc.service youart-vnc.service >/dev/null 2>&1 || true
rm -f \
  /etc/systemd/system/youart-cua-server.service \
  /etc/systemd/system/youart-novnc.service \
  /etc/systemd/system/youart-vnc.service \
  /usr/local/bin/youart-start-cua-server \
  /usr/local/bin/youart-start-novnc \
  /usr/local/bin/youart-start-vnc \
  /usr/local/bin/youart-xstartup \
  /usr/local/bin/cuabot \
  /etc/youart-agent.env
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
  docker ps -a --format "{{.Names}}" \
    | awk '/^cuabot-xpra($|-)/ { print }' \
    | xargs -r docker rm -f >/dev/null 2>&1 || true
fi
runuser -u "$SANDBOX_USER" -- bash -lc '
  pkill -TERM -f "[n]pm exec cuabot --serve" >/dev/null 2>&1 || true
  pkill -TERM -f "[s]h -c cuabot --serve" >/dev/null 2>&1 || true
  pkill -TERM -f "[n]ode /usr/bin/cuabot --serve" >/dev/null 2>&1 || true
  pkill -TERM -f "[h]eadless_shell" >/dev/null 2>&1 || true
  rm -f "$HOME"/.cuabot/server*.pid "$HOME"/.cuabot/server*.port "$HOME"/.cuabot/server*.log
' || true

systemctl daemon-reload
systemctl enable --now sandbox-vnc.service sandbox-novnc.service sandbox-cua-server.service
systemctl restart sandbox-vnc.service sandbox-novnc.service sandbox-cua-server.service

log "Install complete"
