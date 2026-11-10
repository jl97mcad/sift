// Sift's own deeper reading: read-only tools (Linear plans, GitHub PRs, vault notes, server status, the web)
// and a short background look that chains them on a cheap model. Nothing here writes, sends or changes anything.
// Everything it returns is scrubbed of secrets and personal fields before the model, the speech or a log sees it.
import { execFile } from "node:child_process";
import { readFile, realpath, stat } from "node:fs/promises";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { resolve, sep } from "node:path";
import { loadavg, uptime } from "node:os";
import { scrub } from "./memory.mjs";
import { key } from "./speech.mjs";

export const reading = (config) => Boolean(config.reader);
const cap = (text, n = 4000) => (text.length > n ? `${text.slice(0, n)}…` : text);

// ---- Guards
/** Secrets, plus the personal fields a spoken answer or a log must never carry: emails, phone numbers, card-like numbers. */
export function clean(text) {
  return scrub(String(text ?? ""))
    .replace(/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)/g, "[redacted]")
    .replace(/\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{8,}/gi, "$1 [redacted]")
    .replace(/[\w.+-]+@[\w-]+(\.[\w-]+)+/g, "[email]")
    .replace(/(?<![\w.])\+?\d[\d ()-]{8,}\d(?![\w])/g, (m) => (/^\d{4}-\d{2}-\d{2}/.test(m) || m.replace(/\D/g, "").length < 9 ? m : "[number]"));
}

/** True for any path with a "God session" segment: any case, odd spacing, encoded, or with a backslash. */
export function isGodSession(path) {
  let text = String(path ?? "");
  for (let i = 0; i < 3; i += 1) { try { text = decodeURIComponent(text); } catch { break; } }
  return text.normalize("NFKC").split(/[\\/]+/).some((part) => /god[\s_-]*session/i.test(part.replace(/[​-‏­﻿]/g, "")));
}

const run = (bin, args, { timeout = 25_000, env = {}, cwd } = {}) => new Promise((done) =>
  execFile(bin, args, { timeout, maxBuffer: 2 << 20, cwd, env: { ...process.env, ...env, NO_COLOR: "1" } }, (error, stdout, stderr) =>
    done(error && !stdout ? `failed: ${String(stderr || error.message).slice(0, 300)}` : String(stdout).trim() || "(empty)")));

// ---- Linear plans: read only, with the board app's cached token (never a personal key, never refreshed here)
async function linear(config, query, variables) {
  if (!/^\s*query\b/.test(query)) throw new Error("Only reads are allowed.");
  const file = config.reader?.linearTokenFile;
  if (!file) return null;
  const token = JSON.parse(await readFile(file, "utf8"));
  if (!token.access_token || token.expires_at - Date.now() / 1000 < 60) throw new Error("the board's Linear token needs renewing");
  const response = await fetch("https://api.linear.app/graphql", {
    method: "POST", headers: { Authorization: `Bearer ${token.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query, variables }), signal: AbortSignal.timeout(15_000),
  });
  const data = await response.json();
  if (!response.ok || data.errors) throw new Error(`Linear said ${response.status} ${JSON.stringify(data.errors ?? "").slice(0, 200)}`);
  return data.data;
}
const day = (when) => String(when ?? "").slice(0, 10);

export async function linearPlan(config, { id } = {}) {
  const plan = String(id ?? "").trim().toUpperCase();
  if (!/^[A-Z]{2,6}-\d{1,6}$/.test(plan)) return "Say the plan number like JON-123.";
  const data = await linear(config, `query($id:String!){issue(id:$id){identifier title url state{name} priority labels{nodes{name}} description updatedAt
    parent{identifier title} children(first:10){nodes{identifier title state{name}}}
    comments(last:4){nodes{body createdAt}} attachments(first:6){nodes{title url}}}}`, { id: plan });
  if (data === null) return "Linear isn't set up for reading.";
  const i = data.issue;
  if (!i) return `No plan ${plan}.`;
  return clean([`${i.identifier}: ${i.title}. State ${i.state?.name}, updated ${day(i.updatedAt)}.${i.labels.nodes.length ? ` Labels: ${i.labels.nodes.map((l) => l.name).join(", ")}.` : ""}`,
    i.parent ? `Part of ${i.parent.identifier} ${i.parent.title}.` : "",
    i.children.nodes.length ? `Sub-plans: ${i.children.nodes.map((c) => `${c.identifier} ${c.title} (${c.state?.name})`).join("; ")}` : "",
    i.attachments.nodes.length ? `Linked: ${i.attachments.nodes.map((a) => a.title).join("; ")}` : "",
    `Description: ${cap(i.description ?? "(none)", 1800)}`,
    ...i.comments.nodes.map((c) => `Comment ${day(c.createdAt)}: ${cap(c.body, 500)}`)].filter(Boolean).join("\n"));
}

export async function linearSearch(config, { query } = {}) {
  if (!String(query ?? "").trim()) return "Say what to search the plans for.";
  const data = await linear(config, `query($t:String!){searchIssues(term:$t, first:8){nodes{identifier title state{name} updatedAt}}}`, { t: String(query).slice(0, 200) });
  if (data === null) return "Linear isn't set up for reading.";
  const hits = data.searchIssues.nodes;
  return clean(hits.length ? hits.map((i) => `${i.identifier}: ${i.title} (${i.state?.name}, ${day(i.updatedAt)})`).join("\n") : `No plans match "${query}".`);
}

// ---- GitHub: pull requests and their checks, read only (list, view, checks)
const REPO = /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/;
export async function github(config, { action, repo, number, state } = {}) {
  const target = repo || config.reader?.github?.repos?.[0];
  if (!target || !REPO.test(target)) return `Say which repository, like owner/name. Known: ${(config.reader?.github?.repos ?? []).join(", ") || "none"}.`;
  const n = Number(number);
  const env = config.reader?.github?.home ? { HOME: config.reader.github.home } : {};
  if (action === "list") {
    const out = await run("gh", ["pr", "list", "-R", target, "--state", ["open", "closed", "merged", "all"].includes(state) ? state : "open", "--limit", "12",
      "--json", "number,title,isDraft,updatedAt,headRefName,reviewDecision,mergedAt"], { env });
    return clean(cap(out));
  }
  if (!Number.isInteger(n) || n < 1) return "Say the pull request number.";
  if (action === "view") {
    return clean(cap(await run("gh", ["pr", "view", String(n), "-R", target, "--json",
      "number,title,state,isDraft,mergeable,reviewDecision,headRefName,updatedAt,mergedAt,additions,deletions,changedFiles,statusCheckRollup,body"], { env })));
  }
  if (action === "checks") return clean(cap(await run("gh", ["pr", "checks", String(n), "-R", target], { env })));
  return "Action is list, view or checks.";
}

// ---- The vault: search through recall-service, read one note by path. The God session folder is never touched.
export async function vault(config, { action, query, path } = {}) {
  const conf = config.reader?.vault;
  if (!conf) return "The vault isn't set up for reading.";
  if (action === "read") {
    if (!path || isGodSession(path)) return "That isn't available.";
    const root = await realpath(conf.root ?? "/srv/vault");
    const wanted = resolve(root, String(path).replace(/^\/+/, "").replace(root, "").replace(/^\/+/, ""));
    if (isGodSession(wanted) || !/\.(md|txt)$/i.test(wanted)) return "That isn't available.";
    let real;
    try { real = await realpath(wanted); } catch { return "No such note."; }
    if (!real.startsWith(root + sep) || isGodSession(real) || !(await stat(real)).isFile()) return "That isn't available."; // a link out is refused too
    return clean(cap(await readFile(real, "utf8"), 6000));
  }
  if (!String(query ?? "").trim()) return "Say what to search the vault for.";
  const token = (await readFile(conf.tokenFile, "utf8")).trim();
  const response = await fetch(`${conf.url}/v1/recall`, {
    method: "POST", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ query: String(query).slice(0, 300), scope: "vault", limit: 8 }), signal: AbortSignal.timeout(40_000),
  });
  if (!response.ok) return `The vault search failed: HTTP ${response.status}.`;
  const hits = ((await response.json()).hits ?? []).filter((h) => !isGodSession(h.path) && !isGodSession(h.snippet));
  return clean(hits.length ? hits.slice(0, 6).map((h) => `${String(h.path).replace(/^\/srv\/vault\//, "")} (${h.lines}): ${cap(String(h.snippet ?? ""), 400)}`).join("\n") : "Nothing in the vault matches.");
}

// ---- Server status: load, disk, services and a few configured status files and read-only commands
export async function serverStatus(config) {
  const conf = config.reader?.status ?? {};
  const lines = [`Load ${loadavg().map((x) => x.toFixed(1)).join(" ")}, up ${Math.round(uptime() / 3600)} h.`];
  lines.push(`Disk: ${(await run("df", ["-h", "--output=target,size,used,pcent", "/"])).split("\n").slice(1).join("; ")}`);
  if (conf.services?.length) lines.push(`Services: ${(await run("systemctl", ["is-active", ...conf.services])).split("\n").map((s, i) => `${conf.services[i]} ${s}`).join(", ")}`);
  for (const file of conf.files ?? []) lines.push(`${file.name}: ${cap(await readFile(file.path, "utf8").then((t) => t.trim(), () => "unavailable"), file.chars ?? 500)}`);
  for (const command of conf.commands ?? []) lines.push(`${command.name}: ${cap(await run(command.argv[0], command.argv.slice(1), { env: command.env, cwd: command.cwd }), 500)}`);
  return clean(lines.join("\n"));
}

// ---- The web: a search through OpenRouter's web plugin, and fetching one public page
const blocked = (address) => /^(127\.|10\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|::|fc|fd|fe80)/i.test(address);
async function publicUrl(text) {
  const url = new URL(text);
  if (!/^https?:$/.test(url.protocol) || url.username || url.password) throw new Error("Only plain web addresses.");
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const addresses = isIP(host) ? [{ address: host }] : await lookup(host, { all: true });
  if (!addresses.length || addresses.some((a) => blocked(a.address))) throw new Error("That address isn't public.");
  return url;
}
export async function web(config, { action, query, url } = {}) {
  if (action === "fetch") {
    let page = await publicUrl(url);
    for (let hop = 0; hop < 4; hop += 1) {
      const response = await fetch(page, { redirect: "manual", headers: { "User-Agent": "SiftVoiceReader/1 (read-only)" }, signal: AbortSignal.timeout(12_000) });
      if (response.status >= 300 && response.status < 400 && response.headers.get("location")) { page = await publicUrl(new URL(response.headers.get("location"), page).href); continue; }
      if (!response.ok) return `The page answered HTTP ${response.status}.`;
      const raw = (await response.text()).slice(0, 600_000);
      const text = raw.replace(/<(script|style|noscript|svg)[\s\S]*?<\/\1>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
      return clean(cap(text, 5000));
    }
    return "Too many redirects.";
  }
  if (!String(query ?? "").trim()) return "Say what to search the web for.";
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST", headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json" },
    body: JSON.stringify({ model: readerModel(config), max_tokens: 500, reasoning: { enabled: false }, plugins: [{ id: "web", max_results: 4 }],
      messages: [{ role: "user", content: `Search the web and answer in under 120 words, naming the sources: ${String(query).slice(0, 300)}` }] }),
    signal: AbortSignal.timeout(40_000),
  });
  if (!response.ok) return `The web search failed: HTTP ${response.status}.`;
  return clean((await response.json()).choices?.[0]?.message?.content ?? "No answer.");
}

// ---- The tools as the models see them
const fn = (name, description, properties = {}, required = []) => ({ type: "function", function: { name, description, parameters: { type: "object", properties, required } } });
const str = (description) => ({ type: "string", description });
export const READ_TOOLS = [
  fn("plan", "Read one Linear plan: state, description, sub-plans, linked PRs and latest comments.", { id: str("The plan number, e.g. JON-123.") }, ["id"]),
  fn("plan_search", "Search Linear plans by words in the title or description.", { query: str("Words to search for.") }, ["query"]),
  fn("github", "Read GitHub pull requests: action list (open ones in a repo), view (one PR with its check results) or checks (its CI results). Read only.",
    { action: { type: "string", enum: ["list", "view", "checks"] }, repo: str("owner/name; the default repository if left out."), number: { type: "integer" }, state: { type: "string", enum: ["open", "closed", "merged", "all"] } }, ["action"]),
  fn("vault", "Search the person's notes (action search, with query) or read one note (action read, with a path from a search result).",
    { action: { type: "string", enum: ["search", "read"] }, query: str("Words to search for."), path: str("A note's path, as a search result gave it.") }, ["action"]),
  fn("server_status", "The server's load, disk, services, runner, deploy and main state."),
  fn("web", "The web: action search (with query) or fetch (with the page's address). Read only.",
    { action: { type: "string", enum: ["search", "fetch"] }, query: str("What to search for."), url: str("The page address.") }, ["action"]),
];
export const READ_HANDLERS = (config) => ({
  plan: (a) => linearPlan(config, a), plan_search: (a) => linearSearch(config, a), github: (a) => github(config, a),
  vault: (a) => vault(config, a), server_status: () => serverStatus(config), web: (a) => web(config, a),
});
export const LOOK_TOOL = fn("look_into", "Start a short background read of your own when they ask you to look into, dig into or find out about something that needs more than one lookup. You keep talking; the answer is spoken when it's ready. Use it before handing anything to a worker, unless the task changes or sends something.",
  { question: str("What to find out, in full: resolve 'that' and 'it' to the actual plan, PR, note or topic from the conversation.") }, ["question"]);

const LABEL = { plan: "reading that plan", plan_search: "searching the plans", github: "checking GitHub", vault: "looking through your notes", server_status: "checking the server",
  web: "checking the web", sessions: "looking at the sessions", read_session: "reading a session", read_source: "reading your lists", recall: "searching memory" };

export const readerModel = (config) => config.reader?.model ?? "deepseek/deepseek-v4-flash";

// ---- The look: a few read-only steps on a cheap model
/**
 * Chains read tools to answer one question. Capped by steps (default 6 model calls) and time (default 75 s),
 * with every result clamped and scrubbed. onStep(words) says what it's checking; returns the answer text.
 */
export async function look(config, question, { handlers: more = {}, tools: moreTools = [] } = {}, onStep) {
  const { maxSteps = 6, maxSeconds = 75 } = config.reader ?? {};
  const handlers = { ...READ_HANDLERS(config), ...more }; // more: sessions, read_session, read_source, recall (the server's own readers)
  const tools = [...READ_TOOLS, ...moreTools];
  const deadline = Date.now() + maxSeconds * 1000;
  const messages = [{ role: "system", content: `You read things for ${config.person} and report back by voice. ${config.about ?? ""}
Use the tools to find the answer, read-only. Prefer one or two precise lookups; stop when you can answer. Say only what the tools returned; if something couldn't be read, say that.
Final answer: plain spoken sentences, at most 60 words, no lists, markdown, ids or links. Never include secrets, emails or phone numbers.` }, { role: "user", content: String(question).slice(0, 800) }];
  let tokens = 0, steps = 0;
  for (; steps <= maxSteps; steps += 1) {
    const last = steps === maxSteps || Date.now() > deadline;
    const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST", headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": "Sift reader" },
      body: JSON.stringify({ model: readerModel(config), max_tokens: 500, reasoning: { enabled: false }, ...(last ? {} : { tools }), messages }),
      signal: AbortSignal.timeout(Math.max(5_000, Math.min(30_000, deadline - Date.now() + 8_000))),
    });
    if (!response.ok) throw new Error(`Reader model failed: HTTP ${response.status}`);
    const data = await response.json();
    tokens += data.usage?.total_tokens ?? 0;
    const message = data.choices?.[0]?.message ?? {};
    if (!message.tool_calls?.length || last) {
      console.log(`look finished: ${steps} steps, ${tokens} tokens`);
      return clean(message.content?.trim() || "I couldn't find an answer.");
    }
    messages.push({ role: "assistant", content: message.content ?? null, tool_calls: message.tool_calls });
    const calls = message.tool_calls.slice(0, 3);
    for (const name of new Set(calls.map((c) => c.function.name))) onStep?.(LABEL[name] ?? "looking");
    const results = await Promise.all(calls.map(async (call) => {
      let args = {};
      try { args = JSON.parse(call.function.arguments || "{}"); } catch {}
      const handler = tools.some((t) => t.function.name === call.function.name) && handlers[call.function.name];
      try { return handler ? clean(cap(String(await handler(args)), 4000)) : "Unknown tool."; } catch (error) { return `That didn't work: ${clean(error.message)}`; }
    }));
    calls.forEach((call, i) => messages.push({ role: "tool", tool_call_id: call.id, content: results[i] }));
    message.tool_calls.slice(3).forEach((call) => messages.push({ role: "tool", tool_call_id: call.id, content: "Skipped: ask for fewer at once." }));
  }
}
