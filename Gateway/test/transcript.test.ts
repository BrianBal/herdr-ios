import { describe, expect, test } from "bun:test";
import { appendFileSync, mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  claudeProjectDir, claudeTranscript, findClaudeSession, markdownToAnsi, renderClaudeTranscript, TranscriptFollower,
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
    writeFileSync(file, [j({ type: "user", uuid: "u1", message: { content: "hi" } }), say("a1", "one\ntwo"), ""].join("\n"));
    const f = new TranscriptFollower(file);
    expect(f.blocks.map((b) => b.id)).toEqual(["u1:0", "a1:0"]);
    expect(f.poll()).toEqual([]);

    // A line arrives in two writes: nothing until it's whole.
    const line = say("a2", "three");
    appendFileSync(file, line.slice(0, 10));
    expect(f.poll()).toEqual([]);
    appendFileSync(file, line.slice(10) + "\n");
    expect(f.poll()).toEqual([{ id: "a2:0", lines: ["⏺ three"] }]);

    // Paging: the last blocks holding at least n lines, optionally before an id.
    expect(f.tail(1)).toEqual({ blocks: [{ id: "a2:0", lines: ["⏺ three"] }], start: false });
    expect(f.tail(100, "a2:0").blocks.map((b) => b.id)).toEqual(["u1:0", "a1:0"]);
    expect(f.tail(100, "a2:0").start).toBe(true);

    writeFileSync(file, "");
    expect(f.poll()).toBeNull();
    rmSync(dir, { recursive: true, force: true });
  });
});
