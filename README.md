# AI Sandbox Manager

Persistent LXD agent boxes that are easy to reach from Spark and easy to repair when tooling drifts.

## Contract

Use the root CLI:

```bash
sandbox create NAME [--port-base N] [--user USER]
sandbox update NAME
sandbox start NAME
sandbox stop NAME
sandbox copy SOURCE DEST
sandbox export NAME [FILE]
sandbox doctor NAME
sandbox view NAME
sandbox ssh NAME [-- command...]
sandbox list [NAME]
sandbox destroy NAME
sandbox help [COMMAND]
```

The important invariants:

- Spark must be able to run `ssh NAME`.
- `sandbox view NAME` prints the noVNC URL for the box.
- `sandbox update NAME` repairs the VM tooling from this repo.
- `sandbox copy SOURCE DEST` is the day-to-day golden-box cloning path.
- `sandbox export NAME` is the portable backup path.
- Agents use `cuabot` for browser automation on the VM's native desktop.
- noVNC is for human supervision of that same desktop.
- CUA HTTP is installed only as fallback/debug.

Host-side managed state lives under:

```bash
~/.ai-sandbox
```

That includes SSH keys, managed SSH config, known-host entries, host box config
mirrors, and default archives. The only intentional touch outside that directory is a single
`Include ~/.ai-sandbox/ssh/config` line in `~/.ssh/config`, so normal
`ssh NAME` works.

Before browser work, agents should run `cuabot --reset` to close stale Chromium windows/tabs. They should not delete the persistent Chromium profile because OAuth login state is intentional.

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

Create from a portable archive:

```bash
sandbox create agent-from-golden --from golden
sandbox create agent-from-file --from /mnt/external_ssd/sandboxes/golden.tar.gz
```

If `--from` is a name rather than a file path, it resolves to:

```bash
~/.ai-sandbox/archives/NAME.tar.gz
```

Imported boxes keep the VM filesystem from the archive but receive fresh host
ports, fresh host SSH keys, a fresh VNC/CUA password, rewritten managed config,
and a VM hostname matching the new sandbox name. Imported exposure defaults to
localhost unless `--public` or explicit bind flags are supplied.

## Start And Stop

```bash
sandbox stop NAME
sandbox start NAME
```

Stop preserves the LXD instance, `box.env`, SSH key, managed SSH config, and
LXD proxy devices. Stopped boxes still reserve their configured three-port
block, so new boxes will not accidentally reuse their ports.

Start brings the instance back up, refreshes SSH config from `box.env`, waits
for basic SSH, and prints the noVNC URL. Run `sandbox doctor NAME` when you
want full validation.

## Copy And Export

For normal golden-box workflows, use copy:

```bash
sandbox stop youart-agent-golden
sandbox copy youart-agent-golden agent-004
```

Copy uses LXD directly. The source must be stopped so the copied filesystem is
consistent. The destination gets the next free contiguous port block, a fresh
host SSH keypair, a fresh VNC/CUA password, a VM hostname matching the new
sandbox name, and localhost-only exposure unless bind flags are supplied:

```bash
sandbox copy youart-agent-golden agent-public --public
sandbox copy youart-agent-golden agent-mixed --ssh-bind 127.0.0.1 --novnc-bind 0.0.0.0 --cua-bind 127.0.0.1
```

For portable backups or moving a box between machines, use export:

```bash
sandbox stop youart-agent-golden
sandbox export youart-agent-golden
```

Without an explicit path, export writes:

```bash
~/.ai-sandbox/archives/youart-agent-golden.tar.gz
```

The source must be stopped first. To restore, use `sandbox create NEW --from
ARCHIVE_OR_NAME`.

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

`sandbox list` turns those binds into a compact fleet view. A service bound to
`127.0.0.1` is local. A service bound to `0.0.0.0` shows useful host
interfaces, including Tailscale when `tailscale0` is present:

```text
NAME                         STATUS     SSH                      NOVNC                        EXPOSURE
youart-agent-base            RUNNING    ssh youart-agent-base    http://127.0.0.1:2231/       ssh,noVNC on enP7s7,tailscale0
```

The list output reads the current LXD proxy devices when available, then falls
back to `box.env`. It intentionally filters noisy internal bridge interfaces
such as Docker and LXD bridges.

Use `sandbox list NAME` for the detailed access view:

```text
name: youart-agent-base
status: RUNNING
user: agent

ssh:
  alias: ssh youart-agent-base
  private key path: /home/jacob/.ai-sandbox/ssh/youart-agent-base_ed25519
  known hosts: /home/jacob/.ai-sandbox/ssh/known_hosts
  host key alias: ai-sandbox-youart-agent-base
  local: ssh youart-agent-base (127.0.0.1:2230)
  tailscale0: ssh -i /home/jacob/.ai-sandbox/ssh/youart-agent-base_ed25519 -p 2230 agent@100.106.166.101

noVNC:
  local: http://127.0.0.1:2231/
  tailscale0: http://100.106.166.101:2231/
```

The detailed view prints paths and ready-to-copy commands. It does not print
private key contents or the public key.

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
~/.ai-sandbox/ssh/NAME_ed25519
```

Only that key's public half is installed into that VM. The managed SSH config block uses `IdentityFile` and `IdentitiesOnly yes`, so access to one box does not imply access to every box.

Managed host keys also stay in the sandbox SSH directory:

```bash
~/.ai-sandbox/ssh/known_hosts
```

Each box uses `HostKeyAlias ai-sandbox-NAME`, so reused localhost ports do not collide with stale global `~/.ssh/known_hosts` entries.

The managed blocks live in:

```bash
~/.ai-sandbox/ssh/config
```

`~/.ssh/config` only needs this include:

```sshconfig
Include ~/.ai-sandbox/ssh/config
```

Each managed block looks like:

```sshconfig
# >>> ai-sandbox NAME
Host NAME
  HostName 127.0.0.1
  User agent
  Port 2230
  IdentityFile ~/.ai-sandbox/ssh/NAME_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ai-sandbox/ssh/known_hosts
  HostKeyAlias ai-sandbox-NAME
  StrictHostKeyChecking accept-new
# <<< ai-sandbox NAME
```

Update replaces only the matching managed block. Destroy removes the matching
block, the box-specific key, and the matching `ai-sandbox-NAME` known-hosts
entry.

## Update

Update is a repair operation:

```bash
sandbox update NAME
```

It starts the VM if needed, reads `box.env`, regenerates LXD proxy devices and
SSH config, syncs this checkout and the host Codex profile into the VM, runs:

```bash
./uninstall-managed.sh
./install.sh
```

Then it runs doctor.

Update also removes stale legacy managed-tooling shadows when they would win on
`PATH`. For example, older boxes had `/usr/local/bin/codex` pointing at an old
Codex install while the current managed npm prefix is `/usr`; `install.sh`
removes that stale copy before reinstalling Codex.

If the recorded port block is no longer available after old managed proxy devices are removed, update warns and moves the box to the next free contiguous block. The final `box.env` and SSH config are rewritten to match.

Update preserves durable user state:

- Chromium profile and OAuth state
- Codex auth/config/global `AGENTS.md`
- user SSH state
- `git-repos`
- `workspace`
- `box.env`
- logs

Codex behavior rules that must load in every new agent belong in the host
`~/.codex/AGENTS.md`. `sandbox create` and `sandbox update` copy that file into
the VM Codex home. Do not use `~/.codex/memories/*.md` as the primary control
surface for required behavior; Codex treats memories as generated recall state,
and the memory feature may be disabled.

## Package Security

Do not disable Ubuntu's automatic security update path in managed boxes. These VMs may be exposed beyond localhost, so `apt-daily.timer`, `apt-daily-upgrade.timer`, and `unattended-upgrades` should remain available.

`install.sh` handles the known apt lock race by retrying apt commands when Ubuntu's background update job briefly owns `/var/lib/apt/lists/lock`. Future changes should keep that retry behavior instead of deleting lock files or turning off automatic security updates.

## Browser Topology

There is one managed desktop in the VM: the native VNC desktop on `DISPLAY=:1`.

`sandbox view NAME` exposes that desktop through noVNC for humans. The managed
`cuabot` command controls that same desktop for agents. This keeps what the
human sees and what the agent screenshots/clicks in sync.

The installer removes legacy nested `cuabot-xpra` desktop state if it exists.
That path created a second hidden desktop, which made noVNC supervision and
agent screenshots disagree.

## Doctor

```bash
sandbox doctor NAME
```

Doctor checks LXD, the three host ports, `ssh NAME`, noVNC HTTP, CUA `/status`,
Codex login, the cuabot command surface, real screenshot pixels from the native
desktop, and a Codex-mediated browser smoke. The Codex smoke must use `cuabot`,
including `cuabot --screenshot`, and the resulting screenshot must contain the
expected test pixels.

## View

`view` is deliberately dumb:

```bash
sandbox view NAME
```

It prints only the noVNC URL:

```text
http://127.0.0.1:2231/
```

Use `sandbox list NAME` or `doctor` for details.

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
sandbox list sandbox-smoke
sandbox view sandbox-smoke
sandbox list
sandbox ssh sandbox-smoke -- hostname
sandbox stop sandbox-smoke
sandbox list sandbox-smoke
sandbox start sandbox-smoke
sandbox doctor sandbox-smoke
sandbox update sandbox-smoke
```

Verify the VM received this repo, not the PATH directory or stale files:

```bash
lxc exec sandbox-smoke -- runuser -u agent -- bash -lc \
  'cd ~/.ai-sandbox/ai-sandbox-manager && test -f sandbox && test -f install.sh && test -f uninstall-managed.sh && ./sandbox help >/dev/null'
```

When browser automation behavior changes, `sandbox doctor sandbox-smoke` is the
required browser verification. It includes both direct cuabot pixel validation
and a Codex-mediated cuabot smoke.

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
continues after the lock releases and doctor passes. Do not test this by
deleting apt lock files or disabling Ubuntu's automatic security update jobs.

Destroy only throwaway boxes, and verify exact-name confirmation:

```bash
printf 'sandbox-smoke\n' | sandbox destroy sandbox-smoke
```

Required clone/export smoke on throwaway boxes:

```bash
sandbox stop sandbox-smoke
sandbox copy sandbox-smoke sandbox-copy
sandbox ssh sandbox-copy -- hostname
sandbox doctor sandbox-copy
sandbox stop sandbox-copy
sandbox export sandbox-copy
sandbox create sandbox-import --from sandbox-copy
sandbox ssh sandbox-import -- hostname
sandbox doctor sandbox-import
printf 'sandbox-copy\n' | sandbox destroy sandbox-copy
printf 'sandbox-import\n' | sandbox destroy sandbox-import
```

After this smoke, verify managed host state lives under `~/.ai-sandbox`:

```bash
test -d ~/.ai-sandbox/ssh
test -d ~/.ai-sandbox/boxes
test -f ~/.ai-sandbox/ssh/config
test -f ~/.ai-sandbox/ssh/known_hosts
test ! -d ~/.ssh/ai-sandbox
grep -q "$HOME/.ai-sandbox/ssh/config" ~/.ssh/config
```

After the throwaway path passes, test update on the persistent known-good box:

```bash
sandbox update youart-agent-base
sandbox doctor youart-agent-base
```

Do not destroy `youart-agent-base`.
