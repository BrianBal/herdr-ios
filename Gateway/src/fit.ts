// Holds a pane at the phone's size, the way a smaller tmux client shrinks a
// window: a herdr terminal session controller owns the pane's resize while it
// runs, so full-screen programs (opencode, vim, htop) redraw to fit the phone
// instead of being rewrapped there. When it exits herdr puts back the Mac's size.

import type { Subprocess } from "bun";

export const FIT_COLS = { min: 20, max: 500 };
export const FIT_ROWS = { min: 5, max: 300 };

const clamp = (n: number, { min, max }: { min: number; max: number }) => Math.min(max, Math.max(min, Math.round(n)));

/** Both sizes, clamped; null unless both are positive numbers. */
export function fitSize(cols: unknown, rows: unknown): { cols: number; rows: number } | null {
  const c = Number(cols);
  const r = Number(rows);
  if (!(c > 0) || !(r > 0)) return null;
  return { cols: clamp(c, FIT_COLS), rows: clamp(r, FIT_ROWS) };
}

export interface FitOptions {
  herdrBin: string;
  socket: string;
  log?: (msg: string) => void;
}

export class PaneFit {
  private proc: Subprocess<"pipe", "ignore", "pipe">;
  private closed = false;
  cols: number;
  rows: number;

  constructor(readonly paneId: string, size: { cols: number; rows: number }, { herdrBin, socket, log }: FitOptions) {
    this.cols = size.cols;
    this.rows = size.rows;
    this.proc = Bun.spawn(
      [herdrBin, "terminal", "session", "control", paneId, "--takeover", "--cols", String(size.cols), "--rows", String(size.rows)],
      // Frames go to /dev/null: the watch reads the pane with pane.read, which
      // already reports the controller's size.
      { stdin: "pipe", stdout: "ignore", stderr: "pipe", env: { ...process.env, HERDR_SOCKET_PATH: socket } },
    );
    this.proc.exited.then(async (code) => {
      if (this.closed || code === 0) return;
      const err = (await new Response(this.proc.stderr).text()).trim().split("\n")[0];
      log?.(`fit ${paneId} ended (${code})${err ? `: ${err}` : ""}`);
    });
  }

  resize(size: { cols: number; rows: number }) {
    if (this.closed || (size.cols === this.cols && size.rows === this.rows)) return;
    this.cols = size.cols;
    this.rows = size.rows;
    this.write({ type: "terminal.resize", cols: size.cols, rows: size.rows });
  }

  /** Gives the pane back; closing stdin is enough, the kill is a fallback. */
  close() {
    if (this.closed) return;
    this.write({ type: "terminal.release" });
    this.closed = true;
    try {
      this.proc.stdin.end();
    } catch {}
    const kill = setTimeout(() => this.proc.kill(), 2000);
    this.proc.exited.then(() => clearTimeout(kill));
  }

  private write(cmd: object) {
    try {
      this.proc.stdin.write(JSON.stringify(cmd) + "\n");
      this.proc.stdin.flush();
    } catch {}
  }
}
