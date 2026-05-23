#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INSTANCE="${INSTANCE:-youart-agent-base}"
AGENT_USER="${AGENT_USER:-agent}"
CODEX_HOME_SOURCE="${CODEX_HOME_SOURCE:-${HOME}/.codex}"
INCLUDE_CODEX_AUTH="${INCLUDE_CODEX_AUTH:-yes}"
SYNC_HOST_CODEX_PROFILE="${SYNC_HOST_CODEX_PROFILE:-yes}"
REPO_SKILLS_DIR="${REPO_SKILLS_DIR:-${REPO_ROOT}/codex/skills}"

log() { printf '[codex-sync] %s\n' "$*"; }

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$1" >&2
    exit 1
  fi
}

install_codex_yolo() {
  log "Installing codex-yolo helper"
  lxc exec "${INSTANCE}" -- bash -lc 'cat >/usr/local/bin/codex-yolo' <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec codex --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust "$@"
EOF
  lxc exec "${INSTANCE}" -- chmod +x /usr/local/bin/codex-yolo
  lxc exec "${INSTANCE}" -- runuser -u "${AGENT_USER}" -- bash -lc '
    touch ~/.bashrc
    grep -qxF "alias yolo=codex-yolo" ~/.bashrc || printf "\nalias yolo=codex-yolo\n" >> ~/.bashrc
    grep -qxF "alias cy=codex-yolo" ~/.bashrc || printf "alias cy=codex-yolo\n" >> ~/.bashrc
  '
}

append_lxc_trust() {
  log "Adding LXC project trust entries"
  lxc exec "${INSTANCE}" -- runuser -u "${AGENT_USER}" -- bash -lc '
    mkdir -p ~/.codex
    touch ~/.codex/config.toml
    add_trust() {
      path="$1"
      if ! grep -Fq "[projects.\"${path}\"]" ~/.codex/config.toml; then
        {
          printf "\n[projects.\"%s\"]\n" "$path"
          printf "trust_level = \"trusted\"\n"
        } >> ~/.codex/config.toml
      fi
    }
    add_trust "/home/agent"
    add_trust "/home/agent/git-repos"
    add_trust "/home/agent/git-repos/YouArtStudiosWeb"
  '
}

sync_host_profile() {
  if [ "${SYNC_HOST_CODEX_PROFILE}" != "yes" ]; then
    log "Skipping host Codex profile sync"
    return
  fi
  if [ ! -d "${CODEX_HOME_SOURCE}" ]; then
    log "Host Codex home not found: ${CODEX_HOME_SOURCE}"
    return
  fi

  local items=()
  for rel in config.toml rules memories skills; do
    if [ -e "${CODEX_HOME_SOURCE}/${rel}" ]; then
      items+=("${rel}")
    fi
  done
  if [ "${INCLUDE_CODEX_AUTH}" = "yes" ] && [ -f "${CODEX_HOME_SOURCE}/auth.json" ]; then
    items+=("auth.json")
  fi

  if [ "${#items[@]}" -eq 0 ]; then
    log "No host Codex profile files to sync"
    return
  fi

  log "Syncing selected host Codex profile files: ${items[*]}"
  lxc exec "${INSTANCE}" -- bash -lc "install -d -m 700 -o '${AGENT_USER}' -g '${AGENT_USER}' '/home/${AGENT_USER}/.codex'"
  tar -C "${CODEX_HOME_SOURCE}" -cf - "${items[@]}" \
    | lxc exec "${INSTANCE}" -- tar -C "/home/${AGENT_USER}/.codex" -xf -
}

sync_repo_skills() {
  if [ ! -d "${REPO_SKILLS_DIR}" ]; then
    log "Repo skill directory not found: ${REPO_SKILLS_DIR}"
    return
  fi

  log "Installing repo-bundled Codex skills from ${REPO_SKILLS_DIR}"
  lxc exec "${INSTANCE}" -- bash -lc "install -d -m 755 -o '${AGENT_USER}' -g '${AGENT_USER}' '/home/${AGENT_USER}/.codex/skills'"
  tar -C "${REPO_SKILLS_DIR}" -cf - . \
    | lxc exec "${INSTANCE}" -- tar -C "/home/${AGENT_USER}/.codex/skills" -xf -
}

fix_permissions() {
  log "Fixing Codex profile ownership and permissions"
  lxc exec "${INSTANCE}" -- bash -lc "
    chown -R '${AGENT_USER}:${AGENT_USER}' '/home/${AGENT_USER}/.codex'
    chmod 700 '/home/${AGENT_USER}/.codex'
    [ ! -f '/home/${AGENT_USER}/.codex/auth.json' ] || chmod 600 '/home/${AGENT_USER}/.codex/auth.json'
    [ ! -f '/home/${AGENT_USER}/.codex/config.toml' ] || chmod 600 '/home/${AGENT_USER}/.codex/config.toml'
    find '/home/${AGENT_USER}/.codex/skills' -type d -exec chmod 755 {} + 2>/dev/null || true
    find '/home/${AGENT_USER}/.codex/skills' -type f -exec chmod 644 {} + 2>/dev/null || true
  "
}

require lxc

sync_host_profile
sync_repo_skills
fix_permissions
append_lxc_trust
install_codex_yolo

log "Codex sync complete"
