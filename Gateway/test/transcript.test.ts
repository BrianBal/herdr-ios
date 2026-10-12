import { describe, expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, utimesSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { claudeProjectDir, claudeTranscript, findClaudeSession, markdownToAnsi, renderClaudeTranscript } from "../src/transcript";

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
});
