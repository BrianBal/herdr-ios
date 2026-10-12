# iOS Herdr Client — Plan

## Status (2026-10-11)
- **Gateway plugin:** done. It's in `Gateway/`, linked into herdr, and served at `wss://<mac>.<tailnet>.ts.net:8443/ws`. See `Gateway/README.md` for the protocol.
- **HerdrKit:** done. It's in `Packages/HerdrKit` and holds the models, WebSocket client and ANSI renderer. `swift test` passes; set `HERDR_GATEWAY_URL`/`HERDR_GATEWAY_TOKEN` to also run the live tests.
- **iPhone app:** the Phase 2 build plus basic input is working in the Simulator against the live session. That covers pairing, the home screen, the workspace pager, the live terminal, the agents sheet, and the composer and key bar. Generate the project with `cd App && xcodegen generate`.
- Findings from the spikes:
  - herdr answers one request per connection.
  - Pane revisions don't track output, so the gateway diffs the text.
  - Pane reads contain only SGR codes, so the app reflows text instead of emulating a terminal grid.

A native SwiftUI app for iPhone and iPad that connects to the `herdr server` running on your Mac from any network over Tailscale. It shows the herdr workspaces, tabs, panes and agents, and lets you read and drive them from the phone.

## What we're talking to (verified on this machine)

- herdr **0.9.3**, API **protocol 22**. The server runs as `/opt/homebrew/bin/herdr server`.
- The API is **newline-delimited JSON over a Unix socket** at `~/.config/herdr/herdr.sock`. There is **no TCP listener**.
  - Request: `{"id":"1","method":"ping","params":{}}`. Response: `{"id":"1","result":{...}}` or `{"id":..,"error":{code,message}}`.
  - The full JSON Schema is available from `herdr api schema --json`. It's 270 KB and can drive Swift codegen.
- Useful methods:
  - **Topology:** `session.snapshot` returns workspaces, tabs, panes, agents, layouts and focus in one call. Also `workspace.*`, `tab.*`, `pane.list`, `pane.layout`.
  - **Terminal I/O:** `pane.read` (sources `visible`/`recent`/`recent_unwrapped`, format `text`/`ansi`, returns `revision`), `pane.send_input` (text plus logical keys), `pane.send_keys`, `pane.scroll`.
  - **Agents:** `agent.list/get/prompt/read/send_keys/wait/start`, with statuses `idle | working | blocked | done | unknown`.
  - **Streaming:** `events.subscribe` covers topology events (`workspace.*`, `tab.*`, `pane.created/closed/updated/focused/exited`, `pane.agent_detected`, `pane.agent_status_changed`, `pane.scroll_changed`, `pane.output_matched`).
  - `pane_output_changed {pane_id, revision}` exists as an event type, but it is **not** in the subscribable list. Live terminal updates are therefore the main technical risk (see Spike 1).
- `herdr --remote <ssh>` uses `herdr remote-client-bridge` over SSH with a separate, undocumented client protocol (`herdr-client.sock`). **We won't use it.** The public JSON API is stable and versioned.
- Tailscale is already up. This Mac is on the tailnet.

## Architecture

```
iPhone/iPad (Tailscale VPN app on)
   │  wss://<mac>.<tailnet>.ts.net/ws   (TLS cert via `tailscale serve`)
   ▼
herdr-gateway  (small daemon on the Mac, launchd, binds 127.0.0.1 only)
   │  NDJSON
   ▼
~/.config/herdr/herdr.sock  (herdr server)
```

### Why a gateway, not direct SSH from the phone
- The socket is Unix-only, so *something* has to bridge it. Using SSH from iOS (with Citadel/libssh2) would mean managing keys on the phone and running `socat` remotely. That works, but it's clunkier, and the phone would still have to poll.
- The gateway can do work the phone shouldn't have to:
  1. **Output fan-out.** It watches revisions for panes that clients are viewing and pushes only changes.
  2. **Auth.** Access needs both Tailscale identity and a bearer token. Tailscale `serve` also passes `Tailscale-User-Login` headers, so we can restrict access to `brian@`.
  3. **Method allowlist.** It blocks `server.stop`, `server.live_handoff`, `plugin.link`, and similar.
  4. **Push notifications** when an agent becomes `blocked` or `done` while the app is backgrounded.
  5. It insulates the app from herdr protocol bumps by checking `protocol` from `ping`.
- `tailscale serve --bg --https=443 http://127.0.0.1:7777` gives us a valid HTTPS cert and MagicDNS name. That means no ATS exceptions and no port exposed on the LAN.

### Gateway (Mac), packaged as a herdr plugin
The gateway ships as a herdr plugin (`herdr-plugin.toml`) instead of a separate LaunchAgent. herdr starts it with the server and passes it `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `HERDR_PLUGIN_CONFIG_DIR` and `HERDR_PLUGIN_STATE_DIR`. It installs with `herdr plugin install <you>/herdr-ios` (or `herdr plugin link ./Gateway` during development).

```toml
id = "bal.ios-gateway"
name = "iOS Gateway"
version = "0.1.0"
min_herdr_version = "0.9.3"
platforms = ["macos", "linux"]

[[build]]
command = ["swift", "build", "-c", "release"]      # or bun/cargo, see below

[[startup]]
command = ["./bin/gateway-ctl", "ensure"]          # idempotent: spawn detached daemon if not healthy

[[actions]]
id = "pair"
title = "iOS: show pairing QR"
command = ["./bin/gateway-ctl", "pair"]           # opened as a popup pane

[[actions]]
id = "status"
title = "iOS: gateway status / restart"
command = ["./bin/gateway-ctl", "restart"]

[[panes]]
id = "pair"
title = "Pair iPhone"
placement = "popup"
width = 60
height = 32
command = ["./bin/gateway-ctl", "pair"]           # renders QR (wss URL + token) in the terminal
```

**Catch:** herdr documents `[[startup]]` hooks as *one-shot, not supervised daemons*. So `gateway-ctl ensure` has to:
1. Check `$HERDR_PLUGIN_STATE_DIR/gateway.pid` and `GET /healthz`, and exit early if the gateway is already healthy. The hook also re-runs on live handoff.
2. Otherwise spawn the daemon detached (`setsid`/double-fork, stdio redirected to `$HERDR_PLUGIN_STATE_DIR/gateway.log`), write the pidfile, and exit 0.
3. The daemon must survive the herdr server going away. It reconnects to `HERDR_SOCKET_PATH` with backoff and exits after about 10 minutes without a server. Spike 4 checks that herdr doesn't kill the hook's process group.

Config (token, port, allowed tailnet users) lives in `$HERDR_PLUGIN_CONFIG_DIR/config.toml`, and `gateway-ctl ensure` generates a token the first time it runs.

- **Language:**
  - **Swift** (a SwiftPM executable with Hummingbird and NIO): shares `HerdrKit` models with the app, but `swift build` makes installs slow.
  - **Bun:** zero dependencies thanks to the native `Bun.serve` WebSocket and `Bun.connect({unix})`, and it's installed here. This is the fastest route to a working gateway.
  - **Rust:** best for distributing a single binary.
  - Recommendation: **Bun for v1**, revisit later.
- **Endpoints:**
  - `GET /ws` is a WebSocket that proxies JSON-RPC: the app sends `{id, method, params}` and the gateway forwards it to the socket and returns the response. Per-connection subscriptions are mirrored to `events.subscribe` on its own socket connection.
  - Gateway-specific methods:
    - `gw.watch_pane {pane_id, source:"visible", format:"ansi"}` makes the gateway poll `pane.read` at 10–20 Hz for that pane only. It sends `gw.pane_frame {pane_id, revision, text}` when the revision changes and backs off when nothing changes.
    - `gw.unwatch_pane`.
    - `gw.register_push {apns_token}`.
  - `GET /healthz`.
- `tailscale serve --bg --https=443 http://127.0.0.1:<port>` is a one-time setup. `gateway-ctl pair` prints the exact command if it isn't configured yet.

### iOS app
- SwiftUI on iOS 18 and later. One target serves both iPhone and iPad. It uses Swift Concurrency and `@Observable`.
- **Modules:**
  - `HerdrKit`: Codable models generated from the schema plus a hand-written `HerdrClient` actor (WebSocket, id correlation, async `call()`, `AsyncStream` events, reconnect with backoff).
  - `SessionStore`: an `@Observable` mirror of `session.snapshot` that applies events incrementally and re-snapshots on reconnect or gaps.
  - `TerminalView`: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) wrapped in `UIViewRepresentable`. Each frame resets and redraws the ANSI `visible` text, sized to herdr's viewport rows.
  - `Composer`: the input bar.
- **Networking:** the phone runs the official Tailscale app (always-on VPN), so the app just dials the MagicDNS host. Embedding Tailscale through TailscaleKit/tsnet is a later option if we want the app to work without the VPN toggled on.

## UI: mapping herdr panels to iOS

| herdr (TUI) | iPad | iPhone |
|---|---|---|
| Left sidebar: workspaces with agent-status dots | `NavigationSplitView` sidebar column | Root list, with a swipe-from-left-edge drawer when inside a pane |
| Tabs within a workspace | Segmented control or tab strip in the toolbar | Horizontal tab chips at the top of the workspace screen |
| Pane split layout | Detail column renders the real split layout from `pane.layout` rects, scaled. Tap a pane to focus it, double-tap to zoom | One pane at a time; swipe left/right between panes, plus a mini-map button that shows the layout |
| Agents panel (all agents and their status) | `.inspector` trailing side panel, toggled from the toolbar | Sheet with detents (`.medium`/`.large`), reachable from a toolbar button and a badge |
| Notifications (blocked/done) | Banner plus badge in the sidebar | Same, plus push when backgrounded |
| Keybindings | Hardware keyboard: `⌘1–9` workspaces, `⌘[`/`⌘]` tabs, `⌘K` command palette | Key accessory bar: Esc, Tab, Ctrl, ↑↓←→, ⏎, ^C |

**Pane screen:**
- Terminal on top.
- The bottom composer has two modes:
  - **Prompt mode**, used when the pane holds an agent, sends through `agent.prompt` with bracketed-paste-safe submission.
  - **Raw mode** sends through `pane.send_input` with text and keys.
- When an agent is `blocked`, an **approval card** shows the last N lines (`agent.read`) plus quick keys like `1`/`2`/`y`/`n`/Esc, so approvals take one tap.

**Agent status colors** match herdr: working, blocked (attention), done (unseen), idle, unknown.

## Phases

### Phase 0: Spikes (½–1 day)
1. **Live output.** Measure the cost of `pane.read visible ansi` at 10–20 Hz on a busy Claude pane. Also check whether `pane.output_matched` with regex `.` or the internal `pane_output_changed` can be subscribed, to avoid blind polling. Decide the gateway's polling and diff strategy.
2. **Viewport size.** Panes are rendered at the Mac's size, for example 81 rows. Decide between letting the phone scale and font-fit with horizontal pan, or using `recent_unwrapped` text for a reflowed "reader" mode on iPhone. (We probably want both: a terminal view plus a reader view.)
3. Confirm `tailscale serve` with WebSocket upgrade, and check the identity headers from the phone.
4. Plugin lifecycle: confirm that a detached child spawned by a `[[startup]]` hook survives after the hook exits, a server restart, and `herdr update --handoff`.

### Phase 1: Gateway plugin MVP (1–2 days)
- A `Gateway/` herdr plugin that proxies WebSocket to the socket, with token auth, the allowlist, `gw.watch_pane`, the `gateway-ctl ensure` startup hook, and a pairing QR popup. Develop it with `herdr plugin link`.
- CLI test: `websocat wss://<mac>.<tailnet>.ts.net:8443/ws` → `session.snapshot`.

### Phase 2: App MVP, read-only (2–3 days)
- Xcode project, HerdrKit models (codegen script from `herdr api schema --json`), and `HerdrClient`.
- Connection setup screen: host and token. The token is stored in Keychain, and a QR code from `herdr-gateway pair` can fill it in.
- Sidebar (workspaces plus status), tabs, pane list, and SwiftTerm rendering of watched panes.
- Agents inspector or sheet.

### Phase 3: Interaction (2–3 days)
- Composer (prompt and raw modes), the key accessory bar, hardware keyboard shortcuts.
- Approval card for blocked agents.
- Scrollback through `pane.scroll` or `recent` reads, with pull to load more.
- Actions:
  - Focus pane, zoom, and new tab/pane.
  - `agent.start` from a picker of kinds: claude, codex, and so on.
  - Rename and close, with confirmation.

### Phase 4: Background and notifications (1–2 days)
- The gateway subscribes to `pane.agent_status_changed` and sends APNs (token-based `.p8` auth over HTTP/2) on `blocked` or `done`. The fallback is ntfy.sh if we skip an Apple dev push setup.
- Notification actions open the app straight to that pane. A Live Activity or widget could show working and blocked agent counts.

### Phase 5: Polish
- Split-layout rendering on iPad, the command palette, multiple servers (other machines on the tailnet), Stage Manager windows (one pane per window), haptics, and offline/reconnect states.

## Repo layout

```
ios-herdr/
  PLAN.md
  Gateway/            herdr plugin: herdr-plugin.toml, bin/gateway-ctl, gateway daemon source
  HerdrKit/           SwiftPM: models (generated), client, shared by app + gateway
  App/HerdrApp.xcodeproj  (or XcodeGen project.yml)
  scripts/gen-models.swift   herdr api schema --json → Swift Codable
```

## Risks and open questions
- **Live output fidelity.** Polling ANSI snapshots is fine for agents but feels laggy for full-screen TUIs like vim or htop. If we need real streaming, the only path is herdr's private client protocol, which would be a stretch goal and an upstream ask.
- **Protocol drift.** herdr updates (`herdr update`) can bump `protocol`. The gateway should check it and the app should show a "server too new/old" banner.
- **Security.** The gateway gives full shell control of the Mac from the phone. Protection is layered: Tailscale ACLs restrict the gateway port to your devices, the gateway checks the `Tailscale-User-Login` header, a bearer token is required, and dangerous methods are on a denylist. Face ID unlock in the app is optional.
- **Push** needs a paid Apple Developer account for APNs. Without one, use ntfy or local notifications while the app is foregrounded.
- **Decisions for you:**
  - Gateway plugin in Bun (fastest), Swift (shared models) or Rust (single binary)?
  - iPhone-first or iPad-first layout?
  - Use APNs (needs a dev account) or ntfy?
