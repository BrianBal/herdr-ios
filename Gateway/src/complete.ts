// Tab completion for shell panes, done here rather than in the pane's own
// shell: pressing Tab there would type into the user's command line. bash's
// compgen runs in the pane's folder and offers command names for the first
// word, folders after `cd`, and files otherwise. It doesn't know the shell's
// own aliases or functions, and a pane that's ssh'd somewhere else gets none.

import { hostname, homedir } from "node:os";

export interface Completion {
  /** The word being completed, as typed: the app replaces it with a candidate. */
  word: string;
  /** Ready to insert (spaces escaped); folders end in "/". */
  candidates: string[];
}

type Mode = "command" | "dir" | "file";

const SCRIPT = `
cd -- "$1" 2>/dev/null || cd ~
case $3 in
  command) compgen -c -- "$2" ;;
  dir) compgen -d -- "$2" ;;
  *) compgen -f -- "$2" ;;
esac | head -500 | while IFS= read -r f; do
  e=\${f/#\\~/$HOME}
  if [[ -d $e ]]; then printf '%s/\\n' "$f"; else printf '%s\\n' "$f"; fi
done`;

const SEPARATORS = new Set(["|", "||", "&&", ";", "&", "sudo", "time", "env", "xargs"]);

/** Which word is being completed and what kind of thing it should be. */
export function parseLine(line: string): { word: string; mode: Mode } {
  const words = line.split(/\s+/);
  const word = words.pop() ?? "";
  const before = words.filter((w) => w !== "");
  const prev = before.at(-1);
  const first = prev === undefined || SEPARATORS.has(prev);
  if (first) return { word, mode: word.includes("/") || word.startsWith("~") ? "file" : "command" };
  if (before.length === 1 && prev === "cd") return { word, mode: "dir" };
  return { word, mode: "file" };
}

/** The candidates worth showing: no hidden files unless asked for, short command names first. */
export function rank(raw: string[], word: string, mode: Mode, limit = 20): string[] {
  const base = word.slice(word.lastIndexOf("/") + 1);
  let list = [...new Set(raw.filter((c) => c && c !== word))];
  if (!base.startsWith(".")) list = list.filter((c) => !c.replace(/\/$/, "").split("/").at(-1)!.startsWith("."));
  list.sort(mode === "command" ? (a, b) => a.length - b.length || a.localeCompare(b) : (a, b) => a.localeCompare(b));
  return list.slice(0, limit).map(escape);
}

function escape(c: string) {
  return c.replace(/([ '"()&;|<>$`\\!*?[\]{}#])/g, "\\$1");
}

/** A terminal title like "ubuntu@ip-10-0-0-1: ~" names another machine: completing here would mislead. */
export function looksRemote(title: string | undefined, local = hostname()): boolean {
  const m = title?.match(/^[\w.-]+@([\w.-]+)[:\s]/);
  if (!m) return false;
  const short = (h: string) => h.toLowerCase().split(".")[0];
  return short(m[1]) !== short(local);
}

export async function complete(line: string, cwd: string | undefined, bash = Bun.which("bash") ?? "/bin/bash"): Promise<Completion> {
  const { word, mode } = parseLine(line);
  // Every command on the machine isn't a useful list.
  if (mode === "command" && word === "") return { word, candidates: [] };
  const proc = Bun.spawn([bash, "--norc", "--noprofile", "-c", SCRIPT, "complete", cwd ?? homedir(), word, mode], {
    stdout: "pipe",
    stderr: "ignore",
    stdin: "ignore",
  });
  const timer = setTimeout(() => proc.kill(), 2000);
  const out = await new Response(proc.stdout).text();
  clearTimeout(timer);
  return { word, candidates: rank(out.split("\n"), word, mode) };
}
