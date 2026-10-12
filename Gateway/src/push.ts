// Push for the iOS app, sent from this Mac straight to Apple (APNs over
// HTTP/2, token auth with a .p8 key). No other server involved. Three kinds:
//
//   * Alerts: when a pane's agent turns blocked or finishes (and is still so
//     after a short delay, so brief states don't buzz), to every device whose
//     app isn't on screen. A connected device already sees it.
//   * Widget refreshes (iOS 26 widget push): when the agent board changes,
//     tell the Agents widget to reload; it fetches the snapshot itself.
//   * One summary Live Activity per device ("2 working · 1 needs you"):
//     started with a push-to-start token when agents get busy, updated as the
//     board changes, ended once everything has been quiet for a while.
//
// Devices register on every connect (gw.push_register) with their tokens;
// they persist in <state>/devices.json.

import { readFileSync, writeFileSync, existsSync, renameSync } from "node:fs";
import { join } from "node:path";
import http2 from "node:http2";
import { sign } from "node:crypto";
import type { PushConfig } from "./config";
import type { HerdrSocket } from "./herdr";

export type ApnsEnvironment = "development" | "production";

export interface Device {
  /** The app's alert token; identifies the device. */
  token: string;
  environment: ApnsEnvironment;
  name?: string;
  added_at: number;
  last_seen_at: number;
  /** WidgetKit push token (iOS 26+). */
  widget_token?: string;
  /** ActivityKit push-to-start token for the summary Live Activity. */
  activity_start_token?: string;
  /** Update token of the running summary Live Activity, if any. */
  activity_token?: string;
  /** The user's Live Activity switch in the app. */
  live_activity?: boolean;
  /** When we push-started an activity whose update token hasn't arrived yet. */
  activity_pending?: number;
}

export interface PushMessage {
  title: string;
  body: string;
  category?: string;
  threadId?: string;
  collapseId?: string;
  data?: Record<string, unknown>;
}

export type PushType = "alert" | "widgets" | "liveactivity";

/** One APNs request, independent of transport. */
export interface ApnsRequest {
  token: string;
  environment: ApnsEnvironment;
  pushType: PushType;
  /** The app's bundle id; widget and Live Activity pushes add their suffix. */
  topic: string;
  priority: 5 | 10;
  payload: Record<string, unknown>;
  collapseId?: string;
}

export interface SendResult {
  status: number;
  reason?: string;
}

/** Anything that can deliver one push; the APNs client, or a fake in tests. */
export interface PushSender {
  send(req: ApnsRequest): Promise<SendResult>;
}

// MARK: Device store

export class DeviceStore {
  private devices = new Map<string, Device>();
  readonly file: string;

  constructor(stateDir: string) {
    this.file = join(stateDir, "devices.json");
    try {
      if (existsSync(this.file)) {
        for (const d of JSON.parse(readFileSync(this.file, "utf8")) as Device[]) this.devices.set(d.token, d);
      }
    } catch {}
  }

  list(): Device[] {
    return [...this.devices.values()];
  }

  get(token: string): Device | undefined {
    return this.devices.get(token);
  }

  has(token: string): boolean {
    return this.devices.has(token);
  }

  upsert(token: string, environment: ApnsEnvironment, extra: Partial<Device> = {}): Device {
    const now = Date.now();
    const prev = this.devices.get(token);
    const d: Device = { ...(prev ?? { added_at: now }), ...extra, token, environment, last_seen_at: now } as Device;
    this.devices.set(token, d);
    this.save();
    return d;
  }

  update(token: string, change: Partial<Device>) {
    const d = this.devices.get(token);
    if (!d) return;
    Object.assign(d, change);
    this.save();
  }

  remove(token: string): boolean {
    const ok = this.devices.delete(token);
    if (ok) this.save();
    return ok;
  }

  private save() {
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.list(), null, 2), { mode: 0o600 });
    renameSync(tmp, this.file);
  }
}

// MARK: APNs

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

/** ES256 provider token; Apple accepts one for up to an hour and rejects refreshing more than every 20 minutes. */
export function apnsJwt(keyPem: string, keyId: string, teamId: string, now = Date.now()): string {
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = b64url(JSON.stringify({ iss: teamId, iat: Math.floor(now / 1000) }));
  const input = `${header}.${claims}`;
  const sig = sign("sha256", Buffer.from(input), { key: keyPem, dsaEncoding: "ieee-p1363" });
  return `${input}.${b64url(sig)}`;
}

export function apnsPayload(msg: PushMessage): Record<string, unknown> {
  return {
    aps: {
      alert: { title: msg.title, body: msg.body },
      sound: "default",
      ...(msg.category ? { category: msg.category } : {}),
      ...(msg.threadId ? { "thread-id": msg.threadId } : {}),
    },
    ...msg.data,
  };
}

export function topicFor(pushType: PushType, bundleId: string): string {
  if (pushType === "widgets") return `${bundleId}.push-type.widgets`;
  if (pushType === "liveactivity") return `${bundleId}.push-type.liveactivity`;
  return bundleId;
}

export class ApnsClient implements PushSender {
  private sessions = new Map<string, http2.ClientHttp2Session>();
  private jwt?: { token: string; at: number };

  constructor(
    private keyPem: string,
    private keyId: string,
    private teamId: string,
  ) {}

  static host(env: ApnsEnvironment) {
    return env === "production" ? "https://api.push.apple.com" : "https://api.sandbox.push.apple.com";
  }

  private token(): string {
    if (!this.jwt || Date.now() - this.jwt.at > 40 * 60 * 1000) {
      this.jwt = { token: apnsJwt(this.keyPem, this.keyId, this.teamId), at: Date.now() };
    }
    return this.jwt.token;
  }

  private session(env: ApnsEnvironment): http2.ClientHttp2Session {
    const host = ApnsClient.host(env);
    let s = this.sessions.get(host);
    if (!s || s.closed || s.destroyed) {
      s = http2.connect(host);
      s.on("error", () => this.sessions.delete(host));
      s.on("close", () => this.sessions.delete(host));
      // Don't keep the daemon's event loop busy just for an idle push connection.
      s.unref();
      this.sessions.set(host, s);
    }
    return s;
  }

  send(r: ApnsRequest): Promise<SendResult> {
    return new Promise((resolve, reject) => {
      const body = JSON.stringify(r.payload);
      let req: http2.ClientHttp2Stream;
      try {
        req = this.session(r.environment).request({
          ":method": "POST",
          ":path": `/3/device/${r.token}`,
          authorization: `bearer ${this.token()}`,
          "apns-topic": topicFor(r.pushType, r.topic),
          "apns-push-type": r.pushType,
          "apns-priority": String(r.priority),
          ...(r.collapseId ? { "apns-collapse-id": r.collapseId.slice(0, 64) } : {}),
          "content-type": "application/json",
        });
      } catch (e) {
        reject(e);
        return;
      }
      let status = 0;
      let data = "";
      req.setTimeout(10_000, () => req.close(http2.constants.NGHTTP2_CANCEL));
      req.on("response", (h) => (status = Number(h[":status"])));
      req.setEncoding("utf8");
      req.on("data", (c) => (data += c));
      req.on("end", () => {
        let reason: string | undefined;
        try {
          reason = data ? JSON.parse(data).reason : undefined;
        } catch {}
        resolve({ status, reason });
      });
      req.on("error", reject);
      req.end(body);
    });
  }

  close() {
    for (const s of this.sessions.values()) s.close();
    this.sessions.clear();
  }
}

/** Builds the APNs client from config, or explains what's missing. */
export function apnsFromConfig(push: PushConfig): { client?: ApnsClient; problem?: string } {
  if (!push.key_id) return { problem: "push.key_id is not set (run: sh bin/gateway-ctl push-key <AuthKey.p8> <KEY_ID>)" };
  if (!push.team_id) return { problem: "push.team_id is not set" };
  if (!existsSync(push.key_file)) return { problem: `APNs key not found at ${push.key_file}` };
  try {
    const pem = readFileSync(push.key_file, "utf8");
    apnsJwt(pem, push.key_id, push.team_id); // fail now on a bad key, not at the first push
    return { client: new ApnsClient(pem, push.key_id, push.team_id) };
  } catch (e: any) {
    return { problem: `APNs key at ${push.key_file} is unusable: ${e.message}` };
  }
}

/** Apple says the token is dead (app deleted, wrong environment, activity ended). */
function tokenGone(r: SendResult) {
  return r.status === 410 || r.reason === "BadDeviceToken" || r.reason === "Unregistered" || r.reason === "ExpiredToken";
}

// MARK: Board (what the widget and Live Activity show)

export interface BoardAgent {
  paneId: string;
  /** "claude · html-gen" */
  title: string;
  headline: string;
  status: string;
}

/** The Live Activity's ContentState; field names match the Swift struct. */
export interface Board {
  working: number;
  blocked: number;
  done: number;
  agents: BoardAgent[];
}

const PRIORITY: Record<string, number> = { blocked: 0, done: 1, working: 2, idle: 3, unknown: 4 };
const MAX_ACTIVITY_AGENTS = 4;

export function boardFrom(snap: any): Board {
  const labels = new Map<string, string>((snap.workspaces ?? []).map((w: any) => [w.workspace_id, w.label]));
  const agents: BoardAgent[] = [];
  let working = 0;
  let blocked = 0;
  let done = 0;
  for (const p of snap.panes ?? []) {
    if (!p.agent) continue;
    const status = p.agent_status ?? "unknown";
    if (status === "working") working++;
    else if (status === "blocked") blocked++;
    else if (status === "done") done++;
    const kind = p.display_agent || p.agent;
    const ws = labels.get(p.workspace_id);
    const headline = (p.label || p.terminal_title_stripped || "").trim();
    agents.push({ paneId: p.pane_id, title: ws ? `${kind} · ${ws}` : kind, headline, status });
  }
  agents.sort((a, b) => (PRIORITY[a.status] ?? 9) - (PRIORITY[b.status] ?? 9) || a.title.localeCompare(b.title));
  return { working, blocked, done, agents: agents.slice(0, MAX_ACTIVITY_AGENTS) };
}

export const boardIsBusy = (b: Board) => b.working + b.blocked > 0;

export function boardSummary(b: Board): string {
  const parts: string[] = [];
  if (b.blocked) parts.push(`${b.blocked} need${b.blocked === 1 ? "s" : ""} you`);
  if (b.working) parts.push(`${b.working} working`);
  if (!parts.length) parts.push(b.done ? `${b.done} finished` : "All quiet");
  return parts.join(" · ");
}

// MARK: Notifier

interface PaneState {
  status: string;
  timer?: Timer;
}

/** herdr's ready states: `done` is unseen, `idle` is seen (e.g. the pane is focused on the Mac). */
const FINISHED = new Set(["done", "idle"]);

/**
 * What a status change means for notifications: "blocked" when an agent starts
 * waiting on you, "done" when it finishes a turn. Finishing in the pane that's
 * focused on the Mac goes straight to idle, so working → idle counts too, while
 * done → idle (you looked at it) is not news.
 */
export function notificationEvent(prev: string, next: string): "blocked" | "done" | null {
  if (next === "blocked" && prev !== "blocked") return "blocked";
  if (FINISHED.has(next) && prev === "working") return "done";
  return null;
}

export interface NotifierTiming {
  /** Coalesce board changes this long before pushing to widgets/activities. */
  boardDebounceMs: number;
  /** At most one widget refresh per device per this interval. */
  widgetMinIntervalMs: number;
  /** End the Live Activity after the board has been quiet this long. */
  activityQuietMs: number;
  /** Don't retry push-to-start more often than this. */
  activityStartRetryMs: number;
  /** How long an ended Live Activity stays on the lock screen. */
  activityDismissMs: number;
}

export const DEFAULT_TIMING: NotifierTiming = {
  boardDebounceMs: 1500,
  widgetMinIntervalMs: 20_000,
  activityQuietMs: 2 * 60_000,
  activityStartRetryMs: 60_000,
  activityDismissMs: 5 * 60_000,
};

export interface NotifierOptions {
  herdr: HerdrSocket;
  devices: DeviceStore;
  sender?: PushSender;
  config: PushConfig;
  /** Device tokens whose app is connected (on screen) right now. */
  activeTokens: () => Set<string>;
  log?: (msg: string) => void;
  pollMs?: number;
  timing?: Partial<NotifierTiming>;
  /** Called on every poll with whether any agent is working or blocked. */
  onBusy?: (busy: boolean) => void;
}

export function describe(status: string, pane: any, workspaceLabel: string | undefined): PushMessage {
  const agent = pane.display_agent || pane.agent || "Agent";
  const title = workspaceLabel ? `${agent} · ${workspaceLabel}` : agent;
  const what = status === "blocked" ? "Needs your input" : "Finished";
  const headline = (pane.label || pane.terminal_title_stripped || "").trim();
  const showHeadline = headline && headline !== workspaceLabel && headline !== agent;
  return {
    title,
    body: showHeadline ? `${what}: ${headline}` : what,
    category: status === "blocked" ? "AGENT_BLOCKED" : "AGENT_DONE",
    threadId: pane.workspace_id,
    collapseId: `${pane.pane_id}`,
    data: { pane_id: pane.pane_id, workspace_id: pane.workspace_id, status },
  };
}

export class Notifier {
  private panes = new Map<string, PaneState>();
  private primed = false;
  private timer?: Timer;
  private stopped = false;
  private log: (msg: string) => void;
  private t: NotifierTiming;

  private board?: Board;
  private boardKey = "";
  private boardTimer?: Timer;
  private quietSince?: number;
  private lastWidgetPush = new Map<string, number>();
  private widgetTimers = new Map<string, Timer>();
  private lastStartAttempt = new Map<string, number>();
  private lastActivityBlocked = new Map<string, number>();

  constructor(private o: NotifierOptions) {
    this.log = o.log ?? (() => {});
    this.t = { ...DEFAULT_TIMING, ...o.timing };
  }

  start() {
    this.stopped = false;
    this.loop();
  }

  stop() {
    this.stopped = true;
    if (this.timer) clearTimeout(this.timer);
    if (this.boardTimer) clearTimeout(this.boardTimer);
    for (const p of this.panes.values()) if (p.timer) clearTimeout(p.timer);
    for (const t of this.widgetTimers.values()) clearTimeout(t);
  }

  private async loop() {
    if (this.stopped) return;
    await this.poll();
    if (!this.stopped) this.timer = setTimeout(() => this.loop(), this.o.pollMs ?? 1500);
  }

  /** One snapshot diff. Public for tests. */
  async poll() {
    let snap: any;
    try {
      const res = await this.o.herdr.call("session.snapshot", {}, 5000);
      snap = res.result?.snapshot;
    } catch {
      return;
    }
    if (!snap) return;
    this.diffPanes(snap);
    this.diffBoard(snap);
    this.primed = true;
  }

  private diffPanes(snap: any) {
    const labels = new Map<string, string>((snap.workspaces ?? []).map((w: any) => [w.workspace_id, w.label]));
    const seen = new Set<string>();
    for (const pane of snap.panes ?? []) {
      seen.add(pane.pane_id);
      const status = pane.agent ? pane.agent_status ?? "unknown" : "none";
      const prev = this.panes.get(pane.pane_id);
      if (prev && prev.status === status) continue;
      const state: PaneState = { status };
      this.panes.set(pane.pane_id, state);
      // done ↔ idle is only herdr's seen flag; a pending "finished" keeps going.
      if (prev?.timer && FINISHED.has(prev.status) && FINISHED.has(status)) {
        state.timer = prev.timer;
        continue;
      }
      if (prev?.timer) clearTimeout(prev.timer);
      // The first snapshot only records where things stand; it's not news.
      const event = this.primed && prev ? notificationEvent(prev.status, status) : null;
      if (!event || !this.o.config.notify.includes(event)) continue;
      this.log(`push: ${pane.pane_id} ${prev!.status} → ${status}; notifying "${event}" in ${this.o.config.delay_ms}ms`);
      state.timer = setTimeout(() => {
        const now = this.panes.get(pane.pane_id);
        if (!now || now.timer !== state.timer) return; // changed again meanwhile
        now.timer = undefined;
        this.deliver(describe(event, pane, labels.get(pane.workspace_id)));
      }, this.o.config.delay_ms);
    }
    for (const [id, p] of this.panes) {
      if (seen.has(id)) continue;
      if (p.timer) clearTimeout(p.timer);
      this.panes.delete(id);
    }
  }

  private diffBoard(snap: any) {
    const board = boardFrom(snap);
    const key = JSON.stringify(board);
    const changed = key !== this.boardKey;
    this.board = board;
    this.boardKey = key;
    this.o.onBusy?.(boardIsBusy(board));
    if (boardIsBusy(board)) this.quietSince = undefined;
    else this.quietSince ??= Date.now();
    if (changed && this.primed) {
      if (this.boardTimer) clearTimeout(this.boardTimer);
      this.boardTimer = setTimeout(() => this.pushBoard(), this.t.boardDebounceMs);
    } else if (this.quietSince && Date.now() - this.quietSince >= this.t.activityQuietMs) {
      // Nothing changing, but quiet long enough to end any Live Activity.
      this.endQuietActivities();
    }
  }

  /** Sends the current board to widgets and Live Activities. Public for tests. */
  async pushBoard() {
    const board = this.board;
    if (!board || !this.o.sender) return;
    const active = this.o.activeTokens();
    for (const d of this.o.devices.list()) {
      if (d.widget_token && !active.has(d.token)) this.refreshWidget(d);
      await this.updateActivity(d, board);
    }
  }

  /** Throttled per device; a change inside the window gets one trailing refresh. */
  private refreshWidget(d: Device) {
    const last = this.lastWidgetPush.get(d.token) ?? 0;
    const wait = last + this.t.widgetMinIntervalMs - Date.now();
    if (wait > 0) {
      if (!this.widgetTimers.has(d.token)) {
        this.widgetTimers.set(
          d.token,
          setTimeout(() => {
            this.widgetTimers.delete(d.token);
            const now = this.o.devices.get(d.token);
            if (now?.widget_token) this.refreshWidget(now);
          }, wait),
        );
      }
      return;
    }
    this.lastWidgetPush.set(d.token, Date.now());
    this.sendTo(d, "widget_token", {
      token: d.widget_token!,
      environment: d.environment,
      pushType: "widgets",
      topic: this.o.config.topic,
      priority: 5,
      payload: { aps: { "content-changed": true } },
    });
  }

  private async updateActivity(d: Device, board: Board) {
    const busy = boardIsBusy(board);
    const now = Math.floor(Date.now() / 1000);
    if (d.activity_token) {
      if (!busy) return; // ended by endQuietActivities once it's been quiet a while
      // Someone newly needs you: high priority so it lands right away.
      const urgent = board.blocked > (this.lastActivityBlocked.get(d.token) ?? 0);
      this.lastActivityBlocked.set(d.token, board.blocked);
      await this.sendTo(d, "activity_token", {
        token: d.activity_token,
        environment: d.environment,
        pushType: "liveactivity",
        topic: this.o.config.topic,
        priority: urgent ? 10 : 5,
        payload: {
          aps: {
            timestamp: now,
            event: "update",
            "content-state": board,
            "stale-date": now + 30 * 60,
            ...(urgent ? { alert: { title: "herdr", body: boardSummary(board) } } : {}),
          },
        },
      });
      return;
    }
    if (!busy || !d.activity_start_token || d.live_activity === false) return;
    // One started already; it reports its update token when iOS wakes the app.
    if (d.activity_pending) return;
    const lastTry = this.lastStartAttempt.get(d.token) ?? 0;
    if (Date.now() - lastTry < this.t.activityStartRetryMs) return;
    this.lastStartAttempt.set(d.token, Date.now());
    this.lastActivityBlocked.set(d.token, board.blocked);
    this.log(`push: starting Live Activity on ${d.name ?? "device"} (${boardSummary(board)})`);
    this.o.devices.update(d.token, { activity_pending: Date.now() });
    await this.sendTo(d, "activity_start_token", {
      token: d.activity_start_token,
      environment: d.environment,
      pushType: "liveactivity",
      topic: this.o.config.topic,
      priority: 10,
      payload: {
        aps: {
          timestamp: now,
          event: "start",
          "content-state": board,
          "attributes-type": "HerdrActivityAttributes",
          attributes: { name: "herdr" },
          alert: { title: "herdr", body: boardSummary(board) },
          "stale-date": now + 30 * 60,
        },
      },
    });
  }

  private async endQuietActivities() {
    const board = this.board;
    if (!board || !this.o.sender) return;
    const now = Math.floor(Date.now() / 1000);
    for (const d of this.o.devices.list()) {
      // Without its token we can't end it; the app ends a quiet one when opened.
      if (d.activity_pending) this.o.devices.update(d.token, { activity_pending: undefined });
      if (!d.activity_token) continue;
      const token = d.activity_token;
      this.o.devices.update(d.token, { activity_token: undefined });
      this.log(`push: ending Live Activity on ${d.name ?? "device"}`);
      await this.sendTo({ ...d, activity_token: token }, "activity_token", {
        token,
        environment: d.environment,
        pushType: "liveactivity",
        topic: this.o.config.topic,
        priority: 5,
        payload: {
          aps: {
            timestamp: now,
            event: "end",
            "content-state": board,
            "dismissal-date": now + Math.round(this.t.activityDismissMs / 1000),
          },
        },
      });
    }
  }

  /** The app registered a running Live Activity: bring it up to date right away. */
  async activityRegistered(deviceToken: string) {
    const d = this.o.devices.get(deviceToken);
    if (d && this.board) await this.updateActivity(d, this.board);
  }

  /** Sends one push; forgets the device's token of that kind if Apple says it's dead. */
  private async sendTo(d: Device, field: "widget_token" | "activity_token" | "activity_start_token", req: ApnsRequest) {
    try {
      const r = await this.o.sender!.send(req);
      if (r.status === 200) return true;
      this.log(`push ${req.pushType} to ${d.name ?? "device"} failed: ${r.status} ${r.reason ?? ""}`);
      if (tokenGone(r) && this.o.devices.get(d.token)?.[field] === req.token) {
        this.o.devices.update(d.token, { [field]: undefined });
      }
    } catch (e: any) {
      this.log(`push ${req.pushType} to ${d.name ?? "device"} failed: ${e.message}`);
    }
    return false;
  }

  /** Sends an alert to every registered device that isn't looking at the app. */
  async deliver(msg: PushMessage, only?: string): Promise<{ sent: number; skipped: number; failed: number }> {
    const result = { sent: 0, skipped: 0, failed: 0 };
    if (!this.o.sender) return result;
    const active = this.o.activeTokens();
    for (const d of this.o.devices.list()) {
      if (only ? d.token !== only : active.has(d.token)) {
        result.skipped++;
        continue;
      }
      try {
        const r = await this.o.sender.send({
          token: d.token,
          environment: d.environment,
          pushType: "alert",
          topic: this.o.config.topic,
          priority: 10,
          payload: apnsPayload(msg),
          collapseId: msg.collapseId,
        });
        if (r.status === 200) {
          result.sent++;
        } else {
          result.failed++;
          this.log(`push to ${d.name ?? d.token.slice(0, 8)} failed: ${r.status} ${r.reason ?? ""}`);
          // The app was deleted or the token belongs to the other APNs environment.
          if (tokenGone(r)) this.o.devices.remove(d.token);
        }
      } catch (e: any) {
        result.failed++;
        this.log(`push to ${d.name ?? d.token.slice(0, 8)} failed: ${e.message}`);
      }
    }
    if (result.sent) this.log(`push "${msg.title}: ${msg.body}" sent to ${result.sent} device(s)`);
    return result;
  }
}
