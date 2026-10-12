// Photos sent from the app for agents to look at. herdr's API has no way to
// hand an agent an image, so the gateway saves it as a file on this machine
// and the app puts the file's path in the prompt; Claude Code and Codex both
// open images by path. Uploads are private to this user and deleted after a day.

import { mkdirSync, readdirSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomBytes } from "node:crypto";

export const MAX_UPLOAD_BYTES = 12 * 1024 * 1024;
const KEEP_MS = 24 * 60 * 60 * 1000;
const EXTENSIONS = new Set(["jpg", "jpeg", "png", "heic", "gif", "webp"]);

export class UploadError extends Error {}

export class Uploads {
  constructor(
    readonly dir: string,
    private now: () => number = Date.now,
  ) {}

  /** Saves base64 image data; returns the file's absolute path. */
  save(base64: string, ext: string): string {
    const e = ext.toLowerCase().replace(/^\./, "");
    if (!EXTENSIONS.has(e)) throw new UploadError(`unsupported image type: ${ext}`);
    // Decoded size is ~3/4 of the base64 length; check before decoding.
    if (base64.length * 0.75 > MAX_UPLOAD_BYTES) throw new UploadError("image is too large (max 12 MB)");
    const data = Buffer.from(base64, "base64");
    if (data.length === 0) throw new UploadError("no image data");
    mkdirSync(this.dir, { recursive: true, mode: 0o700 });
    this.prune();
    const stamp = new Date(this.now()).toISOString().replace(/[-:]/g, "").replace("T", "-").slice(0, 15);
    const path = join(this.dir, `photo-${stamp}-${randomBytes(3).toString("hex")}.${e}`);
    writeFileSync(path, data, { mode: 0o600 });
    return path;
  }

  /** Deletes uploads older than a day. */
  prune() {
    let names: string[];
    try {
      names = readdirSync(this.dir);
    } catch {
      return;
    }
    const cutoff = this.now() - KEEP_MS;
    for (const name of names) {
      const p = join(this.dir, name);
      try {
        if (statSync(p).mtimeMs < cutoff) unlinkSync(p);
      } catch {}
    }
  }
}
