#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/configs"

log() { printf '[ai-sandbox] %s\n' "$*"; }
warn() { printf '[ai-sandbox][warn] %s\n' "$*" >&2; }
die() { printf '[ai-sandbox][error] %s\n' "$*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

prompt() {
  local var_name="$1"
  local label="$2"
  local default="${3:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || true
    value="${value:-$default}"
  else
    read -r -p "$label: " value || true
  fi
  printf -v "$var_name" '%s' "$value"
}

confirm() {
  local label="$1"
  local answer
  read -r -p "$label (yes/no) [yes]: " answer || true
  answer="${answer:-yes}"
  [[ "$answer" == "yes" ]]
}

detect_uplink() {
  ip route get 1.1.1.1 2>/dev/null | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

detect_gateway() {
  ip route 2>/dev/null | awk '/^default / {print $3; exit}'
}

validate_config_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "Config name must match [A-Za-z0-9._-]+"
}

config_path() {
  local name="$1"
  printf '%s/%s.conf' "$CONFIG_DIR" "$name"
}

save_config() {
  local name="$1"
  local path
  path="$(config_path "$name")"
  mkdir -p "$CONFIG_DIR"
  cat > "$path" <<EOF
CONTAINER="$CONTAINER"
PROFILE="$PROFILE"
POOL="$POOL"
SOURCE="$SOURCE"
UPLINK="$UPLINK"
DNS1="$DNS1"
DNS2="$DNS2"
AUTOSTART="$AUTOSTART"
PRIVILEGED="$PRIVILEGED"
EOF
  log "Saved config: $path"
}

load_config() {
  local name="$1"
  local path
  path="$(config_path "$name")"
  [[ -f "$path" ]] || die "Config not found: $path"
  # shellcheck disable=SC1090
  source "$path"
  log "Loaded config: $path"
}

list_configs() {
  mkdir -p "$CONFIG_DIR"
  find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.conf' -printf '%f\n' | sed 's/\.conf$//' | sort
}

ensure_lxd_initialized() {
  if sudo lxc profile list >/dev/null 2>&1; then
    return 0
  fi
  log "LXD is not initialized. Running: sudo lxd init --auto"
  sudo lxd init --auto
}

create_or_update_storage_pool() {
  local pool="$1"
  local source="$2"
  sudo mkdir -p "$source"

  if sudo lxc storage show "$pool" >/dev/null 2>&1; then
    log "Storage pool '$pool' already exists."
  else
    log "Creating storage pool '$pool' at '$source'."
    sudo lxc storage create "$pool" dir source="$source"
  fi

  log "Pointing default profile root disk to pool '$pool'."
  sudo lxc profile device set default root pool "$pool"
}

configure_macvlan_profile() {
  local profile="$1"
  local uplink="$2"

  if ! sudo lxc profile show "$profile" >/dev/null 2>&1; then
    log "Creating profile '$profile' from default."
    sudo lxc profile copy default "$profile"
  fi

  sudo lxc profile device remove "$profile" eth0 >/dev/null 2>&1 || true
  sudo lxc profile device add "$profile" eth0 nic nictype=macvlan parent="$uplink" name=eth0
}

setup_container() {
  local container="$1"
  local profile="$2"
  local dns1="$3"
  local dns2="$4"
  local autostart="$5"
  local privileged="$6"

  if sudo lxc info "$container" >/dev/null 2>&1; then
    log "Container '$container' already exists."
  else
    log "Launching container '$container' (ubuntu:24.04)."
    sudo lxc launch ubuntu:24.04 "$container"
  fi

  sudo lxc stop "$container" >/dev/null 2>&1 || true

  log "Assigning profile '$profile' to '$container'."
  sudo lxc profile assign "$container" "$profile"

  log "Setting nested Docker compatibility flags."
  if [[ "$privileged" == "yes" ]]; then
    log "Enabling privileged LXC mode."
    sudo lxc config set "$container" security.privileged true
  else
    sudo lxc config unset "$container" security.privileged >/dev/null 2>&1 || true
  fi
  sudo lxc config set "$container" security.nesting true
  sudo lxc config set "$container" security.syscalls.intercept.mknod true
  sudo lxc config set "$container" security.syscalls.intercept.setxattr true

  if ! sudo lxc config device show "$container" | grep -q '^gpu0:'; then
    log "Adding GPU device (CDI id nvidia.com/gpu=0)."
    sudo lxc config device add "$container" gpu0 gpu gputype=physical id=nvidia.com/gpu=0
  else
    log "GPU device 'gpu0' already present."
  fi

  [[ "$autostart" == "yes" ]] && sudo lxc config set "$container" boot.autostart true || true

  log "Starting container '$container'."
  sudo lxc start "$container"

  log "Installing Docker and dependencies inside '$container'."
  sudo lxc exec "$container" -- bash -lc \
    'apt-get update && apt-get install -y git curl python3 docker.io ca-certificates gpg'
  sudo lxc exec "$container" -- systemctl enable --now docker

  log "Installing NVIDIA container toolkit inside '$container'."
  sudo lxc exec "$container" -- bash -lc \
    'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg && \
     curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list && \
     apt-get update && apt-get install -y nvidia-container-toolkit && \
     nvidia-ctk runtime configure --runtime=docker && \
     sed -i "s/^#\?no-cgroups.*/no-cgroups = true/" /etc/nvidia-container-runtime/config.toml && \
     systemctl restart docker'

  log "Pinning deterministic DNS inside '$container'."
  sudo lxc exec "$container" -- bash -lc \
    "systemctl disable --now systemd-resolved || true; \
     rm -f /etc/resolv.conf; \
     printf 'nameserver ${dns1}\nnameserver ${dns2}\noptions timeout:1 attempts:2\n' > /etc/resolv.conf; \
     chmod 644 /etc/resolv.conf"

  log "Pinning Docker daemon DNS inside '$container'."
  sudo lxc exec "$container" -- bash -lc \
    "printf '{\"dns\":[\"${dns1}\",\"${dns2}\"]}\n' > /etc/docker/daemon.json; \
     systemctl restart docker"

  log "Validation: container GPU visibility."
  sudo lxc exec "$container" -- nvidia-smi

  log "Validation: Docker GPU visibility."
  sudo lxc exec "$container" -- docker run --rm --gpus all nvidia/cuda:12.9.0-base-ubuntu24.04 nvidia-smi
}

undo_setup() {
  local container="$1"
  local profile="$2"
  local pool="$3"
  local source="$4"

  log "Stopping and deleting instances if present."
  sudo lxc stop "$container" >/dev/null 2>&1 || true
  sudo lxc delete "$container" --force >/dev/null 2>&1 || true

  log "Deleting profile '$profile' if present."
  sudo lxc profile delete "$profile" >/dev/null 2>&1 || true

  log "Restoring lxdbr0 MTU to 1500."
  sudo lxc network set lxdbr0 bridge.mtu 1500 >/dev/null 2>&1 || true

  if sudo lxc storage show default >/dev/null 2>&1; then
    log "Restoring default profile root pool to 'default' (if available)."
    sudo lxc profile device set default root pool default >/dev/null 2>&1 || true
  fi

  if sudo lxc storage show "$pool" >/dev/null 2>&1; then
    log "Deleting storage pool '$pool'."
    sudo lxc storage delete "$pool" >/dev/null 2>&1 || warn "Could not delete pool '$pool' (may still be in use)."
  fi

  if [[ -d "$source" ]]; then
    if confirm "Also remove storage directory '$source'?"; then
      sudo rm -rf "$source"
    fi
  fi
}

main() {
  need_cmd lxc
  need_cmd sudo
  need_cmd ip

  local mode="${1:-}"
  if [[ -z "$mode" ]]; then
    echo "Usage: $0 setup|undo|list-configs"
    exit 1
  fi

  local default_uplink
  local default_dns
  default_uplink="$(detect_uplink)"
  default_dns="$(detect_gateway)"
  default_uplink="${default_uplink:-eth0}"
  default_dns="${default_dns:-1.1.1.1}"

  case "$mode" in
    setup)
      prompt CONFIG_NAME "Config name (will save to ${CONFIG_DIR}/<name>.conf)" "default"
      validate_config_name "$CONFIG_NAME"
      prompt CONTAINER "Container name" "ai-sandbox"
      prompt PROFILE "Macvlan profile name" "ai-macvlan"
      prompt POOL "Storage pool name" "ai_sandbox_pool"
      prompt SOURCE "Storage source path" "/var/lib/ai-sandbox-manager/storage"
      prompt UPLINK "Host uplink interface for macvlan" "$default_uplink"
      prompt AUTOSTART "Enable container autostart (yes/no)" "yes"
      prompt PRIVILEGED "Enable privileged LXC mode for Docker-in-LXC GPU support (yes/no)" "no"
      DNS1="$default_dns"
      DNS2="8.8.8.8"
      echo
      log "About to apply setup with:"
      log "config=$CONFIG_NAME container=$CONTAINER profile=$PROFILE pool=$POOL source=$SOURCE uplink=$UPLINK dns=($DNS1,$DNS2) autostart=$AUTOSTART privileged=$PRIVILEGED"
      confirm "Proceed with setup?" || exit 0
      save_config "$CONFIG_NAME"
      ensure_lxd_initialized
      create_or_update_storage_pool "$POOL" "$SOURCE"
      configure_macvlan_profile "$PROFILE" "$UPLINK"
      setup_container "$CONTAINER" "$PROFILE" "$DNS1" "$DNS2" "$AUTOSTART" "$PRIVILEGED"
      log "Setup complete."
      ;;
    undo)
      log "Available configs:"
      list_configs || true
      prompt CONFIG_NAME "Config name to use for undo" "default"
      validate_config_name "$CONFIG_NAME"
      load_config "$CONFIG_NAME"
      echo
      log "About to remove setup artifacts from config '$CONFIG_NAME' (container '$CONTAINER')."
      confirm "Proceed with undo?" || exit 0
      undo_setup "$CONTAINER" "$PROFILE" "$POOL" "$SOURCE"
      log "Undo complete."
      ;;
    list-configs)
      list_configs
      ;;
    *)
      die "Unknown mode: $mode (use setup|undo|list-configs)"
      ;;
  esac
}

main "$@"
