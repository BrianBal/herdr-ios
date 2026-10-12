// Minimal client for herdr's socket API: newline-delimited JSON over a Unix
// socket. The server answers one request per connection and then closes it,
// except events.subscribe, which keeps streaming event lines.

export interface HerdrResponse {
  id?: string;
  result?: any;
  error?: { code: string; message: string };
  [k: string]: unknown;
}

export class HerdrUnavailable extends Error {}

const decoder = () => new TextDecoder();

function lineReader(onLine: (line: string) => void) {
  let buf = "";
  const dec = decoder();
  return (chunk: Uint8Array) => {
    buf += dec.decode(chunk, { stream: true });
    let i: number;
    while ((i = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      if (line.trim()) onLine(line);
    }
  };
}

export class HerdrSocket {
  constructor(readonly path: string) {}

  /** One request/response round trip. Rejects with HerdrUnavailable if the server is down. */
  call(method: string, params: unknown = {}, timeoutMs?: number): Promise<HerdrResponse> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let timer: Timer | undefined;
      const finish = (fn: () => void) => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        fn();
      };
      const read = lineReader((line) => {
        finish(() => {
          try {
            resolve(JSON.parse(line));
          } catch (e) {
            reject(new Error(`herdr sent invalid JSON: ${line.slice(0, 200)}`));
          }
        });
      });
      Bun.connect({
        unix: this.path,
        socket: {
          open(s) {
            s.write(JSON.stringify({ id: "gw", method, params }) + "\n");
            if (timeoutMs) {
              timer = setTimeout(() => {
                finish(() => reject(new Error(`herdr ${method} timed out after ${timeoutMs}ms`)));
                s.end();
              }, timeoutMs);
            }
          },
          data(s, d) {
            read(d);
            if (settled) s.end();
          },
          close() {
            finish(() => reject(new HerdrUnavailable(`herdr closed the connection during ${method}`)));
          },
          error(_s, e) {
            finish(() => reject(new HerdrUnavailable(e.message)));
          },
        },
      }).catch((e) => finish(() => reject(new HerdrUnavailable(`cannot reach herdr at ${this.path}: ${e.message}`))));
    });
  }

  /**
   * Open a streaming subscription. `onLine` receives every parsed line,
   * starting with the subscription_started (or error) response. `onClose`
   * fires once when herdr ends the stream or the socket fails.
   */
  async subscribe(
    params: unknown,
    onLine: (msg: HerdrResponse) => void,
    onClose: (reason?: string) => void,
  ): Promise<{ close(): void }> {
    let closed = false;
    const done = (reason?: string) => {
      if (closed) return;
      closed = true;
      onClose(reason);
    };
    const read = lineReader((line) => {
      try {
        onLine(JSON.parse(line));
      } catch {
        // herdr only emits JSON lines; drop anything else.
      }
    });
    try {
      const sock = await Bun.connect({
        unix: this.path,
        socket: {
          open(s) {
            s.write(JSON.stringify({ id: "gw-sub", method: "events.subscribe", params }) + "\n");
          },
          data(_s, d) {
            read(d);
          },
          close() {
            done();
          },
          error(_s, e) {
            done(e.message);
          },
        },
      });
      return {
        close() {
          closed = true;
          sock.end();
        },
      };
    } catch (e: any) {
      throw new HerdrUnavailable(`cannot reach herdr at ${this.path}: ${e.message}`);
    }
  }
}
