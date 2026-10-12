// Long-running gateway process. Normally spawned detached by `gateway-ctl ensure`
// from herdr's startup hook; `gateway-ctl run` runs it in the foreground.

import { readFileSync, rmSync } from "node:fs";
import { loadConfig, resolvePaths } from "./config";
import { createGateway } from "./gateway";
import { HerdrSocket } from "./herdr";
import { DeviceStore, Notifier, apnsFromConfig } from "./push";

const HERDR_GONE_EXIT_MS = 10 * 60 * 1000;
const WATCHDOG_MS = 15 * 1000;

const log = (msg: string) => console.log(`${new Date().toISOString()} ${msg}`);

const paths = resolvePaths();
const config = loadConfig(paths);
const herdr = new HerdrSocket(paths.socket);
const apns = apnsFromConfig(config.push);
const devices = new DeviceStore(paths.stateDir);
const notifier = new Notifier({
  herdr,
  devices,
  sender: apns.client,
  config: config.push,
  activeTokens: () => gateway.activeTokens(),
  log,
});
const gateway = createGateway({ config, herdr, log, push: { devices, notifier, problem: apns.problem } });
if (apns.problem) log(`push notifications off: ${apns.problem}`);
notifier.start();

let server: ReturnType<typeof Bun.serve>;
try {
  server = Bun.serve({ hostname: "127.0.0.1", port: config.port, fetch: gateway.fetch, websocket: gateway.websocket });
} catch (e: any) {
  log(`cannot listen on 127.0.0.1:${config.port}: ${e.message}`);
  process.exit(1);
}
log(`listening on http://127.0.0.1:${server.port} (herdr socket ${paths.socket}, pid ${process.pid})`);

function shutdown(reason: string) {
  log(`shutting down: ${reason}`);
  server.stop(true);
  notifier.stop();
  apns.client?.close();
  try {
    if (readFileSync(paths.pidFile, "utf8").trim() === String(process.pid)) rmSync(paths.pidFile);
  } catch {}
  process.exit(0);
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

// herdr's startup hook re-runs on every server start, so if herdr stays gone
// for a long time we exit rather than linger as an orphan.
let herdrDownSince: number | null = null;
setInterval(async () => {
  try {
    await herdr.call("ping", {}, 2000);
    if (herdrDownSince) log("herdr reachable again");
    herdrDownSince = null;
  } catch (e: any) {
    if (!herdrDownSince) {
      herdrDownSince = Date.now();
      log(`herdr unreachable: ${e.message}`);
    } else if (Date.now() - herdrDownSince > HERDR_GONE_EXIT_MS) {
      shutdown("herdr unreachable for 10 minutes");
    }
  }
}, WATCHDOG_MS);
