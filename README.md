# AI Sandbox Manager

Utilities for building a persistent LXD/LXC workstation for browser-capable coding agents.

The current workstation profile creates an Ubuntu container with:

- XFCE desktop over TigerVNC/noVNC
- CUA computer-server exposed through a host proxy
- Chromium with a persistent user profile
- Codex CLI
- Docker-in-LXC with NVIDIA GPU support
- PyTorch Docker GPU smoke testing
- SSH server with a host proxy for remote access
- Selected Codex profile sync, repo-bundled skills, and `codex-yolo`

## Create The Workstation

```bash
sg lxd -c './scripts/create_agent_workstation_lxc.sh'
```

By default this creates or updates `youart-agent-base` and exposes:

- noVNC: `http://127.0.0.1:16901/`
- CUA: `http://127.0.0.1:28000/`
- SSH: `ssh -p 2222 agent@127.0.0.1`

The default noVNC password is `youart-agent`.

## Codex Profile Sync

The create script runs `scripts/sync_codex_profile_to_lxc.sh` by default. It copies selected Codex files from the host into `/home/agent/.codex`:

- `config.toml`
- `rules/`
- `memories/`
- `skills/`
- `hooks.json` and `hooks/`
- `git-hooks/`
- `auth.json` when `INCLUDE_CODEX_AUTH=yes`

It intentionally skips Codex logs, caches, sqlite state, shell snapshots, and history. Repo-bundled skills live in `codex/skills/` and are installed even if the host profile does not contain them.

The synced profile also installs hook-based push guards for agent shells. Codex loads `hooks.json`, and the LXC agent user gets global Git config pointing `core.hooksPath` at `~/.codex/git-hooks`. Normal Git commands are untouched; `git push` is blocked by the pre-push hook unless an operator deliberately bypasses hooks.

Useful overrides:

```bash
SYNC_CODEX_PROFILE=no sg lxd -c './scripts/create_agent_workstation_lxc.sh'
INCLUDE_CODEX_AUTH=no sg lxd -c './scripts/sync_codex_profile_to_lxc.sh'
```

## Verify

```bash
sg lxd -c './scripts/verify_agent_workstation.sh'
```

The verification script checks the desktop services, noVNC proxy, CUA API, Chromium profile persistence, Docker, direct GPU visibility, and PyTorch CUDA matmul inside Docker.

## Useful Overrides

```bash
INSTANCE=agent-001 NOVNC_HOST_PORT=16911 CUA_HOST_PORT=28010 SSH_HOST_PORT=2231 \
  sg lxd -c './scripts/create_agent_workstation_lxc.sh'
```

From another machine that can SSH to the host, use a jump through the host:

```bash
ssh -J spark -p 2222 agent@127.0.0.1
```

```bash
PYTORCH_IMAGE=nvcr.io/nvidia/pytorch:25.11-py3 \
  sg lxd -c './scripts/verify_agent_workstation.sh'
```
