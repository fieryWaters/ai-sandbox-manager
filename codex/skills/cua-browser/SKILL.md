---
name: cua-browser
description: Use this when browser GUI automation is needed through Cua/CuaBot or the persistent LXC agent workstation, especially for opening websites in Chromium, taking screenshots, clicking/typing/scrolling, validating UI behavior, or supervising an agent desktop through noVNC/CUA without filling the main context with browser setup debugging.
---

# Cua Browser Automation

Prefer the persistent LXC workstation for product work that needs login state, Docker/GPU, or a reusable desktop. Use host `cuabot` for quick disposable public-site browser checks.

## Persistent LXC Workstation

Default instance: `youart-agent-base`.

Host-facing endpoints:

- noVNC desktop: `http://127.0.0.1:16901/`
- CUA API: `http://127.0.0.1:28000/`
- SSH proxy: `ssh -p 2222 agent@127.0.0.1`
- Tailnet noVNC often works at `http://100.106.166.101:16901/` or `http://spark:16901/`

Inside the LXC:

- User: `agent`
- noVNC/VNC password: `youart-agent`
- CUA API: `http://127.0.0.1:8000/`
- Chromium wrapper: `/usr/local/bin/chromium`
- Chromium profile: `/home/agent/.config/chromium`
- Agent repos: `/home/agent/git-repos`

Check state from the host:

```bash
sg lxd -c 'lxc list youart-agent-base --format compact'
curl -fsS http://127.0.0.1:28000/status
curl -fsS -X POST http://127.0.0.1:28000/cmd \
  -H 'Content-Type: application/json' \
  -d '{"command":"get_screen_size","params":{}}'
```

Launch a page in the persistent desktop:

```bash
sg lxd -c 'lxc exec youart-agent-base -- runuser -u agent -- sh -lc "DISPLAY=:1 chromium http://127.0.0.1:18080 >/tmp/chromium.log 2>&1 &"'
```

Use noVNC for human supervision and the CUA API for screenshots/clicks/types. CUA `/cmd` responses may be server-sent-event text; inspect the raw response when JSON parsing fails.

Mac/noVNC note: noVNC can force clipped viewport mode on macOS overlay scrollbars. Prefer opening with `#autoconnect=1&resize=scale&password=youart-agent`. If the desktop appears zoomed/panned after paste or scroll gestures, reset host browser zoom with `Cmd+0`, remote Chromium zoom with `Ctrl+0`, or use `Cmd+scroll`/remote app zoom controls.

## Host Cuabot

`cuabot` is installed persistently at `/home/jacob/.npm-global/bin/cuabot` and should already be on `PATH`.

Local runtime setup:

- Config: `/home/jacob/.cuabot/settings.json`
- Docker image `trycua/cuabot:latest` is cached.
- Playwright Chromium for cuabot is installed in `/home/jacob/.cache/ms-playwright`.
- Xpra is available as `xpra`.

Basic workflow:

1. Check state:

```bash
command -v cuabot
cuabot --status
```

2. Open a public website in sandboxed Chromium:

```bash
cuabot --bash "chromium https://youartstudios.com >/tmp/youartstudios-chromium.log 2>&1 &"
```

For a local dev server running on the host, use `http://host.docker.internal:<port>` inside the sandbox.

3. Capture and inspect a screenshot:

```bash
cuabot --screenshot /tmp/cua-browser.jpg
```

Then view the image with the local image viewer tool.

4. Interact with the page:

```bash
cuabot --click <x> <y>
cuabot --type "text"
cuabot --key Tab
cuabot --scroll <x> <y> 0 <dy>
```

5. When the sandbox is no longer useful, stop it:

```bash
cuabot --stop
```

## Troubleshooting

If host cuabot startup fails, inspect existing state before reinstalling:

```bash
cuabot --status
tail -120 /home/jacob/.cuabot/server.log
docker ps --filter name=cuabot-xpra
docker logs cuabot-xpra --tail 120
```

Avoid rerunning first-time setup unless one of the cached requirements is actually missing.

For the LXC workstation, prefer fixing the running instance or updating `ai-sandbox-manager` scripts rather than ad hoc one-off setup. The repo-bundled skill and sync script are the source of truth for future instances.
