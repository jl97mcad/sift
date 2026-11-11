// Memory between calls: a short summary of each call in a dated file, read back at the next call's
// start and searched by the recall tool. Off unless config.memory.dir is set.
import { chmod, mkdir, readdir, readFile, appendFile } from "node:fs/promises";
import { join } from "node:path";
import { key } from "./speech.mjs";
import { cleanText, digestDeja } from "./digest.mjs";
import { run } from "./asks.mjs";

export const remembering = (config) => Boolean(config.memory?.dir);

/** YYYY-MM-DD and HH:MM in the person's timezone. */
export function dayAndTime(when, timeZone) {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-GB", { timeZone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(new Date(when)).map((p) => [p.type, p.value]));
  return { day: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}` };
}

/** Removes anything that looks like a secret: keys, tokens, passwords. */
export function scrub(text) {
  return String(text ?? "")
    .replace(/\b(sk|pk|rk|ghp|gho|github_pat|xox[abp]|AKIA)[-_A-Za-z0-9]{8,}/g, "[redacted]")
    .replace(/\b(password|passcode|pin|token|secret|api key)\b(\s*(is|:|=)\s*)\S+/gi, "$1$2[redacted]")
    .replace(/[A-Za-z0-9+/_=-]{32,}/g, "[redacted]");
}

const STOP = new Set("a an the and or but of to in on at for with about what did we you i me my is it was that this he she they them our your say said tell remind decide decided talk talked".split(" "));
const terms = (text) => String(text ?? "").toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 1 && !STOP.has(w));

/**
 * Lines of the summaries that best match a query: one point per query word found (prefixes count
 * for words of four letters or more), and newer days win ties. files: [{ day, text }].
 */
export function scoreMemory(files, query, limit = 8) {
  const want = [...new Set(terms(query))];
  if (!want.length) return [];
  const hits = [];
  for (const { day, text } of files) {
    let heading = "";
    for (const line of String(text).split("\n")) {
      if (line.startsWith("## ")) { heading = line.slice(3).trim(); continue; }
      const have = terms(line);
      if (!have.length) continue;
      const score = want.filter((w) => have.includes(w) || (w.length >= 4 && have.some((h) => h.startsWith(w) || (h.length >= 4 && w.startsWith(h))))).length;
      if (score) hits.push({ day, heading, line: line.replace(/^\s*[-*]\s*/, "").trim(), score });
    }
  }
  return hits.sort((a, b) => b.score - a.score || b.day.localeCompare(a.day) || b.heading.localeCompare(a.heading)).slice(0, limit);
}

async function files(dir) {
  const names = (await readdir(dir).catch(() => [])).filter((n) => /^\d{4}-\d{2}-\d{2}\.md$/.test(n)).sort();
  return Promise.all(names.map(async (n) => ({ day: n.slice(0, 10), text: await readFile(join(dir, n), "utf8").catch(() => "") })));
}

/** Today's and yesterday's summaries for the start of a call, newest last, capped. */
export async function recentMemory(config, when = Date.now(), cap = 1400) {
  if (!remembering(config)) return "";
  const zone = config.timezone || config.phoneTimezone;
  const today = dayAndTime(when, zone).day;
  const [y, m, d] = today.split("-").map(Number);
  const yesterday = new Date(Date.UTC(y, m - 1, d - 1)).toISOString().slice(0, 10); // the calendar day before, whatever the clocks did
  const parts = [];
  for (const [day, label] of [[yesterday, "Yesterday"], [today, "Today"]]) {
    const text = await readFile(join(config.memory.dir, `${day}.md`), "utf8").catch(() => "");
    if (text.trim()) parts.push(`${label}:\n${text.replace(/^# .*\n/, "").trim()}`);
  }
  const all = parts.join("\n");
  return all.length > cap ? `…${all.slice(-cap)}` : all; // the newest calls matter most
}

/** The recall tool: the local summaries, and the person's deja memory when configured. */
export async function recall(config, { query } = {}) {
  const q = String(query ?? "").replace(/^[\s-]+/, "").trim().slice(0, 300); // never read as a flag
  if (!q) return "Say what to look for.";
  const deja = config.memory?.dejaCommand
    ? run(config.memory.dejaCommand, q, (config.memory.dejaTimeoutSeconds ?? 20) * 1000).then((r) => (r.code === 0 ? digestDeja(r.out) || "Nothing found."
      : `unavailable: deja ${/timed out/.test(r.err) ? `didn't answer within ${config.memory.dejaTimeoutSeconds ?? 20} s` : short(r.err.trim().split("\n").at(-1) || `exit ${r.code}`, 120)}`))
    : Promise.resolve("");
  const local = remembering(config) ? scoreMemory(await files(config.memory.dir), q) : [];
  const lines = [];
  if (remembering(config)) {
    lines.push(local.length ? `From earlier calls:\n${local.map((h) => `- ${h.day}${h.heading ? `, ${h.heading}` : ""}: ${short(h.line, 240)}`).join("\n")}` : `Nothing in earlier calls' notes matches "${q}".`);
  }
  const deep = await deja;
  if (deep) lines.push(`From ${config.person ?? "their"}'s session memory (deja; reference only, may be out of date):\n${deep}`);
  return lines.join("\n\n") || "No memory is set up.";
}

const short = (text, n) => { const t = String(text ?? "").replace(/\s+/g, " ").trim(); return t.length > n ? `${t.slice(0, n)}…` : t; };

/** The call as plain lines for the summary: the person's words and the assistant's, with news notes kept short. */
export function transcriptText(turns, person = "Person") {
  return (turns ?? []).map((t) => {
    const text = cleanText(t.text ?? t.content ?? "");
    if (!text || /^\((The call just connected|Chief-of-staff mode o)/.test(text)) return null;
    if (/^\(Not said by/.test(text)) return `News: ${short(text.replace(/^\(Not said by [^.]*\.\s*/, ""), 600)}`;
    // Chief-of-staff mode: what was sent (or scrapped) is marked, so the note says it went to the chief.
    const chief = text.match(/^\((To chief of staff|Sent to chief of staff|Scrapped, not sent to chief of staff)\)\s*([\s\S]*)$/);
    if (chief) return `${person} (${chief[1].toLowerCase()}): ${short(chief[2], 1200)}`;
    return `${t.role === "user" ? person : "Assistant"}: ${short(text, 1200)}`;
  }).filter(Boolean).map(scrub).join("\n").slice(-12_000); // secrets never leave for the summary model
}

export const SUMMARY_PROMPT = (person) => `You write a short memory note of a voice call between ${person} and their assistant, for the assistant to read at the next call.
Write up to 10 bullet lines starting "- " (fewer for a short call; never pad, and write nothing at all if nothing in the call is worth keeping). Cover, only if present:
- Decisions ${person} made about their work.
- Open asks answered: only those listed below as answered through the tool, never questions the assistant answered.
- Things ${person} explicitly asked the assistant to remember.
- Messages ${person} sent to their chief of staff (lines marked "sent to chief of staff"): one line each, starting "To chief of staff:", with what it replied. Leave out ones marked scrapped.
- Open threads to pick up next time.
Name what each is about (plan numbers, session names). Leave out greetings, small talk and anything said to someone else in the room.
Use only what the transcript says. Never include passwords, keys, tokens or other secrets. No heading, no preamble.`;

/** One cheap model call: the call's summary as bullet lines, or "" when there was nothing to summarise. */
export async function summariseCall(config, turns, extra = "") {
  const text = transcriptText(turns, config.person);
  const who = config.person ?? "Person";
  if (!text.split("\n").some((l) => l.startsWith(`${who}:`) || l.startsWith(`${who} (`))) return "";
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": config.assistant || "Voice assistant" },
    body: JSON.stringify({
      model: config.memory?.model || config.frontModel || "deepseek/deepseek-v4.1-flash", max_tokens: 500, reasoning: { enabled: false },
      messages: [{ role: "system", content: SUMMARY_PROMPT(config.person ?? "the person") }, { role: "user", content: `${text}${extra ? `\n\n${extra}` : ""}` }],
    }),
    signal: AbortSignal.timeout(45_000),
  });
  if (!response.ok) throw new Error(`Summary model failed: HTTP ${response.status}`);
  const data = await response.json();
  return bullets(data.choices?.[0]?.message?.content ?? "");
}

/** At most ten "- " lines, scrubbed. */
export function bullets(text) {
  return String(text).split("\n").map((l) => l.trim()).filter((l) => /^[-*•]\s+\S/.test(l))
    .map((l) => `- ${scrub(l.replace(/^[-*•]\s+/, ""))}`).slice(0, 10).join("\n");
}

/** Appends a call's summary under a heading with its start time, in a 0600 file in a 0700 folder. */
export async function writeMemory(config, started, summary) {
  if (!remembering(config) || !summary.trim()) return null;
  const { day, time } = dayAndTime(started, config.timezone || config.phoneTimezone);
  await mkdir(config.memory.dir, { recursive: true, mode: 0o700 });
  await chmod(config.memory.dir, 0o700); // a folder that already existed keeps its own mode otherwise
  const file = join(config.memory.dir, `${day}.md`);
  const head = (await readFile(file, "utf8").catch(() => "")) ? "" : `# ${day}\n`;
  await appendFile(file, `${head}\n## Call at ${time}\n${summary.trim()}\n`, { mode: 0o600 });
  await chmod(file, 0o600);
  return file;
}
