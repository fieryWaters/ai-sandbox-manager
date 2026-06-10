---
name: deskbot
description: Use this when browser or desktop GUI automation is needed. The canonical shell path is deskbot, which drives this box's native desktop. The cua computer-server HTTP API on 127.0.0.1:8000 drives the same desktop programmatically. noVNC is for human supervision only.
---

# Desktop Automation

Use `deskbot` for browser and desktop automation from the shell. It controls
the native desktop on `DISPLAY=:1` — the same desktop a human sees through
noVNC, so what you screenshot and click is exactly what they watch.

Before a new browser task, reset stale Chromium windows/tabs. This preserves
the persistent Chromium profile used for OAuth/login state.

After opening a browser or desktop app, focus and maximize it before taking
screenshots or clicking. Prefer `wmctrl` from inside `deskbot --bash`, for
example: `wmctrl -a Chromium 2>/dev/null || true; wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz 2>/dev/null || true`.

```bash
deskbot --reset
deskbot --bash 'cd "$HOME" && setsid chromium --new-window --disable-gpu --disable-vulkan --disable-dev-shm-usage --no-first-run --no-default-browser-check https://example.com >/tmp/deskbot-chromium.log 2>&1 < /dev/null & sleep 5; wmctrl -a Chromium 2>/dev/null || true; wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz 2>/dev/null || true'
deskbot --screenshot /tmp/deskbot-browser.jpg
deskbot --click 100 200
deskbot --type 'hello'
deskbot --key Enter
deskbot --scroll 600 500 0 -500
```

For programmatic control (Python SDK, HTTP), use the cua computer-server on
`127.0.0.1:8000` inside the box — it drives the same display. Do not start
your own desktop, Xvfb, or nested browser sandbox; one desktop per box.

For a local dev server running on the parent host, open the URL that is
reachable from the box's desktop: the host bridge, LAN, or Tailscale address
shown by the dev server or `sandbox list NAME`.

## AI Sandbox boxes

From the host, use the repo CLI:

```bash
sandbox list
sandbox view NAME
sandbox ssh NAME
sandbox doctor NAME
sandbox update NAME
```

`view` prints the noVNC URL for humans. Do not use noVNC as the agent
automation API.

If `deskbot` is missing or broken inside a box, run `sandbox update NAME`
from the host, then verify with `sandbox doctor NAME`. Doctor includes direct
pixel validation and agent-mediated browser smokes.
