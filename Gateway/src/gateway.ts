// WebSocket <-> herdr socket bridge.
//
// Client -> gateway messages are JSON-RPC-ish: {id, method, params}.
//   * herdr methods are forwarded verbatim (one herdr connection per call) and
//     the response comes back as {id, result} / {id, error}.
//   * events.subscribe opens a long-lived herdr stream. The response carries
//     {id, result: {type: "subscription_started", subscription: id}} and each
//     event arrives as {subscription: id, event: <herdr line>}. A stream that
//     herdr closes produces {subscription: id, closed: true, reason?}.
//   * gw.* methods are handled by the gateway (see handleGatewayMethod),
//     including gw.push_* for push notification sign-up (see push.ts).
//     gw.watch_pane with cols/rows (and gw.fit_watch later) also holds the
//     pane at that size while it's watched (see fit.ts).
// Gateway-originated pushes never carry an `id`.

import type { Server, ServerWebSocket } from "bun";
import { timingSafeEqual } from "node:crypto";
import type { GatewayConfig } from "./config";
import { HerdrSocket, HerdrUnavailable, type HerdrResponse } from "./herdr";
import type { ApnsEnvironment, DeviceStore, Notifier } from "./push";
import { claudeTranscript } from "./transcript";
import { complete, looksRemote } from "./complete";
import { UploadError, type Uploads } from "./uploads";
import { fitSize, PaneFit } from "./fit";

export const GATEWAY_VERSION = "0.1.0";
const MAX_INFLIGHT = 64;
const MAX_WATCHES = 8;
const MAX_SUBSCRIPTIONS = 16;
const BACKPRESSURE_BYTES = 2 * 1024 * 1024;

interface Watch {
  pane_id: string;
  params: Record<string, unknown>;
  lastText?: string;
  seq: number;
  quietTicks: number;
  intervalMs: number;
  idleMs: number;
  timer?: Timer;
  polling: boolean;
  stopped: boolean;
  /** Holds the pane at the client's size while watched. */
  fit?: PaneFit;
}

interface ClientState {
  user: string | null;
  inflight: number;
  subscriptions: Map<string, { close(): void }>;
  watches: Map<string, Watch>;
  nextWatch: number;
  /** Set by gw.push_register: this connection is that device's app, on screen. */
  pushToken?: string;
}

type WS = ServerWebSocket<ClientState>;

export interface PushHooks {
  devices: DeviceStore;
  notifier: Notifier;
  /** Why pushes can't be sent (no APNs key yet, …); undefined when ready. */
  problem?: string;
}

export interface GatewayOptions {
  config: GatewayConfig;
  herdr: HerdrSocket;
  push?: PushHooks;
  /** Where gw.upload saves photos; without it, uploads are refused. */
  uploads?: Uploads;
  /** The herdr CLI, for holding panes at the phone's size; without it watches don't resize. */
  herdrBin?: string;
  log?: (msg: string) => void;
}

const APNS_TOKEN = /^[0-9a-f]{64,200}$/i;

/** Agent kinds herdr 0.9 can start (`herdr agent start --kind`), in a sensible menu order. */
export const AGENT_KINDS = [
  "claude", "codex", "gemini", "opencode", "cursor", "copilot", "amp", "droid", "qwen", "kimi", "kiro", "cline",
  "pi", "devin", "agy", "omp", "mastracode", "grok", "hermes", "kilo", "qodercli", "letta", "maki", "muse",
];

/** The kinds whose executable is on this Mac's PATH. */
export function installedAgentKinds(which: (cmd: string) => string | null = Bun.which): string[] {
  return AGENT_KINDS.filter((k) => which(k));
}

function tokenMatches(expected: string, given: string | null): boolean {
  if (!given) return false;
  const a = Buffer.from(expected);
  const b = Buffer.from(given);
  return a.length === b.length && timingSafeEqual(a, b);
}

function bearer(req: Request, url: URL): string | null {
  const h = req.headers.get("authorization");
  if (h?.toLowerCase().startsWith("bearer ")) return h.slice(7).trim();
  return url.searchParams.get("token");
}

function send(ws: WS, msg: unknown) {
  if (ws.readyState !== 1) return;
  ws.send(JSON.stringify(msg));
}

function errorMsg(id: unknown, code: string, message: string) {
  return { id, error: { code, message } };
}

/** Methods that write to a terminal; these must reach herdr in the order sent. */
function inputTarget(method: string, params: any): string | null {
  if (method.startsWith("pane.send_") || method === "pane.clear") return params?.pane_id ?? null;
  if (method === "agent.send_keys" || method === "agent.prompt") return params?.target ?? null;
  return null;
}

export function createGateway({ config, herdr, push, uploads, herdrBin, log = () => {} }: GatewayOptions) {
  const clients = new Set<WS>();
  const deny = new Set(config.deny_methods);
  const allowedUsers = new Set(config.allowed_users);
  // herdr handles each request on its own connection, so two quick key
  // presses could otherwise land out of order. Chain input per target pane.
  const inputQueues = new Map<string, Promise<unknown>>();

  function serialized<T>(target: string | null, run: () => Promise<T>): Promise<T> {
    if (!target) return run();
    const prev = inputQueues.get(target) ?? Promise.resolve();
    const next = prev.then(run, run);
    const tail = next.catch(() => {});
    inputQueues.set(target, tail);
    tail.then(() => {
      if (inputQueues.get(target) === tail) inputQueues.delete(target);
    });
    return next;
  }

  /** Returns a rejection Response, or the authenticated tailnet user (null when local). */
  function authorize(req: Request, url: URL): Response | { user: string | null } {
    const user = req.headers.get("tailscale-user-login");
    // Requests via tailscale serve always carry this header. With an empty
    // allowlist we fail closed: only local (header-less) clients get in.
    if (user && !allowedUsers.has(user)) {
      log(`rejected tailnet user ${user}${allowedUsers.size ? "" : " (allowed_users is empty)"}`);
      return new Response("forbidden", { status: 403 });
    }
    if (!tokenMatches(config.token, bearer(req, url))) {
      log(`rejected bad token from ${user ?? "local"}`);
      return new Response("unauthorized", { status: 401 });
    }
    return { user };
  }

  async function forward(ws: WS, id: unknown, method: string, params: unknown) {
    const st = ws.data;
    if (st.inflight >= MAX_INFLIGHT) {
      send(ws, errorMsg(id, "too_many_requests", `more than ${MAX_INFLIGHT} requests in flight`));
      return;
    }
    st.inflight++;
    try {
      const res = await serialized(inputTarget(method, params), () => herdr.call(method, params ?? {}));
      send(ws, { ...res, id });
    } catch (e: any) {
      const code = e instanceof HerdrUnavailable ? "herdr_unavailable" : "gateway_error";
      send(ws, errorMsg(id, code, e.message));
    } finally {
      st.inflight--;
    }
  }

  async function subscribe(ws: WS, id: unknown, params: unknown) {
    const st = ws.data;
    const subId = String(id);
    if (st.subscriptions.has(subId)) {
      send(ws, errorMsg(id, "invalid_request", `subscription ${subId} already exists`));
      return;
    }
    if (st.subscriptions.size >= MAX_SUBSCRIPTIONS) {
      send(ws, errorMsg(id, "too_many_subscriptions", `limit is ${MAX_SUBSCRIPTIONS}`));
      return;
    }
    let started = false;
    try {
      const handle = await herdr.subscribe(
        params,
        (msg: HerdrResponse) => {
          if (!started) {
            started = true;
            if (msg.error) {
              st.subscriptions.delete(subId);
              send(ws, { ...msg, id });
            } else {
              send(ws, { id, result: { ...msg.result, subscription: subId } });
            }
            return;
          }
          send(ws, { subscription: subId, event: msg });
        },
        (reason) => {
          if (!st.subscriptions.delete(subId)) return;
          send(ws, { subscription: subId, closed: true, reason });
        },
      );
      st.subscriptions.set(subId, handle);
      if (ws.readyState !== 1) handle.close();
    } catch (e: any) {
      send(ws, errorMsg(id, "herdr_unavailable", e.message));
    }
  }

  // Polls pane.read and pushes {watch, frame} only when the text changes.
  // herdr's pane revision does not track output, so we diff the text itself.
  // While the pane is quiet the interval backs off from intervalMs to idleMs.
  function scheduleWatch(ws: WS, w: Watch, watchId: string, delay: number) {
    if (w.stopped) return;
    if (w.timer) clearTimeout(w.timer);
    w.timer = setTimeout(() => pollWatch(ws, w, watchId), delay);
  }

  async function pollWatch(ws: WS, w: Watch, watchId: string) {
    if (w.stopped || w.polling) return;
    w.polling = true;
    let delay: number;
    try {
      if (ws.getBufferedAmount() > BACKPRESSURE_BYTES) {
        delay = w.intervalMs;
      } else {
        const res = await herdr.call("pane.read", { pane_id: w.pane_id, ...w.params }, 5000);
        if (w.stopped) return;
        if (res.error) {
          send(ws, { watch: watchId, closed: true, error: res.error });
          stopWatch(ws, watchId);
          return;
        }
        const read = res.result?.read;
        if (read && read.text !== w.lastText) {
          w.lastText = read.text;
          w.seq++;
          w.quietTicks = 0;
          send(ws, { watch: watchId, frame: { seq: w.seq, ...read } });
        } else {
          w.quietTicks++;
        }
        delay = Math.min(w.idleMs, Math.round(w.intervalMs * 1.5 ** w.quietTicks));
      }
    } catch (e: any) {
      delay = 1000;
      send(ws, { watch: watchId, error: { code: "herdr_unavailable", message: e.message } });
    } finally {
      w.polling = false;
    }
    scheduleWatch(ws, w, watchId, delay);
  }

  function stopWatch(ws: WS, watchId: string): boolean {
    const w = ws.data.watches.get(watchId);
    if (!w) return false;
    w.stopped = true;
    if (w.timer) clearTimeout(w.timer);
    w.fit?.close();
    ws.data.watches.delete(watchId);
    return true;
  }

  function setFit(w: Watch, cols: unknown, rows: unknown) {
    const size = herdrBin ? fitSize(cols, rows) : null;
    if (!size) {
      w.fit?.close();
      w.fit = undefined;
    } else if (w.fit) {
      w.fit.resize(size);
    } else {
      w.fit = new PaneFit(w.pane_id, size, { herdrBin: herdrBin!, socket: herdr.path, log });
    }
  }

  /** Poll watches on this pane right away so typed input echoes quickly. */
  function nudgeWatches(ws: WS, paneId: unknown) {
    for (const [watchId, w] of ws.data.watches) {
      if (w.pane_id !== paneId) continue;
      w.quietTicks = 0;
      scheduleWatch(ws, w, watchId, 30);
    }
  }

  async function handleGatewayMethod(ws: WS, id: unknown, method: string, params: any) {
    const st = ws.data;
    switch (method) {
      case "gw.info": {
        let herdrInfo: unknown = null;
        try {
          herdrInfo = (await herdr.call("ping", {}, 2000)).result ?? null;
        } catch {}
        send(ws, { id, result: { type: "gw_info", gateway_version: GATEWAY_VERSION, user: st.user, herdr: herdrInfo } });
        return;
      }
      case "gw.watch_pane": {
        if (typeof params?.pane_id !== "string") {
          send(ws, errorMsg(id, "invalid_request", "pane_id is required"));
          return;
        }
        if (st.watches.size >= MAX_WATCHES) {
          send(ws, errorMsg(id, "too_many_watches", `limit is ${MAX_WATCHES}`));
          return;
        }
        const watchId = `wt${st.nextWatch++}`;
        const intervalMs = Math.max(50, Number(params.interval_ms) || 100);
        const w: Watch = {
          pane_id: params.pane_id,
          params: {
            source: params.source ?? "visible",
            format: params.format ?? "ansi",
            strip_ansi: params.format === "text",
            ...(params.lines != null ? { lines: params.lines } : {}),
          },
          seq: 0,
          quietTicks: 0,
          intervalMs,
          idleMs: Math.max(intervalMs, Number(params.idle_interval_ms) || 750),
          polling: false,
          stopped: false,
        };
        setFit(w, params.cols, params.rows);
        st.watches.set(watchId, w);
        send(ws, { id, result: { type: "watch_started", watch: watchId } });
        pollWatch(ws, w, watchId);
        return;
      }
      case "gw.fit_watch": {
        // New size for a watched pane (rotation, font size); no cols/rows gives it back.
        const w = st.watches.get(String(params?.watch));
        if (!w) {
          send(ws, errorMsg(id, "not_found", "no such watch"));
          return;
        }
        setFit(w, params?.cols, params?.rows);
        w.quietTicks = 0;
        scheduleWatch(ws, w, String(params.watch), 150);
        send(ws, { id, result: { type: "ok", fitted: !!w.fit } });
        return;
      }
      case "gw.unwatch_pane": {
        const ok = stopWatch(ws, String(params?.watch));
        send(ws, ok ? { id, result: { type: "ok" } } : errorMsg(id, "not_found", "no such watch"));
        return;
      }
      case "gw.unsubscribe": {
        const sub = String(params?.subscription);
        const h = st.subscriptions.get(sub);
        if (!h) {
          send(ws, errorMsg(id, "not_found", "no such subscription"));
          return;
        }
        st.subscriptions.delete(sub);
        h.close();
        send(ws, { id, result: { type: "ok" } });
        return;
      }
      case "gw.claude_transcript": {
        // A Claude pane's earlier conversation, from Claude's own session file.
        const paneId = String(params?.pane_id ?? "");
        const lines = Math.min(20000, Math.max(1, Number(params?.lines) || 1000));
        try {
          const info = await herdr.call("pane.get", { pane_id: paneId }, 3000);
          const pane = info.result?.pane;
          if (!pane) return send(ws, errorMsg(id, "not_found", "no such pane"));
          if (pane.agent !== "claude") return send(ws, errorMsg(id, "not_claude", "this pane isn't running Claude Code"));
          const t = claudeTranscript(pane.foreground_cwd ?? pane.cwd, pane.terminal_title_stripped, lines);
          if (!t) return send(ws, errorMsg(id, "not_found", "no Claude session found for this pane's folder"));
          send(ws, { id, result: { type: "transcript", text: t.text, truncated: t.truncated } });
        } catch (e: any) {
          send(ws, errorMsg(id, "gateway_error", e.message));
        }
        return;
      }
      case "gw.upload": {
        // A photo for an agent: saved on this machine, its path returned for the prompt.
        if (!uploads) return send(ws, errorMsg(id, "unavailable", "uploads are not enabled in this gateway"));
        try {
          const path = uploads.save(String(params?.data ?? ""), String(params?.ext ?? "jpg"));
          send(ws, { id, result: { type: "uploaded", path } });
        } catch (e: any) {
          send(ws, errorMsg(id, e instanceof UploadError ? "invalid_request" : "gateway_error", e.message));
        }
        return;
      }
      case "gw.complete": {
        // Tab completion for a shell pane's command line (see complete.ts).
        const paneId = String(params?.pane_id ?? "");
        const line = String(params?.line ?? "").slice(-4096);
        try {
          const info = await herdr.call("pane.get", { pane_id: paneId }, 3000);
          const pane = info.result?.pane;
          if (!pane) return send(ws, errorMsg(id, "not_found", "no such pane"));
          if (looksRemote(pane.terminal_title_stripped ?? pane.terminal_title)) {
            return send(ws, { id, result: { type: "completions", word: "", candidates: [] } });
          }
          const c = await complete(line, pane.foreground_cwd ?? pane.cwd);
          send(ws, { id, result: { type: "completions", ...c } });
        } catch (e: any) {
          send(ws, errorMsg(id, "gateway_error", e.message));
        }
        return;
      }
      case "gw.agent_kinds": {
        send(ws, { id, result: { type: "agent_kinds", kinds: installedAgentKinds() } });
        return;
      }
      case "gw.push_register": {
        if (!push) return send(ws, errorMsg(id, "unavailable", "push is not enabled in this gateway"));
        const token = String(params?.token ?? "");
        const env: ApnsEnvironment = params?.environment === "production" ? "production" : "development";
        if (!APNS_TOKEN.test(token)) return send(ws, errorMsg(id, "invalid_request", "token must be the hex APNs device token"));
        const name = typeof params?.name === "string" ? params.name.slice(0, 64) : undefined;
        const hex = (v: unknown) => (typeof v === "string" && APNS_TOKEN.test(v) ? v : undefined);
        const isNew = !push.devices.has(token);
        push.devices.upsert(token, env, {
          name,
          widget_token: hex(params?.widget_token),
          activity_start_token: hex(params?.activity_start_token),
          live_activity: params?.live_activity !== false,
          gateway_id: typeof params?.gateway_id === "string" ? params.gateway_id.slice(0, 64) : undefined,
        });
        st.pushToken = token;
        if (isNew) log(`push: registered ${name ?? "device"} (${env})`);
        send(ws, { id, result: { type: "push_registered", ready: !push.problem, problem: push.problem ?? null } });
        return;
      }
      case "gw.activity_register": {
        // The app's summary Live Activity is running; this token updates it.
        if (!push) return send(ws, errorMsg(id, "unavailable", "push is not enabled in this gateway"));
        const token = String(params?.token ?? "");
        const activity = String(params?.activity_token ?? "");
        if (!push.devices.has(token) || !APNS_TOKEN.test(activity)) {
          return send(ws, errorMsg(id, "invalid_request", "unknown device or bad activity_token"));
        }
        push.devices.update(token, { activity_token: activity, activity_pending: undefined });
        send(ws, { id, result: { type: "ok" } });
        push.notifier.activityRegistered(token);
        return;
      }
      case "gw.activity_ended": {
        if (!push) return send(ws, errorMsg(id, "unavailable", "push is not enabled in this gateway"));
        const token = String(params?.token ?? "");
        // Only forget the activity that ended: an older one ending must not
        // drop the token of the one running now. No activity_token: forget any.
        const ended = typeof params?.activity_token === "string" ? params.activity_token : undefined;
        const current = push.devices.get(token)?.activity_token;
        if (!ended || ended === current) {
          push.devices.update(token, { activity_token: undefined, activity_pending: undefined });
        }
        send(ws, { id, result: { type: "ok" } });
        return;
      }
      case "gw.push_unregister": {
        if (!push) return send(ws, errorMsg(id, "unavailable", "push is not enabled in this gateway"));
        const token = String(params?.token ?? "");
        push.devices.remove(token);
        if (st.pushToken === token) st.pushToken = undefined;
        send(ws, { id, result: { type: "ok" } });
        return;
      }
      case "gw.push_status": {
        const token = typeof params?.token === "string" ? params.token : undefined;
        send(ws, {
          id,
          result: {
            type: "push_status",
            enabled: !!push,
            ready: !!push && !push.problem,
            problem: push ? push.problem ?? null : "push is not enabled in this gateway",
            devices: push?.devices.list().length ?? 0,
            registered: token ? !!push?.devices.has(token) : null,
          },
        });
        return;
      }
      case "gw.push_test": {
        if (!push) return send(ws, errorMsg(id, "unavailable", "push is not enabled in this gateway"));
        if (push.problem) return send(ws, errorMsg(id, "push_not_ready", push.problem));
        const token = String(params?.token ?? st.pushToken ?? "");
        if (!push.devices.has(token)) return send(ws, errorMsg(id, "not_found", "this device isn't registered"));
        const r = await push.notifier.deliver(
          { title: "herdr", body: "Notifications are working.", category: "TEST", data: {} },
          token,
        );
        if (r.sent) send(ws, { id, result: { type: "push_sent", ...r } });
        else send(ws, errorMsg(id, "push_failed", "Apple rejected the push; see the gateway log"));
        return;
      }
      default:
        send(ws, errorMsg(id, "unknown_method", `unknown gateway method ${method}`));
    }
  }

  async function onMessage(ws: WS, raw: string | Buffer) {
    let msg: any;
    try {
      msg = JSON.parse(typeof raw === "string" ? raw : raw.toString("utf8"));
    } catch {
      send(ws, errorMsg(null, "invalid_json", "message is not JSON"));
      return;
    }
    const { id, method, params } = msg ?? {};
    if ((typeof id !== "string" && typeof id !== "number") || typeof method !== "string") {
      send(ws, errorMsg(id ?? null, "invalid_request", "expected {id, method, params}"));
      return;
    }
    if (method.startsWith("gw.")) return handleGatewayMethod(ws, id, method, params);
    if (deny.has(method)) {
      send(ws, errorMsg(id, "forbidden", `${method} is not allowed through the gateway`));
      return;
    }
    if (method === "events.subscribe") return subscribe(ws, id, params);
    if (method.startsWith("pane.send") || method.startsWith("agent.send") || method === "agent.prompt") {
      nudgeWatches(ws, params?.pane_id ?? params?.target);
    }
    return forward(ws, id, method, params);
  }

  function closeAll(ws: WS) {
    for (const id of [...ws.data.watches.keys()]) stopWatch(ws, id);
    for (const h of ws.data.subscriptions.values()) h.close();
    ws.data.subscriptions.clear();
  }

  return {
    /** Push tokens of apps connected right now (on screen); they don't need notifications. */
    activeTokens(): Set<string> {
      const tokens = new Set<string>();
      for (const ws of clients) if (ws.data.pushToken) tokens.add(ws.data.pushToken);
      return tokens;
    },
    async fetch(req: Request, server: Server<ClientState>): Promise<Response | undefined> {
      const url = new URL(req.url);
      if (url.pathname === "/healthz") {
        let herdrUp = false;
        try {
          herdrUp = !(await herdr.call("ping", {}, 1000)).error;
        } catch {}
        return Response.json({ ok: true, gateway_version: GATEWAY_VERSION, herdr: herdrUp, pid: process.pid });
      }
      if (url.pathname !== "/ws") return new Response("not found", { status: 404 });
      const auth = authorize(req, url);
      if (auth instanceof Response) return auth;
      const data: ClientState = { user: auth.user, inflight: 0, subscriptions: new Map(), watches: new Map(), nextWatch: 1 };
      if (server.upgrade(req, { data })) {
        log(`client connected (${auth.user ?? "local"})`);
        return undefined;
      }
      return new Response("expected websocket upgrade", { status: 426 });
    },
    websocket: {
      idleTimeout: 120,
      // Room for a photo upload (base64) in one message.
      maxPayloadLength: 20 * 1024 * 1024,
      sendPings: true,
      open: (ws: WS) => {
        clients.add(ws);
      },
      message: (ws: WS, raw: string | Buffer) => {
        onMessage(ws, raw);
      },
      close: (ws: WS) => {
        clients.delete(ws);
        closeAll(ws);
        log(`client disconnected (${ws.data.user ?? "local"})`);
      },
    },
  };
}
