// Claude Code panes keep no terminal scrollback herdr can read (the app
// redraws its own screen), but Claude saves every session as JSONL under
// ~/.claude/projects/<cwd with non-alphanumerics as "-">/<session>.jsonl.
// This finds the pane's session and renders it the way Claude's screen
// looks, so the app can show it as earlier output.

import { openSync, readSync, closeSync, fstatSync, readdirSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const TITLE_PROBE_BYTES = 256 * 1024;
const TAIL_BYTES = 8 * 1024 * 1024;
const MAX_CANDIDATES = 20;

export function claudeProjectDir(cwd: string, home = homedir()): string {
  return join(home, ".claude", "projects", cwd.replace(/[^A-Za-z0-9]/g, "-"));
}

/** The last `bytes` of a file, starting at a line boundary. */
export function readTail(path: string, bytes: number): string {
  const fd = openSync(path, "r");
  try {
    const size = fstatSync(fd).size;
    const start = Math.max(0, size - bytes);
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    let text = buf.toString("utf8");
    if (start > 0) text = text.slice(text.indexOf("\n") + 1);
    return text;
  } finally {
    closeSync(fd);
  }
}

function lastTitle(jsonl: string): string | undefined {
  let title: string | undefined;
  for (const line of jsonl.split("\n")) {
    if (!line.includes('"ai-title"') && !line.includes('"custom-title"')) continue;
    try {
      const o = JSON.parse(line);
      title = o.aiTitle ?? o.customTitle ?? title;
    } catch {}
  }
  return title;
}

/**
 * The session file for a pane: the one whose latest title matches the pane's
 * terminal title (Claude sets both), else the most recently written.
 */
export function findClaudeSession(cwd: string, title: string | undefined, home = homedir()): string | undefined {
  const dir = claudeProjectDir(cwd, home);
  let files: { path: string; mtime: number }[];
  try {
    files = readdirSync(dir)
      .filter((f) => f.endsWith(".jsonl"))
      .map((f) => ({ path: join(dir, f), mtime: statSync(join(dir, f)).mtimeMs }))
      .sort((a, b) => b.mtime - a.mtime)
      .slice(0, MAX_CANDIDATES);
  } catch {
    return undefined;
  }
  const want = title?.trim();
  if (want) {
    for (const f of files) if (lastTitle(readTail(f.path, TITLE_PROBE_BYTES)) === want) return f.path;
  }
  return files[0]?.path;
}

const BOLD = "\x1b[1m";
const NOT_BOLD = "\x1b[22m";
// Claude's lavender for code, so the app's segmenter sees code blocks as code.
const CODE = "\x1b[38;2;177;185;249m";
const NOT_CODE = "\x1b[39m";

/**
 * Markdown as Claude's screen shows it: headings and **bold** in bold,
 * `code` and fenced blocks in the code color, fences themselves dropped.
 */
export function markdownToAnsi(text: string): string {
  let fenced = false;
  const out: string[] = [];
  for (const line of text.split("\n")) {
    if (/^\s*```/.test(line)) {
      fenced = !fenced;
      continue;
    }
    if (fenced) {
      out.push(line.trim() ? `${CODE}${line}${NOT_CODE}` : line);
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.*)$/);
    let l = heading ? `${BOLD}${heading[2]}${NOT_BOLD}` : line;
    l = l.replace(/\*\*([^*\n]+)\*\*/g, `${BOLD}$1${NOT_BOLD}`);
    l = l.replace(/`([^`\n]+)`/g, `${CODE}$1${NOT_CODE}`);
    out.push(l);
  }
  return out.join("\n");
}

function toolSummary(name: string, input: any): string {
  const arg = input?.command ?? input?.file_path ?? input?.pattern ?? input?.url ?? input?.description ?? input?.prompt;
  const s = typeof arg === "string" ? arg.replace(/\s+/g, " ").trim() : "";
  return `${name}(${s.length > 80 ? s.slice(0, 79) + "…" : s})`;
}

/** "⏺ first line" with following lines indented two spaces, like Claude's screen. */
function block(marker: string, text: string): string[] {
  const lines = text.replace(/\s+$/, "").split("\n");
  return lines.map((l, i) => (i === 0 ? `${marker} ${l}` : l ? `  ${l}` : ""));
}

/**
 * Renders a session as Claude shows it: your prompts (❯), replies (⏺) and
 * one-line tool calls; thinking, tool output and subagent traffic are left out.
 */
export function renderClaudeTranscript(jsonl: string): string[] {
  const out: string[] = [];
  const push = (lines: string[]) => {
    if (out.length && out[out.length - 1] !== "") out.push("");
    out.push(...lines);
  };
  for (const line of jsonl.split("\n")) {
    if (!line.trim()) continue;
    let o: any;
    try {
      o = JSON.parse(line);
    } catch {
      continue;
    }
    if (o.isSidechain || o.isMeta) continue;
    const content = o.message?.content;
    if (o.type === "user") {
      const text =
        typeof content === "string"
          ? content
          : Array.isArray(content)
            ? content.filter((c: any) => c?.type === "text").map((c: any) => c.text).join("\n")
            : "";
      // Slash-command plumbing and system reminders aren't things you typed.
      if (!text.trim() || text.trimStart().startsWith("<")) continue;
      push(block("❯", text));
    } else if (o.type === "assistant" && Array.isArray(content)) {
      for (const c of content) {
        if (c?.type === "text" && c.text?.trim()) push(block("⏺", markdownToAnsi(c.text)));
        else if (c?.type === "tool_use") push([`⏺ ${toolSummary(c.name, c.input)}`]);
      }
    }
  }
  return out;
}

/** The pane's Claude session as screen-like text, last `maxLines` lines. */
export function claudeTranscript(cwd: string, title: string | undefined, maxLines: number, home = homedir()) {
  const file = findClaudeSession(cwd, title, home);
  if (!file) return undefined;
  const lines = renderClaudeTranscript(readTail(file, TAIL_BYTES));
  return { text: lines.slice(-maxLines).join("\n"), truncated: lines.length > maxLines, file };
}
