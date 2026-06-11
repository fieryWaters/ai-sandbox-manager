# AI Sandbox Manager

Persistent LXD agent boxes that are easy to reach from Spark and easy to repair
when tooling drifts. Each box runs one native desktop; Codex and Claude Code
run inside with computer use against that desktop.

## Contract

Use the root CLI:

```bash
sandbox create NAME [--port-base N] [--user USER] [--memory LIMIT]
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
- `sandbox update NAME` repairs the box tooling from this repo.
- `sandbox copy SOURCE DEST` is the day-to-day golden-box cloning path.
- `sandbox export NAME` is the portable backup path.
- Each box has exactly one desktop (`DISPLAY=:1`). Agents drive it with
  `deskbot` from the shell or cua computer-server (port 8000 in the box)
  programmatically. noVNC shows the same desktop to humans.
- The host mirror of box config is authoritative; the box cannot change its
  own exposure.

Host-side managed state lives under:

```bash
~/.ai-sandbox
```

That includes SSH keys, managed SSH config, known-host entries, host box config
mirrors, and default archives. The only intentional touch outside that
directory is a single `Include ~/.ai-sandbox/ssh/config` line in
`~/.ssh/config`, so normal `ssh NAME` works.

## Repo Layout

Everything that ends up inside a box is a real, checked-in file — nothing is
generated from heredocs:

```text
sandbox                  Host CLI (the only entry point on Spark)
install.sh               In-box installer: packages + copies vm/ into place
uninstall-managed.sh     Removes managed tooling; preserves user state
vm/bin/                  deskbot, chromium launcher, service start scripts
vm/systemd/              sandbox-vnc / sandbox-novnc / sandbox-cua-server units
vm/doctor/               Pixel and agent-trace validation run by doctor
codex/hooks*             Codex git-push guard (hook-based)
codex/skills/deskbot/    Agent-facing skill for desktop automation
```

The whole checkout is synced into each box at
`/home/<user>/.ai-sandbox/ai-sandbox-manager`, and doctor runs its validation
scripts from there — the code that runs is the code you read in `vm/`.

## Desktop Topology

There is one managed desktop in the box: the native VNC desktop on
`DISPLAY=:1`.

- `deskbot` (vm/bin/deskbot) is a thin xdotool/xwd client of that display for
  shell-driven agents: `--reset`, `--bash`, `--screenshot`, `--click`,
  `--type`, `--key`, `--scroll`.
- cua computer-server runs in "host mode" against the same display and serves
  the canonical programmatic API on port 8000 (proxied to `PORT_BASE + 2`).
- noVNC serves the same display to humans (`PORT_BASE + 1`).

Do not install the upstream `cuabot` npm tool inside boxes: it launches its
own Docker+Xpra desktop, which nests containers and diverges from the desktop
noVNC shows. `deskbot` deliberately has a different name so the two cannot be
confused. The installer and uninstaller remove legacy nested cuabot state.

The `chromium` command is also managed (vm/bin/chromium): Ubuntu's chromium is
a snap that cannot run in LXC, so the launcher wraps Playwright's chrome with
a persistent profile and container-safe flags. Agents should `deskbot --reset`
before browser work; the persistent Chromium profile holds intentional OAuth
state and must not be deleted.

## Agents

`sandbox create` and `sandbox update` sync host agent profiles into the box:

- **Codex**: `~/.codex` auth, config, `AGENTS.md`, hooks (including the
  git-push guard), rules, memories, plus repo skills. Approval bypass is set
  in `config.toml` (`approval_policy`, `sandbox_mode`) — no shell aliases.
- **Claude Code**: `~/.claude/.credentials.json`, `settings.json`,
  `CLAUDE.md`, agents, and skills, plus a minimal `~/.claude.json` (onboarding
  complete, bypass-permissions accepted, host account identity). Claude runs
  non-interactively as `claude -p --dangerously-skip-permissions ...`.

Codex behavior rules that must load in every new agent belong in the host
`~/.codex/AGENTS.md`; Claude equivalents belong in the host `~/.claude/CLAUDE.md`.
Both are copied on create/update.

`git push` is blocked for Codex by the hook in `codex/hooks/`. This is an
advisory guard against accidental pushes, not a security boundary — the box
user has passwordless sudo.

## Create

```bash
sandbox create agent-001 --port-base 2230
```

New boxes default to `limits.memory=100GiB` so runaway builds OOM inside their
own box instead of starving the host and LXD. Use `--memory LIMIT` to choose a
different LXD memory limit, for example:

```bash
sandbox create agent-001 --memory 64GiB
```

Use `--memory none` only for boxes that intentionally need all host memory.

Ports are always contiguous:

- SSH: `PORT_BASE`
- noVNC: `PORT_BASE + 1`
- computer-server: `PORT_BASE + 2`

If any port in the block is busy, create fails before the box becomes useful.

The runtime user defaults to `agent`. `--user` is a create-time choice; update
reads the recorded user and does not migrate home directories.

Create from a portable archive:

```bash
sandbox create agent-from-golden --from golden
sandbox create agent-from-file --from /mnt/external_ssd/sandboxes/golden.tar.gz
```

If `--from` is a name rather than a file path, it resolves to
`~/.ai-sandbox/archives/NAME.tar.gz`. Imported boxes keep the box filesystem
from the archive but receive fresh host ports, fresh host SSH keys, a fresh
VNC password, rewritten managed config, and a hostname matching the new name.
Imported exposure defaults to localhost.

## Start And Stop

```bash
sandbox stop NAME
sandbox start NAME
```

Stop preserves the LXD instance, `box.env`, SSH key, managed SSH config, and
LXD proxy devices. Stopped boxes still reserve their configured three-port
block, so new boxes will not accidentally reuse their ports.

## Copy And Export

```bash
sandbox stop youart-agent-golden
sandbox copy youart-agent-golden agent-004
```

The source must be stopped so the copied filesystem is consistent. The
destination gets the next free port block, a fresh host SSH keypair, a fresh
VNC password, a matching hostname, and localhost-only exposure unless bind
flags are supplied.

For portable backups, `sandbox export NAME` writes
`~/.ai-sandbox/archives/NAME.tar.gz`; restore with `sandbox create NEW --from`.

## Exposure

Each service has an explicit host bind address recorded in the host mirror:

```bash
SSH_BIND=127.0.0.1
NOVNC_BIND=127.0.0.1
CUA_BIND=127.0.0.1
MEMORY_LIMIT=100GiB
```

Default is `127.0.0.1` (Spark-local). Use `--public` or per-service
`--ssh-bind/--novnc-bind/--cua-bind 0.0.0.0` to expose on host interfaces.
`sandbox list` summarizes exposure per box; `sandbox list NAME` prints the
detailed access view with ready-to-copy commands (never private key contents).

Inside the box, VNC, noVNC, and computer-server bind to `127.0.0.1` only — the
LXD proxy devices connect from inside the box's network namespace, so nothing
is reachable from sibling boxes on the LXD bridge.

## Box Config And Trust

The per-box config is tiny and lives in two places:

```bash
~/.ai-sandbox/boxes/NAME.env          # host mirror — authoritative
/home/<user>/.ai-sandbox/box.env      # in-box copy — for install.sh only
```

The host writes the in-box copy and never reads it back once a mirror exists.
A box's agent (who has sudo inside) therefore cannot flip its own binds or
ports. The in-box fallback is read once only to adopt imported archives, and
every field is validated.

## SSH Keys

Each box gets a unique Spark-side key `~/.ai-sandbox/ssh/NAME_ed25519`; only
its public half is installed in that box. Managed config blocks live in
`~/.ai-sandbox/ssh/config` between `# >>> ai-sandbox NAME` markers, with
`HostKeyAlias ai-sandbox-NAME` against `~/.ai-sandbox/ssh/known_hosts` so
reused localhost ports never collide. Destroy removes exactly that box's
block, key, known-host entry, and host mirror.

## Update

```bash
sandbox update NAME
```

Update is the repair operation: starts the box if needed, reads the host
mirror, regenerates proxy devices and SSH config, syncs this checkout and the
host Codex/Claude profiles in, runs `uninstall-managed.sh` then `install.sh`,
and finishes with doctor. If the recorded port block is no longer free, update
warns and moves the box to the next free block.

Update preserves durable user state: Chromium profile/OAuth, Codex and Claude
auth/config, user SSH state, `git-repos`, `workspace`, `box.env`, logs.

Boxes installed before the `deskbot` rename are migrated automatically: the
installer and uninstaller remove `youart-*` units, `/etc/youart-agent.env`,
`/usr/local/bin/cuabot`, and nested cuabot desktop state.

## Package Security

Do not disable Ubuntu's automatic security update path in managed boxes.
`install.sh` handles the known apt lock race by retrying apt commands while
Ubuntu's background update job briefly owns `/var/lib/apt/lists/lock`. Keep
that retry behavior; never delete lock files or disable the security timers.

## Doctor

```bash
sandbox doctor NAME
```

Checks, in order: LXD instance, the three host ports, `ssh NAME`, hostname,
noVNC HTTP, computer-server `/status`, Codex login, Claude auth (a real
one-shot prompt), the deskbot command surface, direct deskbot screenshot
pixels, a Codex-mediated deskbot browser smoke (trace must show deskbot and
no forbidden paths), and a Claude-mediated deskbot browser smoke. The pixel
checks validate a magenta test page actually rendered on the shared desktop.

## Testing Strategy

Run the host CLI from a neutral directory, not from the repo checkout:

```bash
cd ~
command -v sandbox
sandbox help
```

Required smoke on a throwaway box:

```bash
sandbox create sandbox-smoke --port-base 2250
sandbox list sandbox-smoke
sandbox view sandbox-smoke
sandbox list
sandbox ssh sandbox-smoke -- hostname
sandbox stop sandbox-smoke
sandbox start sandbox-smoke
sandbox doctor sandbox-smoke
sandbox update sandbox-smoke
```

Required clone/export smoke:

```bash
sandbox stop sandbox-smoke
sandbox copy sandbox-smoke sandbox-copy
sandbox doctor sandbox-copy
sandbox stop sandbox-copy
sandbox export sandbox-copy
sandbox create sandbox-import --from sandbox-copy
sandbox doctor sandbox-import
printf 'sandbox-copy\n' | sandbox destroy sandbox-copy
printf 'sandbox-import\n' | sandbox destroy sandbox-import
```

To test the apt lock retry deterministically, hold the real apt lists lock in
the box and run update from another shell:

```bash
lxc exec sandbox-smoke -- python3 -c 'import fcntl, time; f=open("/var/lib/apt/lists/lock", "w"); fcntl.lockf(f, fcntl.LOCK_EX); print("LOCK_READY", flush=True); time.sleep(45)'
```

The pass condition is install output showing `apt is busy; waiting`, then
continuing after the lock releases.

After the throwaway path passes, test update on the persistent known-good box:

```bash
sandbox update youart-agent-base
sandbox doctor youart-agent-base
```

Do not destroy `youart-agent-base`.
