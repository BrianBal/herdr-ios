import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { complete, looksRemote, parseLine, rank } from "../src/complete";

describe("shell completion", () => {
  test("first word is a command, after cd a folder, otherwise a file", () => {
    expect(parseLine("gi")).toEqual({ word: "gi", mode: "command" });
    expect(parseLine("ls | gr")).toEqual({ word: "gr", mode: "command" });
    expect(parseLine("./scr")).toEqual({ word: "./scr", mode: "file" });
    expect(parseLine("cd sr")).toEqual({ word: "sr", mode: "dir" });
    expect(parseLine("git add ")).toEqual({ word: "", mode: "file" });
  });

  test("hides dotfiles unless asked, escapes spaces, short commands first", () => {
    expect(rank([".git/", "src/", "my file"], "", "file")).toEqual(["my\\ file", "src/"]);
    expect(rank([".git/", ".env"], ".", "file")).toEqual([".env", ".git/"]);
    expect(rank(["gitk", "git", "gifbuild"], "gi", "command")).toEqual(["git", "gitk", "gifbuild"]);
  });

  test("completes files and folders in the pane's folder", async () => {
    const dir = mkdtempSync(join(tmpdir(), "complete-"));
    mkdirSync(join(dir, "src"));
    writeFileSync(join(dir, "setup.sh"), "");
    writeFileSync(join(dir, "other.txt"), "");
    expect(await complete("cat s", dir)).toEqual({ word: "s", candidates: ["setup.sh", "src/"] });
    expect(await complete("cd s", dir)).toEqual({ word: "s", candidates: ["src/"] });
    expect((await complete("ech", dir)).candidates).toContain("echo");
    expect((await complete("", dir)).candidates).toEqual([]);
  });

  test("a prompt naming another host is remote", () => {
    expect(looksRemote("ubuntu@ip-10-12-1-1: ~", "my-mac.local")).toBe(true);
    expect(looksRemote("bal@my-mac: ~/labs", "my-mac.local")).toBe(false);
    expect(looksRemote("vim notes.md", "my-mac")).toBe(false);
  });
});
