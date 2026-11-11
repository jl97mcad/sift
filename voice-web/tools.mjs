// Two tools for the voice assistant: the Paseo CLI (reads freely; a few confirmed actions), and skills,
// short how-to notes in skills/*.md that it loads when a request matches one.
import { execFile } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { fileURLToPath } from "node:url";
import { digestLogs } from "./digest.mjs";
import { chiefOn } from "./chief.mjs";

const HERE = fileURLToPath(new URL(".", import.meta.url));

// ---- Paseo CLI
// Commands by what they do. Anything not listed is refused: no creating, deleting, archiving,
// restarting, editing or attaching by voice.
const READ = new Set(["ls", "inspect", "logs", "status", "wait", "schedule ls", "schedule inspect", "schedule logs", "permit ls", "terminal ls", "provider ls"]);
const CONFIRM = new Set(["stop", "permit allow", "permit deny", "schedule pause", "schedule resume", "schedule run-once"]);
const SEND = new Set(["send"]);
const GROUPS = new Set(["schedule", "permit", "terminal", "provider"]);

/** Splits a command line like a shell would for plain words and quotes; nothing is ever run by a shell. */
export function words(line) {
  const out = [];
  let word = null, quote = null;
  for (const ch of String(line ?? "")) {
    if (quote) { if (ch === quote) quote = null; else word += ch; continue; }
    if ((ch === "'" || ch === '"') && word === null) { quote = ch; word = ""; continue; } // only at a word's start: "don't" stays one word
    if (/\s/.test(ch)) { if (word !== null) out.push(word), (word = null); continue; }
    word = (word ?? "") + ch;
  }
  if (word !== null) out.push(word);
  return out;
}

export function hostsOf(config) {
  return config.paseo?.hosts ?? {};
}

/** The checked argument list for a command, or a reason it isn't allowed. */
export function plan(config, { command, host, confirmed }) {
  const hosts = hostsOf(config);
  const name = host || config.paseo?.default || Object.keys(hosts)[0];
  const address = hosts[name];
  if (!address) return { refused: `No Paseo host called "${host}". Hosts: ${Object.keys(hosts).join(", ") || "none"}.` };
  let args = words(command);
  if (args[0] === "paseo") args.shift();
  if (args[0] === "agent") args.shift(); // "agent ls" is "ls"
  if (args.some((a) => /^--(host|home)\b/.test(a))) return { refused: "Choose the host with the host field, not --host." };
  const verb = GROUPS.has(args[0]) ? `${args[0]} ${args[1] ?? ""}`.trim() : args[0] ?? "";
  if (!READ.has(verb) && !CONFIRM.has(verb) && !SEND.has(verb)) {
    return { refused: `"${verb || "(nothing)"}" isn't allowed by voice. Allowed: ${[...READ, ...SEND, ...CONFIRM].join(", ")}. Hand anything else to Control.` };
  }
  if (verb === "stop" && args.some((a) => a === "--all" || a === "--cwd")) return { refused: "Stop one agent at a time, by id." };
  if (CONFIRM.has(verb) && confirmed !== true) {
    return { refused: `Not done yet. Say exactly what this will do (${verb} on ${name}) and ask ${config.person} to confirm; only after a clear yes, call again with confirmed true.` };
  }
  if (verb === "ls" && !args.includes("-g") && !args.includes("--global")) args.push("-g");
  if (verb === "logs") {
    args = args.filter((a) => a !== "-f" && a !== "--follow");
    const at = args.indexOf("--tail");
    if (at < 0) args.push("--tail", "15");
    else args[at + 1] = String(Math.min(40, Math.max(1, Number(args[at + 1]) || 15)));
  }
  if (verb === "wait") {
    const at = args.indexOf("--timeout");
    if (at < 0) args.push("--timeout", "60");
    else args[at + 1] = String(Math.min(60, Math.max(1, Number(args[at + 1]) || 60)));
  }
  if (verb === "send" && !args.includes("--no-wait")) args.push("--no-wait"); // the reply is read later, never waited on
  return { args: ["--host", address, "--no-color", ...args], verb, name };
}

const fit = (text, tail = false) => (text.length <= 6000 ? text : tail ? `…${text.slice(-6000)}` : `${text.slice(0, 6000)}…`);
const ago = (when) => {
  const minutes = Math.round((Date.now() - Date.parse(when)) / 60_000);
  if (!Number.isFinite(minutes)) return "";
  return minutes < 60 ? `${minutes} min ago` : minutes < 48 * 60 ? `${Math.round(minutes / 60)} h ago` : `${Math.round(minutes / 1440)} days ago`;
};
const short = (text, n) => { const t = String(text ?? "").replace(/\s+/g, " ").trim(); return t.length > n ? `${t.slice(0, n)}…` : t; };

/**
 * The commands asked most, answered over the server's open connection to the daemon: about 0.2 s
 * instead of 1.5 to 4 s for a fresh CLI process. Returns null for anything it doesn't cover.
 */
const FAST = new Set(["ls", "logs", "inspect", "send", "permit ls"]);
async function fast(api, verb, rest, name) {
  if (!FAST.has(verb)) return null;
  const flags = {}, plain = [];
  for (let i = 0; i < rest.length; i += 1) {
    const a = rest[i];
    if (a === "-g" || a === "--global") continue;
    if (a === "--tail" || a === "--label") { (flags[a] ??= []).push(rest[++i]); continue; }
    if (a === "--no-wait") continue;
    if (a.startsWith("-")) return null; // anything else: the CLI knows it
    plain.push(a);
  }
  const all = (await api.agents.list()).entries.map((e) => e.agent);
  const live = all.filter((a) => !a.archivedAt && a.status !== "closed");
  const find = (id) => all.find((a) => a.id === id) ?? all.find((a) => id && a.id.startsWith(id));
  if (verb === "ls") {
    const labels = (flags["--label"] ?? []).map((l) => l.split("="));
    const shown = live.filter((a) => labels.every(([k, v]) => a.labels?.[k] === v))
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
    if (!shown.length) return `No live sessions on ${name}${labels.length ? " with that label" : ""}.`;
    const busy = shown.filter((a) => a.status === "running").length;
    return fit(`${shown.length} live on ${name}, ${busy} running. id | title | model | status | last active\n` +
      shown.map((a) => `${a.id.slice(0, 8)} | ${short(a.title, 90)} | ${a.provider}/${a.model ?? ""} | ${a.status} | ${ago(a.updatedAt)}`).join("\n"));
  }
  const agent = find(plain[0]);
  if (!agent && verb !== "permit ls") return `No session with id "${plain[0] ?? ""}" on ${name}. Find it with ls first.`;
  if (verb === "logs") {
    const tail = Math.min(40, Math.max(1, Number(flags["--tail"]?.[0]) || 15));
    // Tool steps collapse to one line per run, so fetch more than the lines shown.
    const page = await api.agents.ref(agent.id).timeline.refetch({ direction: "tail", limit: Math.min(200, tail * 6), projection: "projected" });
    return fit(digestLogs(agent, page.entries.map((e) => e.item), tail, name), true);
  }
  if (verb === "inspect") {
    return [`${agent.title} (${agent.id})`, `status ${agent.status}${agent.activeTurn ? `, busy since ${ago(agent.activeTurn.startedAt)}` : ""}`,
      `model ${agent.provider}/${agent.model ?? ""}`, `labels ${JSON.stringify(agent.labels ?? {})}`, `started ${ago(agent.createdAt)}, last active ${ago(agent.updatedAt)}`,
      `folder ${agent.cwd}`, `waiting permissions ${agent.pendingPermissions?.length ?? 0}`, agent.lastError ? `last error ${short(JSON.stringify(agent.lastError), 300)}` : ""].filter(Boolean).join("\n");
  }
  if (verb === "send") {
    const text = plain.slice(1).join(" ").trim();
    if (!text) return "Say what to send.";
    await api.agents.ref(agent.id).send(text);
    return `Sent to ${short(agent.title, 80)}. It's ${agent.status === "running" ? "busy, so it reads it as it goes" : "starting on it"}; read its reply later with logs.`;
  }
  if (verb === "permit ls") {
    const waiting = live.flatMap((a) => (a.pendingPermissions ?? []).map((p) => `${a.id.slice(0, 8)} | ${short(a.title, 70)} | ${short(JSON.stringify(p), 300)}`));
    return waiting.length ? fit(waiting.join("\n")) : `No permission requests waiting on ${name}.`;
  }
  return null;
}

/**
 * Runs one allowed Paseo command on a configured host, trimmed for speech. `daemon(address)` gives
 * the server's open connection to that daemon; commands it can't answer go to the Paseo CLI.
 */
export async function paseo(config, request, daemon) {
  const checked = plan(config, request ?? {});
  if (checked.refused) return checked.refused;
  if (daemon) {
    try {
      const address = hostsOf(config)[checked.name];
      const answer = await fast(await daemon(address), checked.verb, checked.args.slice(checked.verb.includes(" ") ? 5 : 4), checked.name);
      if (answer !== null) return answer;
    } catch (error) {
      console.error(`paseo ${checked.verb} over the open connection failed, trying the CLI:`, error.message);
    }
  }
  return cli(config, checked);
}

function cli(config, checked) {
  const timeout = checked.verb === "wait" ? 75_000 : 30_000;
  return new Promise((resolve) => execFile(config.paseo?.bin ?? "paseo", checked.args, { timeout, maxBuffer: 4 << 20 }, (error, stdout, stderr) => {
    const clean = (text) => String(text ?? "").replace(/\x1b\[[0-9;]*m/g, "").trim();
    const out = clean(stdout), err = clean(stderr);
    if (error && !out) return resolve(`paseo ${checked.verb} failed on ${checked.name}: ${(err || error.message).slice(0, 800)}`);
    // Tables are padded to line up on a screen; for a model, one " | " between columns is enough.
    const text = (checked.verb === "logs" ? out : out.replace(/[ \t]{2,}/g, " | ").replace(/ \| $/gm, "")) || err || "Done, no output.";
    resolve(fit(text, checked.verb === "logs"));
  }));
}

// ---- Skills
let cache = null;

/** Skills from the skills folder: name and description from each file's front matter, then the body. */
export function skills(config) {
  const offered = (all) => all.filter((s) => !s.needs || (s.needs === "chief" && chiefOn(config)));
  if (cache) return offered(cache);
  const folder = config.skillsDir ? (isAbsolute(config.skillsDir) ? config.skillsDir : join(HERE, config.skillsDir)) : join(HERE, "skills");
  let files = [];
  try { files = readdirSync(folder).filter((f) => f.endsWith(".md")).sort(); } catch {}
  cache = files.map((file) => {
    const text = readFileSync(join(folder, file), "utf8");
    const match = text.match(/^---\n([\s\S]*?)\n---\n?([\s\S]*)$/);
    const meta = Object.fromEntries((match?.[1] ?? "").split("\n").map((l) => l.match(/^(\w+):\s*(.*)$/)).filter(Boolean).map((m) => [m[1], m[2].trim()]));
    return { name: meta.name || file.replace(/\.md$/, ""), description: meta.description || "", needs: meta.needs || "", body: (match?.[2] ?? text).trim() };
  });
  return offered(cache); // a skill for a feature that's off here ("needs: chief") isn't offered
}

export function skill(config, { name } = {}) {
  const all = skills(config);
  const found = all.find((s) => s.name === String(name ?? "").trim().toLowerCase());
  return found ? found.body : `No skill called "${name}". Skills: ${all.map((s) => s.name).join(", ") || "none"}.`;
}
