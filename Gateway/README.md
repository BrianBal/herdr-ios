# herdr iOS gateway plugin

A herdr plugin that exposes the herdr socket API (`herdr.sock`, NDJSON) as an authenticated WebSocket. `tailscale serve` publishes it to your tailnet so the iOS app can reach it from any network.

```
iOS app ──wss://<host>.ts.net:8443/ws──▶ tailscale serve ──▶ 127.0.0.1:7777 (gateway) ──▶ herdr.sock
```

## Install

Requires [Bun](https://bun.sh) and Tailscale.

```sh
cd Gateway && bun install
herdr plugin link "$PWD"                       # dev; or: herdr plugin install <owner>/<repo>/Gateway
sh bin/gateway-ctl ensure                       # herdr runs this automatically on every server start
tailscale serve --bg --https=8443 http://127.0.0.1:7777   # once
herdr plugin pane open --plugin bal.ios-gateway --entrypoint pair   # pairing QR
```

`gateway-ctl` commands: `ensure`, `stop`, `restart`, `status`, `pair [--wait]`, `rotate-token`, `run` (foreground).
herdr actions: `bal.ios-gateway.restart`, `bal.ios-gateway.status`.

| What | Where |
|---|---|
| Config (port, token, allowlist, denied methods) | `$(herdr plugin config-dir bal.ios-gateway)/config.toml` (mode 600) |
| Log + pidfile | `~/.local/state/herdr/plugins/bal.ios-gateway/` |

### Lifecycle
herdr `[[startup]]` hooks are one-shot. `gateway-ctl ensure` exits right away if `/healthz` answers. Otherwise it spawns `src/daemon.ts` detached (own session, reparented to launchd) and waits for it to become healthy. The daemon keeps running across herdr restarts and exits after herdr has been unreachable for 10 minutes. The next server start runs the hook again.

## Security
- Binds `127.0.0.1` only. Remote access goes only through `tailscale serve`.
- Every WebSocket upgrade needs `Authorization: Bearer <token>` (a `?token=` query parameter also works for CLI testing).
- Requests from the tailnet carry `Tailscale-User-Login`. That login must be in `allowed_users`, and if the list is empty all tailnet requests are refused. The default list is the Mac's own Tailscale login.
- `deny_methods` blocks server and plugin administration (`server.stop`, `plugin.link`, and others).
- This still grants full terminal control of the Mac. Treat the token like an SSH key.

## WebSocket protocol

Each client message is one JSON text frame: `{"id": string|number, "method": string, "params"?: object}`.

**herdr methods** (any method in `herdr api schema`, except the denied ones) are forwarded verbatim. The reply echoes your `id`:
```json
{"id": 1, "result": {"type": "session_snapshot", ...}}
{"id": 2, "error": {"code": "herdr_unavailable", "message": "..."}}
```

**Subscriptions.** `events.subscribe` with herdr's params:
```json
→ {"id":"s1","method":"events.subscribe","params":{"subscriptions":[{"type":"pane.focused"},{"type":"pane.agent_status_changed","pane_id":"w1:p1"}]}}
← {"id":"s1","result":{"type":"subscription_started","subscription":"s1"}}
← {"subscription":"s1","event":{ ...herdr event line... }}
← {"subscription":"s1","closed":true}            // herdr ended the stream; resubscribe
```
Cancel with `{"method":"gw.unsubscribe","params":{"subscription":"s1"}}`.

**Live pane output.** herdr has no output stream, so the gateway polls `pane.read` and pushes a frame only when the text changes. It polls every `interval_ms` (default 100) and backs off to `idle_interval_ms` (default 750) while the pane is quiet. Input sent through the gateway (`pane.send_*`, `agent.send_*`, `agent.prompt`) triggers an immediate poll.
```json
→ {"id":"w","method":"gw.watch_pane","params":{"pane_id":"w1:p1","source":"visible","format":"ansi"}}
← {"id":"w","result":{"type":"watch_started","watch":"wt1"}}
← {"watch":"wt1","frame":{"seq":1,"pane_id":"w1:p1","text":"<ansi>","format":"ansi","source":"visible",...}}
← {"watch":"wt1","closed":true,"error":{...}}    // e.g. pane closed
```
Stop with `{"method":"gw.unwatch_pane","params":{"watch":"wt1"}}`. Limits: 8 watches, 16 subscriptions and 64 in-flight requests per connection.

**Other.** `gw.info` returns the gateway version, the authenticated user and herdr's `ping` result, including `protocol`. `GET /healthz` is unauthenticated and returns `{ok, herdr, pid, gateway_version}`.

## Push notifications

The gateway notifies the app when an agent turns **blocked** (needs input) or
**done**, after the status has held for `push.delay_ms` (default 3 s). It sends
straight from this Mac to Apple (APNs over HTTP/2 with a token-based .p8 key);
no other server is involved. Devices whose app is connected right now are
skipped: the app only holds a connection while it's on screen.

Setup: create a key at developer.apple.com → Certificates, IDs & Profiles →
Keys (enable *Apple Push Notifications service*), then

    sh bin/gateway-ctl push-key ~/Downloads/AuthKey_ABC123.p8 ABC123
    sh bin/gateway-ctl restart

Settings live in the `[push]` table of `config.toml`; registered devices in
`<state>/devices.json`. Tokens Apple reports as gone are dropped.

Gateway methods: `gw.push_register {token, environment, name}` (the app calls
it on every connect; it also marks that connection as "app on screen"),
`gw.push_unregister {token}`, `gw.push_status {token?}`, `gw.push_test {token}`.

Notification payloads carry `pane_id`, `workspace_id` and `status`; categories
are `AGENT_BLOCKED` (buttons send keys 1/2/3, or a text reply) and `AGENT_DONE`
(text reply via `agent.prompt`).

## Keeping the Mac awake

While any agent is working or blocked, the gateway holds `caffeinate -is`
(no idle sleep; no system sleep on AC power), tied to its own pid. It lets
go two minutes after everything is quiet. Turn off with `keep_awake = false`.

## Development
```sh
bun test                         # fake herdr socket; no live session needed
bunx -p typescript tsc -p .      # typecheck
sh bin/gateway-ctl run           # foreground daemon
```
