---
name: cua-browser
description: Use this when browser GUI automation is needed. The canonical path is cuabot in the current shell or persistent AI sandbox VM. noVNC is for human supervision only; CUA HTTP is fallback/debug.
---

# Cua Browser Automation

Use `cuabot` for browser automation.

Before a new browser task, reset stale Chromium windows/tabs. This preserves the persistent Chromium profile used for OAuth/login state.

After opening a browser or desktop app, focus and maximize it before taking screenshots or clicking. Prefer `wmctrl` from inside `cuabot --bash`, for example: `wmctrl -a Chromium 2>/dev/null || true; wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz 2>/dev/null || true`.

In a managed AI Sandbox VM, `cuabot` controls the native desktop on `DISPLAY=:1`. `sandbox view NAME` shows that same desktop through noVNC for human supervision. The CUA HTTP API is installed only as fallback/debug.

```bash
cuabot --reset
cuabot --bash 'cd "$HOME" && setsid chromium --new-window --disable-gpu --disable-vulkan --disable-dev-shm-usage --no-first-run --no-default-browser-check https://example.com >/tmp/cuabot-chromium.log 2>&1 < /dev/null & sleep 5; wmctrl -a Chromium 2>/dev/null || true; wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz 2>/dev/null || true'
cuabot --screenshot /tmp/cua-browser.jpg
cuabot --click 100 200
cuabot --type 'hello'
cuabot --key Enter
cuabot --scroll 600 500 0 -500
```

For a local dev server running on the parent host, open the URL that is reachable from the VM desktop. `host.docker.internal` is useful when it resolves; otherwise use the host bridge, LAN, or Tailscale address shown by the dev server or `sandbox list NAME`.

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

`doctor` includes direct pixel validation and a Codex-mediated cuabot browser smoke.

## Fallback

Use CUA HTTP only when diagnosing cuabot or the desktop stack. It is not the normal browser-control path.
