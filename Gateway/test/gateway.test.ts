import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import { appendFileSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeProjectDir } from "../src/transcript";
import { DEFAULT_DENY_METHODS, type GatewayConfig } from "../src/config";
import { createGateway, installedAgentKinds } from "../src/gateway";
import { KeepAwake } from "../src/awake";
import { Uploads } from "../src/uploads";
import { HerdrSocket } from "../src/herdr";
import { DeviceStore, Notifier, apnsJwt, apnsPayload, boardFrom, describe as describePush, type ApnsRequest } from "../src/push";
import { generateKeyPairSync, verify } from "node:crypto";

// Fake herdr: one request per connection, like the real server.
let paneText = "hello";
// What session.snapshot reports for the agent pane; tests flip it.
let agentStatus = "working";
const calls: string[] = [];
const keyLog: string[] = [];
let keyArrivals = 0;
const dir = mkdtempSync(join(tmpdir(), "herdr-gw-"));
const sockPath = join(dir, "herdr.sock");

const fakeHerdr = Bun.listen<{ buf: string }>({
  unix: sockPath,
  socket: {
    open(s) {
      s.data = { buf: "" };
    },
    data(s, d) {
      s.data.buf += d.toString();
      const i = s.data.buf.indexOf("\n");
      if (i < 0) return;
      const req = JSON.parse(s.data.buf.slice(0, i));
      calls.push(req.method);
      const reply = (o: unknown) => s.write(JSON.stringify(o) + "\n");
      switch (req.method) {
        case "ping":
          reply({ id: req.id, result: { type: "pong", version: "test", protocol: 22 } });
          s.end();
          return;
        case "pane.send_keys":
          // First key is slowest: without per-pane ordering, later keys would win the race.
          setTimeout(() => {
            keyLog.push(req.params.keys.join("+"));
            reply({ id: req.id, result: { type: "ok" } });
            s.end();
          }, Math.max(0, 45 - keyArrivals++ * 20));
          return;
        case "pane.read":
          reply({ id: req.id, result: { type: "pane_read", read: { pane_id: req.params.pane_id, text: paneText, revision: 0, format: req.params.format, source: req.params.source } } });
          s.end();
          return;
        case "pane.get":
          reply({ id: req.id, result: { type: "pane", pane: { pane_id: req.params.pane_id, agent: "claude", cwd: "/w/proj", terminal_title_stripped: "Charts" } } });
          s.end();
          return;
        case "session.snapshot":
          reply({
            id: req.id,
            result: {
              type: "session_snapshot",
              snapshot: {
                workspaces: [{ workspace_id: "w1", label: "html-gen" }],
                panes: [
                  { pane_id: "w1:p1", workspace_id: "w1", agent: "claude", agent_status: agentStatus, terminal_title_stripped: "Fix the charts" },
                  { pane_id: "w1:p2", workspace_id: "w1", agent_status: "unknown" },
                ],
              },
            },
          });
          s.end();
          return;
        case "events.subscribe":
          reply({ id: req.id, result: { type: "subscription_started" } });
          setTimeout(() => reply({ data: { type: "pane.agent_status_changed", pane_id: "w1:p1", agent_status: "blocked" } }), 20);
          setTimeout(() => s.end(), 60);
          return;
        default:
          reply({ id: req.id, error: { code: "unknown_method", message: req.method } });
          s.end();
          return;
      }
    },
  },
});

const config: GatewayConfig = {
  port: 0,
  serve_port: 8443,
  token: "test-token-0123456789",
  allowed_users: ["me@example.com"],
  public_url: "",
  deny_methods: DEFAULT_DENY_METHODS,
  keep_awake: false,
  push: { key_file: "", key_id: "", team_id: "TEAM", topic: "dev.test", notify: ["blocked", "done"], delay_ms: 40 },
};
const herdr = new HerdrSocket(sockPath);
const sent: ApnsRequest[] = [];
const devices = new DeviceStore(dir);
const notifier = new Notifier({
  herdr,
  devices,
  config: config.push,
  sender: { send: async (req) => (sent.push(req), { status: 200 }) },
  timing: { boardDebounceMs: 10, widgetMinIntervalMs: 0, activityQuietMs: 0, activityStartRetryMs: 0 },
  activeTokens: () => gw.activeTokens(),
});
const uploads = new Uploads(join(dir, "uploads"));
// Fake herdr CLI for pane fitting: logs its args, the commands on stdin, then EOF.
const fitLog = join(dir, "fit.log");
const herdrBin = join(dir, "herdr");
writeFileSync(herdrBin, `#!/bin/sh\necho "$*" >> "${fitLog}"\ncat >> "${fitLog}"\necho EOF >> "${fitLog}"\n`);
chmodSync(herdrBin, 0o755);
const gw = createGateway({ config, herdr, uploads, herdrBin, claudeHome: dir, push: { devices, notifier } });
const server = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: gw.fetch, websocket: gw.websocket });
const wsUrl = `ws://127.0.0.1:${server.port}/ws`;

afterAll(() => {
  server.stop(true);
  fakeHerdr.stop(true);
  rmSync(dir, { recursive: true, force: true });
});

class Client {
  ws: WebSocket;
  inbox: any[] = [];
  waiters: Array<() => void> = [];
  constructor(headers: Record<string, string> = { authorization: `Bearer ${config.token}` }) {
    this.ws = new WebSocket(wsUrl, { headers } as any);
    this.ws.onmessage = (e) => {
      this.inbox.push(JSON.parse(String(e.data)));
      this.waiters.splice(0).forEach((w) => w());
    };
  }
  open() {
    return new Promise<void>((res, rej) => {
      this.ws.onopen = () => res();
      this.ws.onerror = () => rej(new Error("ws error"));
    });
  }
  send(o: unknown) {
    this.ws.send(JSON.stringify(o));
  }
  async next(pred: (m: any) => boolean, timeoutMs = 2000): Promise<any> {
    const deadline = Date.now() + timeoutMs;
    while (true) {
      const idx = this.inbox.findIndex(pred);
      if (idx >= 0) return this.inbox.splice(idx, 1)[0];
      const left = deadline - Date.now();
      if (left <= 0) throw new Error(`timed out; inbox: ${JSON.stringify(this.inbox)}`);
      await Promise.race([new Promise<void>((r) => this.waiters.push(r)), Bun.sleep(left)]);
    }
  }
  close() {
    this.ws.close();
  }
}

describe("auth", () => {
  test("rejects missing token", async () => {
    const r = await fetch(`http://127.0.0.1:${server.port}/ws`, { headers: { upgrade: "websocket" } });
    expect(r.status).toBe(401);
  });
  test("rejects tailnet user not on the allowlist even with a valid token", async () => {
    const r = await fetch(`http://127.0.0.1:${server.port}/ws`, {
      headers: { authorization: `Bearer ${config.token}`, "tailscale-user-login": "someone@else.com" },
    });
    expect(r.status).toBe(403);
  });
  test("refuses tailnet users when the allowlist is empty", async () => {
    const open = createGateway({ config: { ...config, allowed_users: [] }, herdr: new HerdrSocket(sockPath) });
    const srv = Bun.serve({ hostname: "127.0.0.1", port: 0, fetch: open.fetch, websocket: open.websocket });
    const r = await fetch(`http://127.0.0.1:${srv.port}/ws`, {
      headers: { authorization: `Bearer ${config.token}`, "tailscale-user-login": "me@example.com" },
    });
    expect(r.status).toBe(403);
    srv.stop(true);
  });
  test("accepts allowed tailnet user with token", async () => {
    const c = new Client({ authorization: `Bearer ${config.token}`, "tailscale-user-login": "me@example.com" });
    await c.open();
    c.send({ id: 1, method: "gw.info" });
    const m = await c.next((m) => m.id === 1);
    expect(m.result.user).toBe("me@example.com");
    expect(m.result.herdr.type).toBe("pong");
    c.close();
  });
  test("healthz is open and reports herdr", async () => {
    const h = await (await fetch(`http://127.0.0.1:${server.port}/healthz`)).json();
    expect(h).toMatchObject({ ok: true, herdr: true });
  });
});

describe("forwarding", () => {
  let c: Client;
  beforeAll(async () => {
    c = new Client();
    await c.open();
  });
  afterAll(() => c.close());

  test("forwards herdr methods and keeps the client id", async () => {
    c.send({ id: "abc", method: "ping", params: {} });
    expect((await c.next((m) => m.id === "abc")).result.type).toBe("pong");
  });
  test("passes herdr errors through", async () => {
    c.send({ id: "e1", method: "nope.nope", params: {} });
    expect((await c.next((m) => m.id === "e1")).error.code).toBe("unknown_method");
  });
  test("refuses denied methods without calling herdr", async () => {
    const before = calls.length;
    c.send({ id: "d1", method: "server.stop", params: {} });
    expect((await c.next((m) => m.id === "d1")).error.code).toBe("forbidden");
    expect(calls.slice(before)).not.toContain("server.stop");
  });
  test("rejects malformed messages", async () => {
    c.send({ method: "ping" });
    expect((await c.next((m) => m.error?.code === "invalid_request")).error).toBeDefined();
  });
  test("streams subscription events and reports close", async () => {
    c.send({ id: "s1", method: "events.subscribe", params: { subscriptions: [] } });
    expect((await c.next((m) => m.id === "s1")).result).toMatchObject({ type: "subscription_started", subscription: "s1" });
    const ev = await c.next((m) => m.subscription === "s1" && m.event);
    expect(ev.event.data.agent_status).toBe("blocked");
    expect(await c.next((m) => m.subscription === "s1" && m.closed)).toBeDefined();
  });
});

describe("input ordering", () => {
  test("keys for one pane reach herdr in the order sent", async () => {
    const c = new Client();
    await c.open();
    keyLog.length = 0;
    keyArrivals = 0;
    for (const [i, k] of ["down", "down", "enter"].entries()) {
      c.send({ id: `k${i}`, method: "pane.send_keys", params: { pane_id: "w1:p1", keys: [k] } });
    }
    for (let i = 0; i < 3; i++) await c.next((m) => m.id === `k${i}`);
    expect(keyLog).toEqual(["down", "down", "enter"]);
    c.close();
  });
});

describe("pane watch", () => {
  test("pushes a frame on start and only again when text changes", async () => {
    const c = new Client();
    await c.open();
    paneText = "frame one";
    c.send({ id: "w", method: "gw.watch_pane", params: { pane_id: "w1:p1", interval_ms: 50, idle_interval_ms: 50 } });
    const { result } = await c.next((m) => m.id === "w");
    const f1 = await c.next((m) => m.watch === result.watch && m.frame);
    expect(f1.frame).toMatchObject({ seq: 1, text: "frame one", format: "ansi", source: "visible" });

    await Bun.sleep(200); // several polls with unchanged text
    expect(c.inbox.filter((m) => m.frame)).toHaveLength(0);

    paneText = "frame two";
    const f2 = await c.next((m) => m.frame);
    expect(f2.frame).toMatchObject({ seq: 2, text: "frame two" });

    c.send({ id: "u", method: "gw.unwatch_pane", params: { watch: result.watch } });
    expect((await c.next((m) => m.id === "u")).result.type).toBe("ok");
    paneText = "frame three";
    await Bun.sleep(150);
    expect(c.inbox.filter((m) => m.frame)).toHaveLength(0);
    c.close();
  });

  test("holds the pane at the client's size while watched", async () => {
    const fitLines = () => (existsSync(fitLog) ? readFileSync(fitLog, "utf8").trim().split("\n") : []);
    const c = new Client();
    await c.open();
    c.send({ id: "w", method: "gw.watch_pane", params: { pane_id: "w1:p1", cols: 44, rows: 9000 } });
    const { result } = await c.next((m) => m.id === "w");
    c.send({ id: "f", method: "gw.fit_watch", params: { watch: result.watch, cols: 60, rows: 30 } });
    expect((await c.next((m) => m.id === "f")).result).toMatchObject({ type: "ok", fitted: true });
    c.send({ id: "u", method: "gw.unwatch_pane", params: { watch: result.watch } });
    await c.next((m) => m.id === "u");
    for (let i = 0; i < 40 && fitLines().at(-1) !== "EOF"; i++) await Bun.sleep(25);
    expect(fitLines()).toEqual([
      "terminal session control w1:p1 --takeover --cols 44 --rows 300", // rows clamped
      JSON.stringify({ type: "terminal.resize", cols: 60, rows: 30 }),
      JSON.stringify({ type: "terminal.release" }),
      "EOF",
    ]);
    c.close();
  });
});

describe("claude transcript on a watch", () => {
  test("sends the session's tail, then each new block, and pages back", async () => {
    const proj = claudeProjectDir("/w/proj", dir);
    mkdirSync(proj, { recursive: true });
    const file = join(proj, "s.jsonl");
    const say = (uuid: string, text: string) =>
      JSON.stringify({ type: "assistant", uuid, message: { content: [{ type: "text", text }] } }) + "\n";
    writeFileSync(file, say("a1", "first") + say("a2", "second"));
    const c = new Client();
    await c.open();
    try {
      c.send({ id: "w", method: "gw.watch_pane", params: { pane_id: "w1:p1", interval_ms: 50, idle_interval_ms: 50, transcript_lines: 1 } });
      const { result } = await c.next((m) => m.id === "w");
      expect(result.transcript).toBe(true);
      const first = await c.next((m) => m.transcript);
      expect(first.transcript).toEqual({ reset: true, blocks: [{ id: "a2:0", lines: ["⏺ second"] }], start: false });

      appendFileSync(file, say("a3", "third"));
      const next = await c.next((m) => m.transcript, 3000);
      expect(next.transcript).toEqual({ blocks: [{ id: "a3:0", lines: ["⏺ third"] }] });

      c.send({ id: "b", method: "gw.transcript_before", params: { watch: result.watch, before: "a2:0", lines: 50 } });
      expect((await c.next((m) => m.id === "b")).result).toEqual({ type: "transcript", blocks: [{ id: "a1:0", lines: ["⏺ first"] }], start: true });
    } finally {
      c.close();
    }
  });
});

describe("push", () => {
  const phone = "a".repeat(64);
  const ipad = "b".repeat(64);

  test("provider token is a valid ES256 JWT", () => {
    const { privateKey, publicKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
    const pem = privateKey.export({ type: "pkcs8", format: "pem" }).toString();
    const jwt = apnsJwt(pem, "KEY123", "TEAM", 1_700_000_000_000);
    const [h, c, sig] = jwt.split(".");
    expect(JSON.parse(Buffer.from(h, "base64url").toString())).toEqual({ alg: "ES256", kid: "KEY123" });
    expect(JSON.parse(Buffer.from(c, "base64url").toString())).toEqual({ iss: "TEAM", iat: 1_700_000_000 });
    const ok = verify("sha256", Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: "ieee-p1363" }, Buffer.from(sig, "base64url"));
    expect(ok).toBe(true);
  });

  test("message text and payload", () => {
    const m = describePush("blocked", { pane_id: "w1:p1", workspace_id: "w1", agent: "claude", terminal_title_stripped: "Fix the charts" }, "html-gen");
    expect(m.title).toBe("claude · html-gen");
    expect(m.body).toBe("Needs your input: Fix the charts");
    expect(apnsPayload(m)).toEqual({
      aps: { alert: { title: m.title, body: m.body }, sound: "default", category: "AGENT_BLOCKED", "thread-id": "w1" },
      pane_id: "w1:p1",
      workspace_id: "w1",
      status: "blocked",
    });
  });

  test("register validates the token and persists it", async () => {
    const c = new Client();
    await c.open();
    c.send({ id: 1, method: "gw.push_register", params: { token: "nope" } });
    expect((await c.next((m) => m.id === 1)).error.code).toBe("invalid_request");
    c.send({ id: 2, method: "gw.push_register", params: { token: phone, environment: "development", name: "taco", gateway_id: "g-mac" } });
    expect((await c.next((m) => m.id === 2)).result.type).toBe("push_registered");
    expect(new DeviceStore(dir).list().map((d) => [d.name, d.gateway_id])).toEqual([["taco", "g-mac"]]);
    expect(gw.activeTokens().has(phone)).toBe(true);
    c.close();
    await Bun.sleep(50);
    expect(gw.activeTokens().has(phone)).toBe(false);
  });

  test("notifies on blocked after the delay, skipping devices with the app open", async () => {
    devices.upsert(ipad, "development", { name: "ipad" });
    sent.length = 0;
    agentStatus = "working";
    await notifier.poll(); // primes: no news yet
    // The iPad has the app on screen.
    const c = new Client();
    await c.open();
    c.send({ id: 1, method: "gw.push_register", params: { token: ipad } });
    await c.next((m) => m.id === 1);

    agentStatus = "blocked";
    await notifier.poll();
    expect(sent.filter((r) => r.pushType === "alert").length).toBe(0); // waits out delay_ms
    await Bun.sleep(80);
    const alerts = sent.filter((r) => r.pushType === "alert");
    expect(alerts.map((r) => r.token)).toEqual([phone]);
    expect((alerts[0].payload.aps as any).alert.body).toBe("Needs your input: Fix the charts");
    // Tells the app which of its gateways this came from.
    expect(alerts[0].payload.gateway_id).toBe("g-mac");
    c.close();
  });

  test("a status that doesn't hold is not sent", async () => {
    sent.length = 0;
    agentStatus = "working";
    await notifier.poll();
    agentStatus = "done";
    await notifier.poll();
    agentStatus = "working";
    await notifier.poll();
    await Bun.sleep(80);
    expect(sent.filter((r) => r.pushType === "alert").length).toBe(0);
  });

  test("finishing in the pane focused on the Mac (working → idle) notifies; looking at it (done → idle) doesn't", async () => {
    sent.length = 0;
    agentStatus = "working";
    await notifier.poll();
    agentStatus = "idle";
    await notifier.poll();
    await Bun.sleep(80);
    expect(sent.filter((r) => r.pushType === "alert").map((r) => (r.payload.aps as any).alert.body)).toEqual([
      "Finished: Fix the charts",
      "Finished: Fix the charts",
    ]);

    sent.length = 0;
    agentStatus = "done";
    await notifier.poll();
    agentStatus = "idle";
    await notifier.poll();
    await Bun.sleep(80);
    expect(sent.filter((r) => r.pushType === "alert").length).toBe(0);
  });

  test("done then seen within the delay still sends once", async () => {
    sent.length = 0;
    agentStatus = "working";
    await notifier.poll();
    agentStatus = "done";
    await notifier.poll();
    agentStatus = "idle";
    await notifier.poll();
    await Bun.sleep(80);
    expect(sent.filter((r) => r.pushType === "alert").length).toBe(2); // one per registered device (taco + ipad)
  });

  test("board: counts and agents ordered by what needs you", () => {
    const b = boardFrom({
      workspaces: [{ workspace_id: "w1", label: "html-gen" }, { workspace_id: "w2", label: "web" }],
      panes: [
        { pane_id: "a", workspace_id: "w1", agent: "claude", agent_status: "working", terminal_title_stripped: "Charts" },
        { pane_id: "b", workspace_id: "w2", agent: "codex", agent_status: "blocked" },
        { pane_id: "c", workspace_id: "w2", agent_status: "unknown" },
      ],
    });
    expect(b).toEqual({
      working: 1,
      blocked: 1,
      done: 0,
      agents: [
        { paneId: "b", title: "codex · web", headline: "", status: "blocked" },
        { paneId: "a", title: "claude · html-gen", headline: "Charts", status: "working" },
      ],
    });
  });

  test("widget refresh and Live Activity start → update → end", async () => {
    const tab = "d".repeat(64);
    const widget = "e".repeat(64);
    const start = "f".repeat(64);
    const activity = "9".repeat(64);
    for (const d of devices.list()) devices.remove(d.token);
    devices.upsert(tab, "development", { name: "tab", widget_token: widget, activity_start_token: start });
    agentStatus = "idle";
    await notifier.poll();
    await Bun.sleep(30);
    sent.length = 0;

    // Gets busy: the widget is told to reload and the Live Activity starts once.
    agentStatus = "working";
    await notifier.poll();
    await Bun.sleep(30);
    const widgetPush = sent.find((r) => r.pushType === "widgets");
    expect(widgetPush?.token).toBe(widget);
    expect(widgetPush?.payload).toEqual({ aps: { "content-changed": true } });
    const starts = sent.filter((r) => r.pushType === "liveactivity" && r.token === start);
    expect(starts.length).toBe(1);
    const aps = starts[0].payload.aps as any;
    expect(aps.event).toBe("start");
    expect(aps["attributes-type"]).toBe("HerdrActivityAttributes");
    expect(aps["content-state"].working).toBe(1);

    // A change before the app reports the activity's token doesn't start a second one.
    sent.length = 0;
    agentStatus = "blocked";
    await notifier.poll();
    await Bun.sleep(30);
    expect(sent.filter((r) => r.pushType === "liveactivity").length).toBe(0);

    // The app reports the running activity: it gets the current board right away.
    const c = new Client();
    await c.open();
    c.send({ id: 1, method: "gw.activity_register", params: { token: tab, activity_token: activity } });
    await c.next((m) => m.id === 1);
    await Bun.sleep(20);
    const update = sent.find((r) => r.pushType === "liveactivity" && r.token === activity);
    expect((update?.payload.aps as any).event).toBe("update");
    expect((update?.payload.aps as any)["content-state"].blocked).toBe(1);

    // An older activity ending doesn't drop the running one's token; this one ending does.
    c.send({ id: 2, method: "gw.activity_ended", params: { token: tab, activity_token: "8".repeat(64) } });
    await c.next((m) => m.id === 2);
    expect(devices.get(tab)?.activity_token).toBe(activity);
    c.send({ id: 3, method: "gw.activity_ended", params: { token: tab, activity_token: activity } });
    await c.next((m) => m.id === 3);
    expect(devices.get(tab)?.activity_token).toBeUndefined();
    c.send({ id: 4, method: "gw.activity_register", params: { token: tab, activity_token: activity } });
    await c.next((m) => m.id === 4);
    c.close();

    // Quiet (activityQuietMs is 0 here): the activity ends and the token is forgotten.
    sent.length = 0;
    agentStatus = "idle";
    await notifier.poll(); // board changed
    await notifier.poll(); // still quiet → end
    await Bun.sleep(30);
    const end = sent.find((r) => r.pushType === "liveactivity" && r.token === activity);
    expect((end?.payload.aps as any).event).toBe("end");
    expect(devices.get(tab)?.activity_token).toBeUndefined();
  });

  test("drops tokens Apple reports as gone", async () => {
    const gone = "c".repeat(64);
    devices.upsert(gone, "production");
    const n = new Notifier({
      herdr,
      devices,
      config: config.push,
      sender: { send: async (r) => (r.token === gone ? { status: 410, reason: "Unregistered" } : { status: 200 }) },
      activeTokens: () => new Set(),
    });
    const r = await n.deliver({ title: "t", body: "b" });
    expect(r.failed).toBe(1);
    expect(devices.has(gone)).toBe(false);
  });
});

describe("agents", () => {
  test("installed kinds keep herdr's order and skip missing executables", () => {
    const have = new Set(["codex", "claude", "zsh"]);
    expect(installedAgentKinds((c) => (have.has(c) ? `/bin/${c}` : null))).toEqual(["claude", "codex"]);
  });

  test("gw.agent_kinds answers", async () => {
    const c = new Client();
    await c.open();
    c.send({ id: 1, method: "gw.agent_kinds" });
    const r = await c.next((m) => m.id === 1);
    expect(r.result.type).toBe("agent_kinds");
    expect(Array.isArray(r.result.kinds)).toBe(true);
    c.close();
  });
});

describe("uploads", () => {
  test("gw.upload saves the photo privately and returns its path", async () => {
    const c = new Client();
    await c.open();
    const png = Buffer.from("89504e470d0a1a0a0000000d49484452", "hex");
    c.send({ id: 1, method: "gw.upload", params: { data: png.toString("base64"), ext: "png" } });
    const r = await c.next((m) => m.id === 1);
    expect(r.result.type).toBe("uploaded");
    expect(r.result.path.startsWith(join(dir, "uploads") + "/")).toBe(true);
    expect(r.result.path.endsWith(".png")).toBe(true);
    expect(readFileSync(r.result.path).equals(png)).toBe(true);
    expect(statSync(r.result.path).mode & 0o777).toBe(0o600);

    c.send({ id: 2, method: "gw.upload", params: { data: "aGk=", ext: "exe" } });
    expect((await c.next((m) => m.id === 2)).error.code).toBe("invalid_request");
    c.close();
  });

  test("uploads older than a day are deleted on the next upload", () => {
    const u = new Uploads(join(dir, "uploads-prune"));
    const old = u.save("aGk=", "jpg");
    const day = Date.now() / 1000 - 25 * 3600;
    utimesSync(old, day, day);
    const fresh = u.save("aGk=", "jpg");
    expect(existsSync(old)).toBe(false);
    expect(existsSync(fresh)).toBe(true);
  });
});

describe("keep awake", () => {
  test("holds while busy, releases after the quiet window", () => {
    let t = 0;
    let started = 0;
    let killed = 0;
    const k = new KeepAwake({ quietMs: 100, now: () => t, start: () => (started++, { kill: () => killed++ }) });
    k.update(false);
    expect(k.holding).toBe(false);
    k.update(true);
    k.update(true);
    expect([started, k.holding]).toEqual([1, true]);
    t = 50;
    k.update(false); // quiet, but not for long enough
    expect(k.holding).toBe(true);
    t = 160;
    k.update(false);
    expect([killed, k.holding]).toEqual([1, false]);
    k.update(true);
    expect(started).toBe(2);
  });
});
