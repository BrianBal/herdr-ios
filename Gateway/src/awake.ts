// Keeps the Mac from idle-sleeping while agents are busy, so a long task
// doesn't stall halfway (and its "done" notification doesn't wait until
// morning). Holds a `caffeinate` assertion while any agent is working or
// blocked, and lets go once everything has been quiet for a while.
//
// caffeinate -i: no idle sleep; -s: no system sleep while on AC power. A lid
// closed on battery still sleeps, which macOS doesn't let apps prevent.
// -w ties it to the gateway's pid, so it can't outlive the gateway.

import { spawn, type ChildProcess } from "node:child_process";

export interface AwakeOptions {
  /** Release this long after the last busy moment. */
  quietMs?: number;
  log?: (msg: string) => void;
  /** Starts the assertion; returns a handle with kill(). Injected in tests. */
  start?: () => { kill(): void };
  now?: () => number;
}

function startCaffeinate(): ChildProcess {
  const child = spawn("caffeinate", ["-is", "-w", String(process.pid)], { stdio: "ignore" });
  child.on("error", () => {}); // caffeinate missing (not macOS): nothing to hold
  return child;
}

export class KeepAwake {
  private hold?: { kill(): void };
  private lastBusy = 0;
  private quietMs: number;
  private log: (msg: string) => void;
  private startFn: () => { kill(): void };
  private now: () => number;

  constructor(o: AwakeOptions = {}) {
    this.quietMs = o.quietMs ?? 2 * 60_000;
    this.log = o.log ?? (() => {});
    this.startFn = o.start ?? startCaffeinate;
    this.now = o.now ?? Date.now;
  }

  get holding() {
    return !!this.hold;
  }

  /** Called on every board poll with whether any agent is working or blocked. */
  update(busy: boolean) {
    if (busy) {
      this.lastBusy = this.now();
      if (!this.hold) {
        this.hold = this.startFn();
        this.log("keeping the Mac awake while agents work");
      }
    } else if (this.hold && this.now() - this.lastBusy >= this.quietMs) {
      this.release();
      this.log("agents quiet; the Mac may sleep again");
    }
  }

  release() {
    this.hold?.kill();
    this.hold = undefined;
  }
}
