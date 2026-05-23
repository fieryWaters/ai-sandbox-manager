# AI Sandbox Manager

Utilities for building a persistent LXD/LXC workstation for browser-capable coding agents.

The current workstation profile creates an Ubuntu container with:

- XFCE desktop over TigerVNC/noVNC
- CUA computer-server exposed through a host proxy
- Chromium with a persistent user profile
- Codex CLI
- Docker-in-LXC with NVIDIA GPU support
- PyTorch Docker GPU smoke testing

## Create The Workstation

```bash
sg lxd -c './scripts/create_agent_workstation_lxc.sh'
```

By default this creates or updates `youart-agent-base` and exposes:

- noVNC: `http://127.0.0.1:16901/`
- CUA: `http://127.0.0.1:28000/`

The default noVNC password is `youart-agent`.

## Verify

```bash
sg lxd -c './scripts/verify_agent_workstation.sh'
```

The verification script checks the desktop services, noVNC proxy, CUA API, Chromium profile persistence, Docker, direct GPU visibility, and PyTorch CUDA matmul inside Docker.

## Useful Overrides

```bash
INSTANCE=agent-001 NOVNC_HOST_PORT=16911 CUA_HOST_PORT=28010 \
  sg lxd -c './scripts/create_agent_workstation_lxc.sh'
```

```bash
PYTORCH_IMAGE=nvcr.io/nvidia/pytorch:25.11-py3 \
  sg lxd -c './scripts/verify_agent_workstation.sh'
```

