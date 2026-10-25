import { describe, expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  claudeProjectDir, claudeTranscript, findClaudeSession, markdownToAnsi, readRange, renderClaudeTranscript, TranscriptFollower,
} from "../src/transcript";

const j = (o: unknown) => JSON.stringify(o);
const session = [
  j({ type: "user", message: { content: "fix the charts\nplease" } }),
  j({ type: "user", message: { content: "<command-name>/clear</command-name>" } }),
  j({ type: "assistant", message: { content: [{ type: "thinking", thinking: "hmm" }] } }),
  j({ type: "assistant", message: { content: [{ type: "text", text: "Looking at it.\n\nFirst:\n- a\n- b" }] } }),
  j({ type: "assistant", message: { content: [{ type: "tool_use", name: "Bash", input: { command: "bun test   --watch" } }] } }),
  j({ type: "user", message: { content: [{ type: "tool_result", content: "ok" }] } }),
  j({ type: "assistant", isSidechain: true, message: { content: [{ type: "text", text: "subagent chatter" }] } }),
  j({ type: "ai-title", aiTitle: "Chart fixes" }),
].join("\n");

describe("claude transcript", () => {
  test("renders prompts, replies and tool calls like the screen", () => {
    expect(renderClaudeTranscript(session)).toEqual([
      "❯ fix the charts",
      "  please",
      "",
      "⏺ Looking at it.",
      "",
      "  First:",
      "  - a",
      "  - b",
      "",
      "⏺ Bash(bun test --watch)",
    ]);
  });

  test("markdown becomes terminal styling", () => {
    const e = "\x1b";
    expect(markdownToAnsi("## Plan\nUse **bold** and `x()`.\n```ts\nconst a = 1;\n\n```\ndone")).toBe(
      [`${e}[1mPlan${e}[22m`, `Use ${e}[1mbold${e}[22m and ${e}[38;2;177;185;249mx()${e}[39m.`,
       `${e}[38;2;177;185;249mconst a = 1;${e}[39m`, "", "done"].join("\n"),
    );
  });

  test("project dir naming matches Claude's", () => {
    expect(claudeProjectDir("/Users/me/trace/Trace.Bot", "/Users/me")).toBe("/Users/me/.claude/projects/-Users-me-trace-Trace-Bot");
  });

  test("finds the session by title, else the newest", () => {
    const home = mkdtempSync(join(tmpdir(), "claude-home-"));
    const dir = claudeProjectDir("/w/proj", home);
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, "old.jsonl"), session);
    writeFileSync(join(dir, "new.jsonl"), j({ type: "ai-title", aiTitle: "Other" }));
    const past = new Date(Date.now() - 60_000);
    utimesSync(join(dir, "old.jsonl"), past, past);
    expect(findClaudeSession("/w/proj", "Chart fixes", home)).toBe(join(dir, "old.jsonl"));
    expect(findClaudeSession("/w/proj", "Unknown", home)).toBe(join(dir, "new.jsonl"));
    expect(findClaudeSession("/w/none", "x", home)).toBeUndefined();
    const t = claudeTranscript("/w/proj", "Chart fixes", 3, home)!;
    expect(t.text.split("\n")).toEqual(["  - b", "", "⏺ Bash(bun test --watch)"]);
    expect(t.truncated).toBe(true);
    rmSync(home, { recursive: true, force: true });
  });

  test("follows the session as Claude appends to it", () => {
    const dir = mkdtempSync(join(tmpdir(), "claude-follow-"));
    const file = join(dir, "s.jsonl");
    const say = (uuid: string, text: string) => j({ type: "assistant", uuid, message: { content: [{ type: "text", text }] } });
    const line0 = j({ type: "user", uuid: "u1", message: { content: "hi" } });
    const line1 = say("a1", "one\ntwo");
    writeFileSync(file, [line0, line1, ""].join("\n"));
    const f = new TranscriptFollower(file);
    expect(f.blocks.map((b) => b.id)).toEqual(["u1:0", "a1:0"]);
    expect(f.poll()).toEqual([]);

    // A line arrives in two writes: nothing until it's whole.
    const line = say("a2", "three");
    appendFileSync(file, line.slice(0, 10));
    expect(f.poll()).toEqual([]);
    appendFileSync(file, line.slice(10) + "\n");
    const a2 = { id: "a2:0", at: line0.length + line1.length + 2, lines: ["⏺ three"] };
    expect(f.poll()).toEqual([a2]);

    // Paging: the last blocks holding at least n lines, optionally before an id.
    expect(f.tail(1)).toEqual({ blocks: [a2], start: false, prev: line0.length + 1 });
    expect(f.tail(100, "a2:0").blocks.map((b) => b.id)).toEqual(["u1:0", "a1:0"]);
    expect(f.tail(100, "a2:0").start).toBe(true);

    writeFileSync(file, "");
    expect(f.poll()).toBeNull();
    rmSync(dir, { recursive: true, force: true });
  });

  test("reads any range of the file, from either end", () => {
    const dir = mkdtempSync(join(tmpdir(), "claude-range-"));
    const file = join(dir, "s.jsonl");
    const say = (n: number) => j({ type: "assistant", uuid: `a${n}`, message: { content: [{ type: "text", text: `m${n}` }] } });
    const lines = Array.from({ length: 10 }, (_, i) => say(i));
    // An entry with nothing to show (thinking) in the middle.
    lines.splice(5, 0, j({ type: "assistant", uuid: "t", message: { content: [{ type: "thinking", thinking: "x".repeat(50) }] } }));
    writeFileSync(file, lines.join("\n") + "\n");
    const at: number[] = [];
    lines.reduce((pos, l) => (at.push(pos), pos + l.length + 1), 0);
    const ids = (r: { blocks: { id: string }[] }) => r.blocks.map((b) => b.id.split(":")[0]);

    // The gap between a0 and a6 (after the thinking entry), from the end, 2 blocks (4 lines) at a time.
    let r = readRange(file, at[0] + 1, at[7], 4);
    expect(ids(r)).toEqual(["a4", "a5"]);
    expect(r).toMatchObject({ more: true, edge: at[4] });
    r = readRange(file, at[0] + 1, r.edge, 4);
    expect(ids(r)).toEqual(["a2", "a3"]);
    r = readRange(file, at[0] + 1, r.edge, 4);
    expect(ids(r)).toEqual(["a1"]);
    expect(r).toMatchObject({ more: false, edge: at[0] + 1 });

    // From the start: past a0, first 4 lines' worth.
    r = readRange(file, at[0] + 1, at[10], 4, false);
    expect(ids(r)).toEqual(["a1", "a2"]);
    expect(r).toMatchObject({ more: true, edge: at[3] });
    r = readRange(file, r.edge, at[10], 100, false);
    expect(ids(r)).toEqual(["a3", "a4", "a5", "a6", "a7", "a8"]);
    expect(r).toMatchObject({ more: false, edge: at[10] });

    // Chunks shorter than a line don't matter, either way.
    const all = ["a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "a8", "a9"];
    for (const chunk of [7, 64, 1 << 20]) {
      expect(ids(readRange(file, 0, 1e9, 1000, true, chunk))).toEqual(all);
      expect(ids(readRange(file, 0, 1e9, 1000, false, chunk))).toEqual(all);
      expect(ids(readRange(file, at[0] + 1, at[7], 4, true, chunk))).toEqual(["a4", "a5"]);
      expect(ids(readRange(file, at[0] + 1, at[10], 4, false, chunk))).toEqual(["a1", "a2"]);
    }
    rmSync(dir, { recursive: true, force: true });
  });
});
