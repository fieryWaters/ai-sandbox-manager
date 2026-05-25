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

Inside the LXC:

- User: `agent`
- noVNC/VNC password: `agent-desktop`
- CUA API: `http://127.0.0.1:8000/`
- App URL: `http://127.0.0.1:18080/`
- Chromium wrapper: `/usr/local/bin/chromium`
- Chromium profile: `/home/agent/.config/chromium`
- Agent repos: `/home/agent/git-repos`

Port rule:

- If you are on the parent host, use CUA at `http://127.0.0.1:28000`.
- If you are already inside the LXC, use CUA at `http://127.0.0.1:8000`.
- Do not use the parent-host CUA port `28000` from inside the LXC.

Check state from the host:

```bash
sg lxd -c 'lxc list youart-agent-base --format compact'
curl -fsS http://127.0.0.1:28000/status
curl -fsS -X POST http://127.0.0.1:28000/cmd \
  -H 'Content-Type: application/json' \
  -d '{"command":"get_screen_size","params":{}}'
```

Check state from inside the LXC:

```bash
curl -fsS http://127.0.0.1:8000/status
curl -fsS http://127.0.0.1:8000/commands
curl -fsS -X POST http://127.0.0.1:8000/cmd \
  -H 'Content-Type: application/json' \
  -d '{"command":"get_screen_size","params":{}}'
```

Launch a page in the persistent desktop from inside the LXC:

```bash
DISPLAY=:1 /usr/local/bin/chromium http://127.0.0.1:18080 >/tmp/chromium.log 2>&1 &
```

Launch a page in the persistent desktop from the parent host:

```bash
sg lxd -c 'lxc exec youart-agent-base -- runuser -u agent -- sh -lc "DISPLAY=:1 chromium http://127.0.0.1:18080 >/tmp/chromium.log 2>&1 &"'
```

Use noVNC for human supervision and the CUA API for screenshots/clicks/types. CUA `/cmd` responses are server-sent-event style lines such as `data: {...}`, so strip the `data: ` prefix before parsing JSON.

Minimal CUA HTTP usage:

```bash
CUA_BASE=http://127.0.0.1:8000  # inside LXC; use 28000 on the parent host

curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"left_click","params":{"x":640,"y":420}}'

curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"type_text","params":{"text":"hello"}}'

curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"press_key","params":{"key":"Enter"}}'

curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"hotkey","params":{"keys":["CTRL","L"]}}'

curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"scroll","params":{"x":0,"y":-5}}'
```

Capture a screenshot to a PNG:

```bash
CUA_BASE=http://127.0.0.1:8000  # inside LXC; use 28000 on the parent host
raw="$(curl -sS -X POST "$CUA_BASE/cmd" \
  -H 'Content-Type: application/json' \
  -d '{"command":"screenshot","params":{}}')"
printf '%s\n' "${raw#data: }" | python3 -c '
import base64, json, sys
payload = json.load(sys.stdin)
open("/tmp/cua-screen.png", "wb").write(base64.b64decode(payload["image_data"]))
'
```

Useful command names from `/commands`: `screenshot`, `get_screen_size`, `get_cursor_position`, `left_click`, `double_click`, `right_click`, `move_cursor`, `drag_to`, `type_text`, `press_key`, `hotkey`, `scroll`, `scroll_down`, `scroll_up`, `open`, and `launch`.

For visual bug hunts, prefer: open page in Chromium on `DISPLAY=:1`, capture screenshots with CUA, use noVNC only for supervision, and use DOM/CDP measurement only as a supplement.

Mac/noVNC note: noVNC can force clipped viewport mode on macOS overlay scrollbars. Prefer opening with `#autoconnect=1&resize=scale&password=agent-desktop`. If the desktop appears zoomed/panned after paste or scroll gestures, reset host browser zoom with `Cmd+0`, remote Chromium zoom with `Ctrl+0`, or use `Cmd+scroll`/remote app zoom controls.

## Host Cuabot

`cuabot` should already be on `PATH` after setup.

Local runtime setup:

- Config: `~/.cuabot/settings.json`
- Docker image `trycua/cuabot:latest` is cached.
- Playwright Chromium for cuabot is installed in `~/.cache/ms-playwright`.
- Xpra is available as `xpra`.

Basic workflow:

1. Check state:

```bash
command -v cuabot
cuabot --status
```

2. Open a public website in sandboxed Chromium:

```bash
cuabot --bash "chromium https://example.com >/tmp/example-chromium.log 2>&1 &"
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
tail -120 ~/.cuabot/server.log
docker ps --filter name=cuabot-xpra
docker logs cuabot-xpra --tail 120
```

Avoid rerunning first-time setup unless one of the cached requirements is actually missing.

For the LXC workstation, prefer fixing the running instance or updating `ai-sandbox-manager` scripts rather than ad hoc one-off setup. The repo-bundled skill and sync script are the source of truth for future instances.
