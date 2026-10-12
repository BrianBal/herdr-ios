import { mkdirSync, existsSync, readFileSync, writeFileSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

export const PLUGIN_ID = "bal.ios-gateway";

export const DEFAULT_DENY_METHODS = [
  "server.stop",
  "server.live_handoff",
  "server.ssh_agent.register",
  "server.reload_agent_manifests",
  "plugin.link",
  "plugin.unlink",
  "plugin.enable",
  "plugin.disable",
  "integration.install",
  "integration.uninstall",
];

export interface PushConfig {
  /** APNs auth key (.p8) from developer.apple.com → Keys. */
  key_file: string;
  key_id: string;
  team_id: string;
  /** The app's bundle id. */
  topic: string;
  /** Agent statuses that trigger a notification. */
  notify: string[];
  /** How long a status must hold before notifying, so brief states don't buzz. */
  delay_ms: number;
}

export interface GatewayConfig {
  /** Loopback port the daemon binds; `tailscale serve` proxies to it. */
  port: number;
  /** HTTPS port used with `tailscale serve --https=<serve_port>`. */
  serve_port: number;
  /** Bearer token required on every WebSocket upgrade. */
  token: string;
  /** Tailscale logins allowed via the Tailscale-User-Login header. Empty = tailnet requests refused. */
  allowed_users: string[];
  /** Override for the URL advertised in the pairing QR. */
  public_url: string;
  deny_methods: string[];
  push: PushConfig;
  /** Hold a caffeinate assertion while agents are working or blocked. */
  keep_awake: boolean;
}

export interface Paths {
  socket: string;
  herdrBin: string;
  configDir: string;
  stateDir: string;
  configFile: string;
  pidFile: string;
  logFile: string;
}

function herdrBin(): string {
  return process.env.HERDR_BIN_PATH || Bun.which("herdr") || "/opt/homebrew/bin/herdr";
}

/** Plugin dirs come from herdr's env when launched by herdr; otherwise ask the CLI. */
export function resolvePaths(): Paths {
  const bin = herdrBin();
  let configDir = process.env.HERDR_PLUGIN_CONFIG_DIR;
  if (!configDir) {
    const r = Bun.spawnSync([bin, "plugin", "config-dir", PLUGIN_ID], { stderr: "pipe" });
    const out = r.stdout.toString().trim();
    configDir = r.exitCode === 0 && out ? out : join(homedir(), ".config", "herdr-ios-gateway");
  }
  // Matches herdr's layout so manual `gateway-ctl` runs share the pidfile with hook runs.
  const stateDir =
    process.env.HERDR_PLUGIN_STATE_DIR ||
    join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "herdr", "plugins", PLUGIN_ID);
  mkdirSync(configDir, { recursive: true });
  mkdirSync(stateDir, { recursive: true });
  return {
    socket: process.env.HERDR_SOCKET_PATH || join(homedir(), ".config", "herdr", "herdr.sock"),
    herdrBin: bin,
    configDir,
    stateDir,
    configFile: join(configDir, "config.toml"),
    pidFile: join(stateDir, "gateway.pid"),
    logFile: join(stateDir, "gateway.log"),
  };
}

function tailscaleSelfLogin(): string | undefined {
  try {
    const r = Bun.spawnSync(["tailscale", "status", "--json"], { stderr: "pipe" });
    if (r.exitCode !== 0) return undefined;
    // UserIDs exceed 2^53, so JSON.parse would round them; match the raw text.
    const raw = r.stdout.toString();
    const userId = raw.match(/"Self":\s*\{[\s\S]*?"UserID":\s*(\d+)/)?.[1];
    if (!userId) return undefined;
    return raw.match(new RegExp(`"${userId}":\\s*\\{[^}]*?"LoginName":\\s*"([^"]+)"`))?.[1];
  } catch {
    return undefined;
  }
}

function defaultPush(paths: Paths): PushConfig {
  return {
    key_file: join(paths.configDir, "apns.p8"),
    key_id: "",
    team_id: "RB5EV68CB8",
    topic: "dev.bal.herdr.app",
    notify: ["blocked", "done"],
    delay_ms: 3000,
  };
}

export function loadConfig(paths: Paths): GatewayConfig {
  if (!existsSync(paths.configFile)) {
    const login = tailscaleSelfLogin();
    writeConfig(paths, {
      port: 7777,
      serve_port: 8443,
      token: randomBytes(32).toString("base64url"),
      allowed_users: login ? [login] : [],
      public_url: "",
      deny_methods: DEFAULT_DENY_METHODS,
      push: defaultPush(paths),
      keep_awake: true,
    });
  }
  const raw = Bun.TOML.parse(readFileSync(paths.configFile, "utf8")) as Partial<GatewayConfig>;
  if (!raw.token || raw.token.length < 16) {
    throw new Error(`${paths.configFile}: token missing or shorter than 16 chars`);
  }
  return {
    port: raw.port ?? 7777,
    serve_port: raw.serve_port ?? 8443,
    token: raw.token,
    allowed_users: raw.allowed_users ?? [],
    public_url: raw.public_url ?? "",
    deny_methods: raw.deny_methods ?? DEFAULT_DENY_METHODS,
    push: { ...defaultPush(paths), ...(raw.push ?? {}) },
    keep_awake: raw.keep_awake ?? true,
  };
}

/** Installs an APNs key: copies the .p8 next to the config (0600) and records its id. */
export function setPushKey(paths: Paths, p8Path: string, keyId: string): GatewayConfig {
  const c = loadConfig(paths);
  const pem = readFileSync(p8Path, "utf8");
  if (!pem.includes("PRIVATE KEY")) throw new Error(`${p8Path} doesn't look like an APNs .p8 key`);
  const keyFile = join(paths.configDir, "apns.p8");
  writeFileSync(keyFile, pem, { mode: 0o600 });
  chmodSync(keyFile, 0o600);
  const next = { ...c, push: { ...c.push, key_file: keyFile, key_id: keyId.trim() } };
  writeConfig(paths, next);
  return next;
}

export function rotateToken(paths: Paths): GatewayConfig {
  const c = { ...loadConfig(paths), token: randomBytes(32).toString("base64url") };
  writeConfig(paths, c);
  return c;
}

function writeConfig(paths: Paths, c: GatewayConfig) {
  const list = (xs: string[]) => `[${xs.map((x) => JSON.stringify(x)).join(", ")}]`;
  const body = `# herdr iOS gateway config. Restart the gateway after editing:
#   herdr plugin action invoke ${PLUGIN_ID}.restart

# Loopback port the daemon binds (never exposed directly).
port = ${c.port}

# HTTPS port for: tailscale serve --bg --https=${c.serve_port} http://127.0.0.1:${c.port}
serve_port = ${c.serve_port}

# Bearer token the app must send. Rotate with: sh bin/gateway-ctl rotate-token
token = ${JSON.stringify(c.token)}

# Tailscale logins allowed (checked via the Tailscale-User-Login header that
# tailscale serve injects). Empty list = all tailnet requests are refused.
allowed_users = ${list(c.allowed_users)}

# Override the URL advertised in the pairing QR (default: wss://<magicdns>:<serve_port>/ws).
public_url = ${JSON.stringify(c.public_url)}

# Socket API methods the gateway refuses to forward.
deny_methods = ${list(c.deny_methods)}

# Keep the Mac from idle-sleeping while agents are working or waiting on you
# (released two minutes after they're all done).
keep_awake = ${c.keep_awake}

# Push notifications through Apple (APNs), sent straight from this Mac.
# Install a key with: sh bin/gateway-ctl push-key <AuthKey_XXXX.p8> <KEY_ID>
[push]
key_file = ${JSON.stringify(c.push.key_file)}
key_id = ${JSON.stringify(c.push.key_id)}
team_id = ${JSON.stringify(c.push.team_id)}
# The app's bundle id.
topic = ${JSON.stringify(c.push.topic)}
# Agent statuses that notify (blocked = needs input, done = finished).
notify = ${list(c.push.notify)}
# A status must hold this long before notifying.
delay_ms = ${c.push.delay_ms}
`;
  writeFileSync(paths.configFile, body, { mode: 0o600 });
  chmodSync(paths.configFile, 0o600);
}
