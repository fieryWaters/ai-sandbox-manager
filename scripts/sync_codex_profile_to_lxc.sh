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
REPO_CODEX_DIR="${REPO_CODEX_DIR:-${REPO_ROOT}/codex}"

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
  for rel in config.toml hooks.json rules memories skills hooks git-hooks; do
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

sync_repo_codex_defaults() {
  if [ ! -d "${REPO_CODEX_DIR}" ]; then
    log "Repo Codex defaults directory not found: ${REPO_CODEX_DIR}"
    return
  fi

  for rel in hooks.json hooks git-hooks; do
    if [ ! -e "${REPO_CODEX_DIR}/${rel}" ]; then
      continue
    fi
    if lxc exec "${INSTANCE}" -- test -e "/home/${AGENT_USER}/.codex/${rel}"; then
      log "Keeping host-synced Codex ${rel}"
      continue
    fi
    log "Installing repo default Codex ${rel}"
    tar -C "${REPO_CODEX_DIR}" -cf - "${rel}" \
      | lxc exec "${INSTANCE}" -- tar -C "/home/${AGENT_USER}/.codex" -xf -
  done
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
    find '/home/${AGENT_USER}/.codex/hooks' -type d -exec chmod 755 {} + 2>/dev/null || true
    find '/home/${AGENT_USER}/.codex/hooks' -type f -exec chmod 755 {} + 2>/dev/null || true
    find '/home/${AGENT_USER}/.codex/git-hooks' -type d -exec chmod 755 {} + 2>/dev/null || true
    find '/home/${AGENT_USER}/.codex/git-hooks' -type f -exec chmod 755 {} + 2>/dev/null || true
  "
}

install_git_hooks() {
  log "Installing git pre-push guard for agent user"
  lxc exec "${INSTANCE}" -- bash -lc "
    if [ -L /usr/local/bin/git ] && [ \"\$(readlink /usr/local/bin/git)\" = '/home/${AGENT_USER}/.codex/bin/git' ]; then
      rm -f /usr/local/bin/git
    fi
    if [ -L /usr/bin/git ] && [ \"\$(readlink /usr/bin/git)\" = '/home/${AGENT_USER}/.codex/bin/git' ] && [ -x /usr/bin/git.real ]; then
      rm -f /usr/bin/git
      mv /usr/bin/git.real /usr/bin/git
    fi
    rm -f '/home/${AGENT_USER}/.codex/bin/git' '/home/${AGENT_USER}/.codex/bin/git-ssh'
  "
  lxc exec "${INSTANCE}" -- runuser -u "${AGENT_USER}" -- /usr/bin/git config --global core.hooksPath "/home/${AGENT_USER}/.codex/git-hooks"
  lxc exec "${INSTANCE}" -- runuser -u "${AGENT_USER}" -- /usr/bin/git config --global --unset core.sshCommand 2>/dev/null || true
}

require lxc

sync_host_profile
sync_repo_codex_defaults
sync_repo_skills
fix_permissions
install_git_hooks
append_lxc_trust
install_codex_yolo

log "Codex sync complete"
