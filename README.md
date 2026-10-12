# herdr-ios

An iPhone and iPad client for [herdr](https://herdr.dev), reachable from
anywhere over Tailscale: live panes, a terminal key bar, agent
notifications, a home-screen widget and a Lock Screen Live Activity.

```
iPhone app ──wss (Tailscale)──▶ tailscale serve :8443 ──▶ gateway plugin ──▶ herdr socket
                                                              │
                                                              └──▶ APNs (notifications, widget, Live Activity)
```

- **`Gateway/`**: a herdr plugin (Bun). It serves the herdr socket API as an
  authenticated WebSocket, streams panes, and sends pushes straight from your
  Mac to Apple. See [Gateway/README.md](Gateway/README.md).
- **`Packages/HerdrKit/`**: the Swift client: models, ANSI rendering, message
  and code segmentation, link detection, scrollback splicing.
- **`App/`**: the SwiftUI app (XcodeGen project), the Agents widget, and the
  Live Activity.

## What the app does

- Workspaces, tabs, and splits (swipe between them on iPhone; side by side on
  iPad and foldables), live and reflowed to the phone's width.
- A composer with a key bar (esc, ^C, arrows, tab, …), quick-prompt chips,
  and copy buttons on agent messages and code blocks.
- Start agents (Claude Code, Codex, …) in new workspaces or panes; new tab,
  split and close.
- Scrollback, including Claude Code's history via its session transcript.
- Notifications when an agent needs you or finishes, with reply and choice
  buttons; an Agents widget; a summary Live Activity.

## Setup

1. Install the gateway into herdr: `cd Gateway && herdr plugin link "$PWD"`. It starts
   with herdr and writes its config (token, allowed Tailscale users) to
   herdr's plugin config dir.
2. Expose it on your tailnet:
   `tailscale serve --bg --https=8443 http://127.0.0.1:7777`.
3. Build the app: `cd App && xcodegen generate`, open `Herdr.xcodeproj`, set
   your team and bundle ID, run it on a device.
4. Pair: `herdr plugin pane open --plugin bal.ios-gateway --entrypoint pair`
   shows a QR code and a pairing link. More machines: install the gateway on
   each and add it in Settings → Gateways; switch from the home screen title.
5. Optional, for push: create an APNs key and run
   `sh Gateway/bin/gateway-ctl push-key <AuthKey.p8> <KEY_ID>`.

Status and next steps are in [TODO.md](TODO.md).
