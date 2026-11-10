// Tool output digested before the model reads it: who, what and when, the latest ask and reply as
// the main lines, tool steps collapsed, shell and JSON noise dropped. Plain code, no model call.

/** "12 min ago", "3 h ago", "2 days ago"; "" when unknown. */
export function ago(when, now = Date.now()) {
  const minutes = Math.round((now - Date.parse(when)) / 60_000);
  if (!Number.isFinite(minutes)) return "";
  return minutes < 60 ? `${Math.max(0, minutes)} min ago` : minutes < 48 * 60 ? `${Math.round(minutes / 60)} h ago` : `${Math.round(minutes / 1440)} days ago`;
}

export const short = (text, n) => { const t = String(text ?? "").replace(/\s+/g, " ").trim(); return t.length > n ? `${t.slice(0, n).replace(/\s+\S*$/, "")}…` : t; };

/**
 * Text a model can read aloud from: no ANSI, code blocks, markup, links, JSON blobs or long ids.
 * keepLines keeps one item per line (for lists like a focus list); otherwise it's one paragraph.
 */
export function cleanText(text, { keepLines = false } = {}) {
  let t = String(text ?? "")
    .replace(/\x1b\[[0-9;]*[A-Za-z]/g, "")
    .replace(/^---\n[\s\S]*?\n---\n/, "") // front matter
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/```[\s\S]*?(```|$)/g, " [code] ")
    .replace(/<\/?[a-z][\w-]*(\s[^>]*)?>/gi, " ") // tags such as <board-runner>; their text stays
    .replace(/\[([^\]]+)\]\((https?:[^)]+)\)/g, "$1")
    .replace(/https?:\/\/\S+/g, "[link]")
    .replace(/\{[^{}]{80,}\}/g, "[data]")
    .replace(/\[[^\[\]]{200,}\]/g, "[data]")
    .replace(/\b[0-9a-f]{12,}\b/gi, "")
    .replace(/`([^`\n]+)`/g, "$1")
    .replace(/(^|[\s(])([`*_]{1,3})([^`*_\n]+?)\2(?=[\s.,;:!?)]|$)/gm, "$1$3")
    .replace(/^#{1,6}\s+/gm, "")
    .replace(/^\s*[-*]\s+\[[ x]\]\s*/gim, "- ")
    .replace(/\*\*/g, "");
  if (keepLines) return t.split("\n").map((l) => l.replace(/[ \t]+/g, " ").trim()).filter(Boolean).join("\n");
  return t.replace(/\s+/g, " ").trim();
}

/** A shell command as its first real command: no "cd somewhere &&", paths cut to their last part. */
export function commandGist(command) {
  const parts = String(command ?? "").split(/\s*(?:&&|;|\|\|)\s*/).map((p) => p.trim()).filter((p) => p && !/^(cd|set|export|source|\.)\s/.test(p));
  return (parts[0] ?? "").replace(/(?:\/[\w.@~-]+){2,}\/([\w.@-]+)/g, "…/$1");
}

/** A tool step in a few words: its name and what it touched. */
function step(item) {
  const d = item.detail ?? {};
  const what = d.command ? commandGist(d.command) : d.path ? String(d.path).split("/").pop() : d.label ?? d.query ?? d.url ?? "";
  return `${item.name}${what ? ` ${short(cleanText(what), 70)}` : ""}`;
}

/** Tool steps as one line: how many, which tools, the last one, and any failures. */
function stepsLine(calls) {
  if (!calls.length) return null;
  const counts = new Map();
  for (const c of calls) counts.set(c.name, (counts.get(c.name) ?? 0) + 1);
  const failed = calls.filter((c) => c.status === "failed").length;
  const names = [...counts].map(([n, k]) => (k > 1 ? `${n} ×${k}` : n)).join(", ");
  return `${calls.length} tool step${calls.length > 1 ? "s" : ""} (${names}), last: ${step(calls.at(-1))}${failed ? `; ${failed} failed` : ""}`;
}

/** The header line for a session: title, status, host, how long busy, last active. */
function header(agent, host, now) {
  const bits = [agent.status ?? "unknown"];
  if (agent.activeTurn?.startedAt) bits.push(`on this turn since ${ago(agent.activeTurn.startedAt, now)}`);
  if (host) bits.push(`on ${host}`);
  if (agent.updatedAt) bits.push(`last active ${ago(agent.updatedAt, now)}`);
  return `${short(agent.title ?? agent.name ?? "Untitled", 110)} (${bits.join(", ")})`;
}

/**
 * read_session: a session's latest ask and its latest reply as the main lines, the tool steps
 * since that ask on one line, and one earlier reply for context. items: timeline items, oldest first.
 */
export function digestSession(agent, items, host, now = Date.now()) {
  const list = (items ?? []).filter(Boolean);
  const lastAsk = list.findLastIndex((i) => i.type === "user_message" && i.text?.trim());
  const replies = list.filter((i) => i.type === "assistant_message" && i.text?.trim());
  const latest = replies.at(-1);
  const lines = [header(agent, host, now)];
  if (lastAsk >= 0) lines.push(`Latest ask: ${short(cleanText(list[lastAsk].text), 300)}`);
  const since = list.slice(lastAsk + 1);
  const steps = stepsLine(since.filter((i) => i.type === "tool_call" && !i.agentMessage));
  const replyAfter = since.filter((i) => i.type === "assistant_message" && i.text?.trim()).at(-1);
  if (replyAfter) lines.push(`Latest reply: ${short(cleanText(replyAfter.text), 600)}`);
  else if (lastAsk >= 0) lines.push(agent.status === "running" ? "No reply to it yet; still working." : "No reply to it.");
  if (steps) lines.push(`Since the ask: ${steps}`);
  const message = since.filter((i) => i.type === "tool_call" && i.agentMessage).at(-1);
  if (message) lines.push(`Message from ${message.agentMessage.sender?.title ?? "a session"}: ${short(cleanText(message.agentMessage.text), 250)}`);
  const earlier = replies.filter((r) => r !== replyAfter).at(-1);
  if (earlier) lines.push(`Earlier reply: ${short(cleanText(earlier.text), 250)}`);
  if (lines.length === 1) lines.push(latest ? `Said: ${short(cleanText(latest.text), 600)}` : "Nothing said yet.");
  return lines.join("\n");
}

/**
 * paseo logs: newest last, consecutive tool steps collapsed to one line, thoughts dropped except
 * the last thing it did, each line trimmed.
 */
export function digestLogs(agent, items, tail = 15, host, now = Date.now()) {
  const out = [];
  let run = [];
  const flush = () => { if (run.length) out.push(`Tools: ${stepsLine(run)}`); run = []; };
  const list = (items ?? []).filter(Boolean);
  const say = (line) => { flush(); out.push(line); }; // skipped items never split a run of steps
  list.forEach((item, n) => {
    if (item.type === "tool_call" && !item.agentMessage) { run.push(item); return; }
    if (item.type === "user_message" && item.text?.trim()) say(`Asked: ${short(cleanText(item.text), 300)}`);
    else if (item.type === "assistant_message" && item.text?.trim()) say(`Said: ${short(cleanText(item.text), 400)}`);
    else if (item.type === "tool_call" && item.agentMessage) say(`Message from ${item.agentMessage.sender?.title ?? "a session"}: ${short(cleanText(item.agentMessage.text), 250)}`);
    else if (item.type === "reasoning" && n === list.length - 1 && item.text?.trim()) say(`Thinking: ${short(cleanText(item.text), 160)}`);
  });
  flush();
  return `${header(agent, host, now)}\n${out.slice(-tail).join("\n") || "Nothing yet."}`;
}

/** Plan number at the start of a title, like JON-4122. */
const planIn = (title) => String(title ?? "").match(/^\s*([A-Z]{2,10}-\d+)/)?.[1];

/**
 * sessions: per host, the counts, the seats, what's running and the idle plan leads; the rest as a
 * count. hosts: [{ name, agents | error }]. compact gives the short form for the start of a call.
 */
export function digestSessions(hosts, { compact = false, now = Date.now() } = {}) {
  const lines = [];
  hosts = (hosts ?? []).map((h) => ({ ...h, agents: h.agents?.map((a) => ({ ...a, title: cleanText(a.title ?? a.name ?? "") })) }));
  const width = compact ? 55 : 80;
  for (const { name, agents, error } of hosts ?? []) {
    if (error) { lines.push(`On ${name}: unavailable (${short(error, 120)})`); continue; }
    const live = [...(agents ?? [])].sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
    const running = live.filter((a) => a.status === "running");
    lines.push(`On ${name}: ${live.length} live, ${running.length} running.`);
    const seats = live.filter((a) => a.labels?.seat);
    // The short form (start of a call) leaves out ids and seat titles: read_session finds a session by name.
    const id = (a) => (compact ? "" : `${a.id.slice(0, 8)} `);
    if (seats.length) lines.push(`Seats: ${seats.map((a) => `${a.labels.seat} ${id(a)}${a.status}${a.status === "running" ? "" : `, ${ago(a.updatedAt, now)}`}${compact ? "" : ` "${short(a.title, 70)}"`}`).join("; ")}`);
    const rest = running.filter((a) => !a.labels?.seat);
    const most = compact ? 10 : 20;
    if (rest.length) lines.push(`Running: ${rest.slice(0, most).map((a) => `${id(a)}${short(a.title, width)}`).join("; ")}${rest.length > most ? `; and ${rest.length - most} more` : ""}`);
    const leads = live.filter((a) => a.status !== "running" && !a.labels?.seat && (a.labels?.role === "lead" || /\blead\b/i.test(a.title ?? "")) && planIn(a.title));
    if (leads.length) lines.push(`Idle plan leads: ${compact ? leads.slice(0, 15).map((a) => planIn(a.title)).join(", ") : leads.slice(0, 15).map((a) => `${id(a)}${short(a.title, width)}`).join("; ")}${leads.length > 15 ? `; and ${leads.length - 15} more` : ""}`);
    const others = live.length - seats.length - rest.length - leads.length;
    if (others > 0) lines.push(`Other idle sessions: ${others}${compact ? "" : `: ${live.filter((a) => a.status !== "running" && !a.labels?.seat && !leads.includes(a)).slice(0, 12).map((a) => `${a.id.slice(0, 8)} ${short(a.title, 50)}`).join("; ")}`}`);
  }
  return lines.join("\n") || "No live sessions.";
}

/** deja's output (recall or search) with the ids, file lists and commands dropped: each hit's place, date and gist. */
export function digestDeja(text, cap = 1500) {
  const out = [];
  let kept = 0;
  for (const raw of String(text ?? "").split("\n")) {
    const line = raw.trim();
    if (!line || /^<\/?deja/.test(line) || /^(deja:|\(answering from)/.test(line) || /^(Recalled history|No session matched|ranked by|\[relevance\])/.test(line)) continue;
    if (/^(files it touched|it ran|what this session concluded)/.test(line)) continue;
    const hit = line.match(/^(?:\d+\.\s*)?\[(\w+)\]\s+([^·]+)·.*?(?:updated\s+)?(\d{4}-\d{2}-\d{2}|[A-Z][a-z]{2} \d{1,2})/);
    if (hit) { out.push(`* ${hit[2].trim().replace(/^imported:/, "")}, ${hit[3]}:`); kept = 0; continue; }
    const body = cleanText(line.replace(/^[-→…]+\s*/, "").replace(/…$/, ""));
    if (body.length > 20 && kept < 2) { out.push(`  ${short(body, 220)}`); kept += 1; }
  }
  const all = out.join("\n");
  return all.length > cap ? `${all.slice(0, cap)}…` : all;
}

/**
 * The block of things already read at the start of a call. Each part is capped so the whole stays
 * under about 1,500 tokens. parts: { at, needs, sessions, sources: [{ name, text }], memory }.
 */
export function contextBlock({ at, needs, sessions, sources = [], memory, person = "the person" }, cap = 6000) {
  const fit = (text, n) => { const t = String(text ?? "").trim(); return t.length > n ? `${t.slice(0, n).replace(/\s+\S*$/, "")}…` : t; };
  const last = (text, n) => { const t = String(text ?? "").trim(); return t.length > n ? `…${t.slice(-n)}` : t; }; // the newest notes are at the end
  const parts = [`Already read for this call, at ${at}. This is a snapshot from the start of the call: answer from it straight away, without a tool. If ${person} asks for the latest, for detail, or something may have changed since, read again with the tools.`];
  if (needs) parts.push(`Open questions waiting for ${person} (the needs queue):\n${fit(needs, 1600)}`);
  if (sessions) parts.push(`Sessions:\n${fit(sessions, 1400)}`);
  const each = sources.length ? Math.floor(1800 / sources.length) : 0;
  for (const s of sources) if (s.text) parts.push(`${s.name}:\n${fit(cleanText(s.text, { keepLines: true }), each)}`);
  if (memory) parts.push(`Notes from earlier calls (yours, written after each call):\n${last(memory, 1200)}`);
  const block = parts.join("\n\n");
  return block.length > cap ? `${block.slice(0, cap)}…` : block;
}
