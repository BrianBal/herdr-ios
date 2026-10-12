// gateway-ctl: lifecycle + pairing for the iOS gateway daemon.
//
// herdr [[startup]] hooks are one-shot, so `ensure` spawns the daemon detached
// (own session, stdio to the state-dir log) and exits once it is healthy.

import { spawn } from "node:child_process";
import { openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import QRCode from "qrcode";
import { loadConfig, resolvePaths, rotateToken, setPushKey, PLUGIN_ID, type GatewayConfig, type Paths } from "./config";
import { DeviceStore, apnsFromConfig } from "./push";

const LOG_ROTATE_BYTES = 5 * 1024 * 1024;
const DAEMON = join(import.meta.dir, "daemon.ts");

function readPid(paths: Paths): number | null {
  try {
    const pid = Number(readFileSync(paths.pidFile, "utf8").trim());
    return Number.isInteger(pid) && pid > 0 ? pid : null;
  } catch {
    return null;
  }
}

function alive(pid: number | null): boolean {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

async function probe(config: GatewayConfig): Promise<{ body: any } | null> {
  try {
    const r = await fetch(`http://127.0.0.1:${config.port}/healthz`, { signal: AbortSignal.timeout(1000) });
    return { body: r.ok ? await r.json().catch(() => null) : null };
  } catch {
    return null; // nothing listening
  }
}

/** The gateway's health, or null if it isn't the one answering on the port. */
async function health(config: GatewayConfig): Promise<any | null> {
  const body = (await probe(config))?.body;
  // Other servers have a /healthz too; only ours reports gateway_version.
  return body?.gateway_version ? body : null;
}

function rotateLog(paths: Paths) {
  try {
    if (statSync(paths.logFile).size > LOG_ROTATE_BYTES) renameSync(paths.logFile, paths.logFile + ".1");
  } catch {}
}

async function ensure(paths: Paths, config: GatewayConfig): Promise<number> {
  const h = await health(config);
  if (h?.ok) {
    console.log(`gateway already running (pid ${h.pid}) on 127.0.0.1:${config.port}`);
    return 0;
  }
  if (await probe(config)) {
    console.error(
      `port ${config.port} is in use by another program; set a free port in ${paths.configFile} and run ensure again`,
    );
    return 1;
  }
  const stale = readPid(paths);
  if (alive(stale)) {
    // Process exists but is not answering: replace it.
    process.kill(stale!, "SIGTERM");
    await Bun.sleep(300);
  }
  rotateLog(paths);
  const out = openSync(paths.logFile, "a");
  const child = spawn(process.execPath, [DAEMON], {
    detached: true,
    stdio: ["ignore", out, out],
    env: {
      ...process.env,
      HERDR_SOCKET_PATH: paths.socket,
      HERDR_BIN_PATH: paths.herdrBin,
      HERDR_PLUGIN_CONFIG_DIR: paths.configDir,
      HERDR_PLUGIN_STATE_DIR: paths.stateDir,
    },
  });
  child.unref();
  writeFileSync(paths.pidFile, String(child.pid));
  for (let i = 0; i < 30; i++) {
    await Bun.sleep(100);
    const h2 = await health(config);
    if (h2?.ok) {
      console.log(`gateway started (pid ${h2.pid}) on 127.0.0.1:${config.port}; log: ${paths.logFile}`);
      return 0;
    }
    if (!alive(child.pid ?? null)) break;
  }
  console.error(`gateway failed to start; see ${paths.logFile}`);
  return 1;
}

async function stop(paths: Paths, config: GatewayConfig): Promise<number> {
  const pid = readPid(paths) ?? (await health(config))?.pid ?? null;
  if (!alive(pid)) {
    rmSync(paths.pidFile, { force: true });
    console.log("gateway not running");
    return 0;
  }
  process.kill(pid!, "SIGTERM");
  for (let i = 0; i < 30 && alive(pid); i++) await Bun.sleep(100);
  if (alive(pid)) process.kill(pid!, "SIGKILL");
  rmSync(paths.pidFile, { force: true });
  console.log(`gateway stopped (pid ${pid})`);
  return 0;
}

interface TailscaleInfo {
  dnsName?: string;
  serveTarget?: string;
}

function tailscaleInfo(config: GatewayConfig): TailscaleInfo {
  const run = (args: string[]) => {
    const r = Bun.spawnSync(["tailscale", ...args], { stderr: "pipe" });
    return r.exitCode === 0 ? JSON.parse(r.stdout.toString() || "{}") : null;
  };
  try {
    const dnsName = run(["status", "--json"])?.Self?.DNSName?.replace(/\.$/, "");
    const serve = run(["serve", "status", "--json"]);
    const handler = serve?.Web?.[`${dnsName}:${config.serve_port}`]?.Handlers?.["/"]?.Proxy;
    return { dnsName, serveTarget: handler };
  } catch {
    return {};
  }
}

function publicUrl(config: GatewayConfig, ts: TailscaleInfo): string | null {
  if (config.public_url) return config.public_url;
  return ts.dnsName ? `wss://${ts.dnsName}:${config.serve_port}/ws` : null;
}

async function status(paths: Paths, config: GatewayConfig): Promise<number> {
  const h = await health(config);
  const ts = tailscaleInfo(config);
  const expectedTarget = `http://127.0.0.1:${config.port}`;
  const report = {
    running: !!h?.ok,
    pid: h?.pid ?? null,
    herdr_reachable: h?.herdr ?? false,
    local_url: `http://127.0.0.1:${config.port}`,
    public_url: publicUrl(config, ts),
    tailscale_serve: ts.serveTarget ?? null,
    tailscale_serve_ok: ts.serveTarget === expectedTarget || ts.serveTarget === `http://localhost:${config.port}`,
    allowed_users: config.allowed_users,
    push: {
      ready: !apnsFromConfig(config.push).problem,
      problem: apnsFromConfig(config.push).problem ?? null,
      devices: new DeviceStore(paths.stateDir).list().map((d) => `${d.name ?? "device"} (${d.environment})`),
    },
    config: paths.configFile,
    log: paths.logFile,
  };
  console.log(JSON.stringify(report, null, 2));
  return report.running ? 0 : 1;
}

async function pair(paths: Paths, config: GatewayConfig, wait: boolean): Promise<number> {
  const ts = tailscaleInfo(config);
  const url = publicUrl(config, ts);
  const h = await health(config);
  console.log("herdr iOS gateway — pairing\n");
  if (!url) {
    console.log("Could not determine the Tailscale MagicDNS name. Is Tailscale running?");
    console.log(`Set public_url in ${paths.configFile} to override.`);
  } else {
    const link = `herdr-ios://pair?url=${encodeURIComponent(url)}&token=${encodeURIComponent(config.token)}`;
    console.log(await QRCode.toString(link, { type: "terminal", small: true, errorCorrectionLevel: "L" }));
    console.log(`URL:   ${url}`);
    console.log(`Token: ${config.token}`);
    console.log(`Link:  ${link}\n`);
  }
  if (!h?.ok) console.log("! gateway is not running — run: sh bin/gateway-ctl ensure");
  const target = ts.serveTarget;
  if (!config.public_url && !target) {
    console.log(`! tailscale serve is not set up for port ${config.serve_port}. Run once:`);
    console.log(`    tailscale serve --bg --https=${config.serve_port} http://127.0.0.1:${config.port}`);
  } else if (!config.public_url && !target!.endsWith(`:${config.port}`)) {
    console.log(`! tailscale serve :${config.serve_port} points at ${target}, not this gateway.`);
  }
  if (wait && process.stdin.isTTY) {
    console.log("\nPress Enter to close.");
    for await (const _ of console) break;
  }
  return 0;
}

const USAGE = `usage: gateway-ctl <command>
  ensure        start the daemon unless it is already healthy (herdr startup hook)
  stop          stop the daemon
  restart       stop then start
  status        print JSON status (daemon, herdr, tailscale serve)
  pair [--wait] print the pairing QR code for the iOS app
  rotate-token  generate a new token (restart + re-pair afterwards)
  push-key <AuthKey.p8> <KEY_ID>
                install the APNs key for push notifications (then restart)
  run           run the daemon in the foreground (development)`;

async function main(argv: string[]): Promise<number> {
  const [cmd, ...rest] = argv;
  if (!cmd || cmd === "-h" || cmd === "--help") {
    console.log(USAGE);
    return cmd ? 0 : 2;
  }
  const paths = resolvePaths();
  const config = loadConfig(paths);
  switch (cmd) {
    case "ensure":
    case "start":
      return ensure(paths, config);
    case "stop":
      return stop(paths, config);
    case "restart":
      await stop(paths, config);
      return ensure(paths, loadConfig(paths));
    case "status":
      return status(paths, config);
    case "pair":
      return pair(paths, config, rest.includes("--wait"));
    case "rotate-token": {
      rotateToken(paths);
      console.log(`new token written to ${paths.configFile}; restart the gateway and re-pair devices`);
      return 0;
    }
    case "push-key": {
      const [file, keyId] = rest;
      if (!file || !keyId) {
        console.error("usage: gateway-ctl push-key <AuthKey_XXXX.p8> <KEY_ID>");
        return 2;
      }
      const c = setPushKey(paths, file, keyId);
      const check = apnsFromConfig(c.push);
      if (check.problem) {
        console.error(check.problem);
        return 1;
      }
      console.log(`APNs key ${keyId} installed at ${c.push.key_file} (team ${c.push.team_id}, topic ${c.push.topic}).`);
      console.log("Restart the gateway to start sending: sh bin/gateway-ctl restart");
      return 0;
    }
    case "run":
      await import("./daemon");
      return new Promise(() => {}); // daemon keeps the process alive
    default:
      console.error(`unknown command: ${cmd}\n${USAGE}`);
      return 2;
  }
}

process.exit(await main(process.argv.slice(2)));
