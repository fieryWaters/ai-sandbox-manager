---
name: cua-browser
description: Use this when browser GUI automation is needed. The canonical path is cuabot in the current shell or persistent AI sandbox VM. noVNC is for human supervision only; CUA HTTP is fallback/debug.
---

# Cua Browser Automation

Use `cuabot` first.

Before a new browser task, close stale Chromium windows/tabs in the cuabot sandbox. This keeps screenshots and coordinates predictable while preserving the persistent Chromium profile used for OAuth/login state.

Do not use noVNC, ffmpeg, xdotool, gnome-screenshot, or the raw CUA HTTP API for normal browser automation. Screenshots, clicks, typing, scrolling, and browser launch should go through `cuabot`.

```bash
cuabot --bash 'pkill -x chromium || true; chromium --new-window https://example.com >/tmp/cuabot-chromium.log 2>&1 &'
cuabot --screenshot /tmp/cua-browser.jpg
cuabot --click 100 200
cuabot --type 'hello'
cuabot --key Enter
cuabot --scroll 600 500 0 -500
```

For a local dev server running on the parent host, open it from cuabot Chromium with `http://host.docker.internal:<port>`.

## AI Sandbox VM

From Spark, use the repo CLI:

```bash
sandbox list
sandbox view NAME
sandbox ssh NAME
sandbox doctor NAME
sandbox update NAME
```

`view` prints the noVNC URL for humans. Do not use noVNC as the agent automation API.

If `cuabot` is missing or broken inside a VM, run:

```bash
sandbox update NAME
```

Then verify:

```bash
sandbox doctor NAME
```

Use full doctor when you need to prove Codex itself follows the browser contract:

```bash
sandbox doctor NAME --full
```

## Fallback

Use CUA HTTP only when diagnosing cuabot or the desktop stack. It is not the normal browser-control path.
