# AI Sandbox Manager

Persistent LXD agent boxes that are easy to reach from Spark and easy to repair when tooling drifts.

## Contract

Use the root CLI:

```bash
sandbox create NAME [--port-base N] [--user USER]
sandbox update NAME
sandbox doctor NAME [--quick|--full]
sandbox view NAME
sandbox ssh NAME [-- command...]
sandbox list
sandbox status NAME
sandbox destroy NAME
sandbox help [COMMAND]
```

The important invariants:

- Spark must be able to run `ssh NAME`.
- `sandbox view NAME` prints the noVNC URL for the box.
- `sandbox update NAME` repairs the VM tooling from this repo.
- Agents use `cuabot` for browser automation.
- noVNC is for human supervision only.
- CUA HTTP is installed only as fallback/debug.

Before browser work, agents should close stale Chromium windows/tabs. They should not delete the persistent Chromium profile because OAuth login state is intentional.

## Create

Create a box from Spark:

```bash
sandbox create agent-001 --port-base 2230
```

Ports are always contiguous:

- SSH: `PORT_BASE`
- noVNC: `PORT_BASE + 1`
- CUA fallback: `PORT_BASE + 2`

If any port in the block is busy, create fails before the box becomes useful.

The runtime user defaults to `agent`:

```bash
sandbox create agent-002 --user agent --port-base 2240
```

`--user` is a create-time choice. Update reads the recorded user and does not migrate home directories.

## Exposure

Each service has an explicit host bind address in the VM config:

```bash
SSH_BIND=127.0.0.1
NOVNC_BIND=127.0.0.1
CUA_BIND=127.0.0.1
```

Default is `127.0.0.1`, meaning exposed only on Spark localhost. Use `0.0.0.0` only when you intentionally want access from the network:

```bash
sandbox create agent-public --port-base 2250 --public
sandbox create agent-mixed --port-base 2260 --ssh-bind 127.0.0.1 --novnc-bind 0.0.0.0 --cua-bind 127.0.0.1
```

`sandbox list` turns those binds into usable access addresses. A service bound
to `127.0.0.1` shows only local access. A service bound to `0.0.0.0` shows
local access plus useful host interfaces, including Tailscale when `tailscale0`
is present:

```text
youart-agent-base            RUNNING    managed
  ssh:   ssh youart-agent-base (127.0.0.1:2230)
         ssh -p 2230 agent@192.168.1.71 (enP7s7)
         ssh -p 2230 agent@100.106.166.101 (tailscale0)
  noVNC: http://127.0.0.1:2231/
         http://192.168.1.71:2231/ (enP7s7)
         http://100.106.166.101:2231/ (tailscale0)
  CUA:   http://127.0.0.1:2232/
```

The list output reads the current LXD proxy devices when available, then falls
back to `box.env`. It intentionally filters noisy internal bridge interfaces
such as Docker and LXD bridges.

## VM State

The VM-local config is intentionally tiny:

```bash
/home/<user>/.ai-sandbox/box.env
```

Current fields:

```bash
SANDBOX_USER=agent
PORT_BASE=2230
VNC_PASSWORD=<generated>
SSH_BIND=127.0.0.1
NOVNC_BIND=127.0.0.1
CUA_BIND=127.0.0.1
```

Everything else is convention or generated state. The repo is synced to:

```bash
/home/<user>/.ai-sandbox/ai-sandbox-manager
```

Logs live under:

```bash
/home/<user>/.ai-sandbox/logs
```

## SSH Keys

Each box gets a unique Spark-side SSH key:

```bash
~/.ssh/ai-sandbox/NAME_ed25519
```

Only that key's public half is installed into that VM. The managed SSH config block uses `IdentityFile` and `IdentitiesOnly yes`, so access to one box does not imply access to every box.

Managed host keys also stay in the sandbox SSH directory:

```bash
~/.ssh/ai-sandbox/known_hosts
```

Each box uses `HostKeyAlias ai-sandbox-NAME`, so reused localhost ports do not collide with stale global `~/.ssh/known_hosts` entries.

The managed block in `~/.ssh/config` looks like:

```sshconfig
# >>> ai-sandbox NAME
Host NAME
  HostName 127.0.0.1
  User agent
  Port 2230
  IdentityFile ~/.ssh/ai-sandbox/NAME_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/ai-sandbox/known_hosts
  HostKeyAlias ai-sandbox-NAME
  StrictHostKeyChecking accept-new
# <<< ai-sandbox NAME
```

Update replaces only the matching managed block. Destroy removes the matching block, the box-specific key, and the matching `ai-sandbox-NAME` known-hosts entry.

## Update

Update is a repair operation:

```bash
sandbox update NAME
```

It starts the VM if needed, reads `box.env`, regenerates LXD proxy devices and SSH config, syncs this checkout into the VM, runs:

```bash
./uninstall-managed.sh
./install.sh
```

Then it runs quick doctor.

If the recorded port block is no longer available after old managed proxy devices are removed, update warns and moves the box to the next free contiguous block. The final `box.env` and SSH config are rewritten to match.

Update preserves:

- Chromium profile and OAuth state
- Codex auth/config
- user SSH state
- `git-repos`
- `workspace`
- `box.env`
- logs

## Package Security

Do not disable Ubuntu's automatic security update path in managed boxes. These VMs may be exposed beyond localhost, so `apt-daily.timer`, `apt-daily-upgrade.timer`, and `unattended-upgrades` should remain available.

`install.sh` handles the known apt lock race by retrying apt commands when Ubuntu's background update job briefly owns `/var/lib/apt/lists/lock`. Future changes should keep that retry behavior instead of deleting lock files or turning off automatic security updates.

## Doctor

Quick doctor is the default:

```bash
sandbox doctor NAME
sandbox doctor NAME --quick
```

It checks LXD, the three host ports, `ssh NAME`, noVNC HTTP, CUA `/status`, Codex login, and the cuabot command/browser dependency surface.

Full doctor adds real browser automation:

```bash
sandbox doctor NAME --full
```

It runs a direct `cuabot` browser smoke and a Codex-mediated browser smoke. A second Codex pass judges the executed-command trace and must return exactly `true` or `false`; it returns `true` only when the browser work used `cuabot`, including `cuabot --screenshot`, without using ffmpeg, noVNC, xdotool, gnome-screenshot, or raw CUA.

## View

`view` is deliberately dumb:

```bash
sandbox view NAME
```

It prints only the noVNC URL:

```text
http://127.0.0.1:2231/
```

Use `status` or `doctor` for details.

## Testing Strategy

When changing this repo:

Run the host CLI from a neutral directory, not from the repo checkout. This
proves the `sandbox` command on PATH resolves the real repo root before it
syncs files into a VM.

```bash
cd ~
command -v sandbox
sandbox help
```

Required smoke on a throwaway VM:

```bash
sandbox create sandbox-smoke --port-base 2250
sandbox status sandbox-smoke
sandbox view sandbox-smoke
sandbox list
sandbox ssh sandbox-smoke -- hostname
sandbox doctor sandbox-smoke
sandbox update sandbox-smoke
```

Verify the VM received this repo, not the PATH directory or stale files:

```bash
lxc exec sandbox-smoke -- runuser -u agent -- bash -lc \
  'cd ~/.ai-sandbox/ai-sandbox-manager && test -f sandbox && test -f install.sh && test -f uninstall-managed.sh && ./sandbox help >/dev/null'
```

Run full doctor when browser automation behavior changes:

```bash
sandbox doctor sandbox-smoke --full
```

To test the apt lock retry deterministically, hold the real apt lists lock in
the VM and run update from another shell:

```bash
lxc exec sandbox-smoke -- python3 -c 'import fcntl, time; f=open("/var/lib/apt/lists/lock", "w"); fcntl.lockf(f, fcntl.LOCK_EX); print("LOCK_READY", flush=True); time.sleep(45)'
```

After `LOCK_READY` prints:

```bash
sandbox update sandbox-smoke
```

The pass condition is that install output shows `apt is busy; waiting`, then
continues after the lock releases and quick doctor passes. Do not test this by
deleting apt lock files or disabling Ubuntu's automatic security update jobs.

Destroy only throwaway boxes, and verify exact-name confirmation:

```bash
printf 'sandbox-smoke\n' | sandbox destroy sandbox-smoke
```

After the throwaway path passes, test update on the persistent known-good box:

```bash
sandbox update youart-agent-base
sandbox doctor youart-agent-base
```

Do not destroy `youart-agent-base`.
