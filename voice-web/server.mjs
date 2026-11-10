// A tailnet-only voice assistant you just talk to. A fast front model holds the conversation;
// real work goes to the person's worker Paseo sessions in the background, and news is spoken when ready.
// Listens on 127.0.0.1 only; `tailscale serve` puts it on the tailnet over HTTPS.
// Person-specific settings live in config.json (see config.example.json), so anyone can run one.
import { createServer } from "node:http";
import { appendFile, readFile } from "node:fs/promises";
import { execFile } from "node:child_process";
import { createPaseoApi } from "@getpaseo/client";
import { createHostClient } from "@getpaseo/client/node";
import { writeFile, chmod, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { isPhantom, looksUnfinished, pieces, plain, progressLine, settledLength, speakPiece, stepLabel, transcribe } from "./speech.mjs";
import { respond, summarise, systemPrompt, toolsFor, workersOf } from "./front.mjs";
import { paseo, skill } from "./tools.mjs";
import { contextBlock, digestSession, digestSessions } from "./digest.mjs";
import { answerAsk, answering } from "./asks.mjs";
import { recall, recentMemory, remembering, summariseCall, writeMemory } from "./memory.mjs";

const PORT = Number(process.env.PORT ?? 8771);
// The Pipecat bot (pipecat/bot.py): the page's WebRTC offer goes to it; it calls the tools on BOT_PORT.
const PIPECAT = process.env.PIPECAT_URL ?? "http://127.0.0.1:8774";
const BOT_PORT = Number(process.env.BOT_PORT ?? 8773); // 127.0.0.1 only and never served on the tailnet
const MAX_AUDIO = 20 * 1024 * 1024;
const config = JSON.parse(await readFile(new URL("./config.json", import.meta.url), "utf8").catch(() =>
  readFile(new URL("./config.example.json", import.meta.url), "utf8")));
const page = await readFile(new URL("./index.html", import.meta.url));
const LOCAL = "tcp://127.0.0.1:6767";
/** The page's heading and home-screen name: config.title, else the assistant's name, else "Voice". */
const title = () => config.title || config.assistant || "Voice";
const clients = new Map(); // one Paseo connection per daemon, opened on first use and kept open
/** The open connection for a Paseo host address; a bare host:port means TCP. */
const open = (address) => daemon(/^\w+:\/\//.test(address) ? address : `tcp://${address}`);

/**
 * A Paseo daemon by any address the Paseo CLI takes: host:port, tcp://, ws://, or a relay://
 * pairing address (how the server reaches a laptop that's off the tailnet or asleep).
 */
async function daemon(url = LOCAL) {
  const address = url.startsWith("ws://") ? `tcp://${new URL(url).host}` : url;
  if (!clients.has(address)) {
    const host = createHostClient(address, { clientId: "voice-front-door", connectTimeoutMs: 15_000 });
    clients.set(address, host.connect().then(() => createPaseoApi(host)).catch((error) => { clients.delete(address); throw error; }));
  }
  return clients.get(address);
}

/**
 * A worker that isn't a Paseo session (OpenClaw, say): a configured command gets the prompt in a
 * file whose path replaces {file}, and its output is the reply. Delivery to chat channels is the
 * command's choice; OpenClaw's `agent` only replies to the caller unless --deliver is passed.
 */
/** The reply text inside a command's JSON, wherever it sits (OpenClaw nests it as terminalReply.text). */
function replyIn(value) {
  if (!value || typeof value !== "object") return null;
  if (typeof value.terminalReply?.text === "string") return value.terminalReply.text;
  if (typeof value.finalAssistantMessageRawText === "string") return value.finalAssistantMessageRawText;
  if (typeof value.reply === "string") return value.reply;
  for (const child of Object.values(value)) {
    const found = replyIn(child);
    if (found) return found;
  }
  return null;
}

async function runCommand(worker, prompt) {
  // A fresh unlistable folder: no guessable path to plant a link at, no clash between jobs.
  const folder = await mkdtemp(join(tmpdir(), "voice-task-"));
  await chmod(folder, 0o711); // the command may run as another user: it can open the file, not list the folder
  const file = join(folder, "task.txt");
  await writeFile(file, prompt, { flag: "wx", mode: 0o644 });
  const quoted = `'${file.replaceAll("'", "'\\''")}'`;
  try {
    const stdout = await new Promise((resolve, reject) => execFile("/bin/sh", ["-c", worker.command.replaceAll("{file}", quoted)],
      { timeout: (worker.timeoutMinutes ?? 10) * 60_000, maxBuffer: 4 << 20 }, (error, out) => (error ? reject(error) : resolve(out))));
    // The JSON may follow log lines; take it from the first "{" to the last "}".
    const json = stdout.slice(stdout.indexOf("{"), stdout.lastIndexOf("}") + 1);
    try {
      const reply = replyIn(JSON.parse(json));
      if (reply) return reply.trim();
    } catch {}
    return stdout.trim().split("\n").slice(-20).join("\n"); // never read out a whole log
  } finally {
    await rm(folder, { recursive: true, force: true }).catch(() => {});
  }
}

const history = [];
const jobs = [];
const listeners = new Set();
let conversation = Promise.resolve(); // one turn or job summary at a time touches the history
const queues = new Map(); // each worker session takes one task at a time
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const serial = (fn) => (conversation = conversation.then(fn, fn));

const bots = new Set(); // open Pipecat calls; while one is open, news is spoken inside the call

/** News for the person: spoken inside an open call, or as a clip the page plays when no call is open. */
async function tell(text) {
  if (bots.size) { toBots({ type: "progress", text }); return broadcast({ type: "say", text }); }
  broadcast({ type: "say", text, audio: await voice(text) });
}
function toBots(event) {
  const line = `data: ${JSON.stringify(event)}\n\n`;
  for (const bot of bots) {
    try { bot.write(line); } catch { bots.delete(bot); }
  }
}

function broadcast(event) {
  const line = `data: ${JSON.stringify(event)}\n\n`;
  for (const listener of listeners) {
    try { listener.write(line); } catch { listeners.delete(listener); }
  }
}

/** Speech for some text, one clip per piece, in order. */
async function voice(text) {
  const clips = await Promise.all(pieces(plain(text)).map((piece) => speakPiece(piece).catch(() => null)));
  return clips.filter(Boolean);
}

/** A worker's live session, looked up fresh each time: by seat label, or for a plan lead by plan number. */
async function session(worker, plan) {
  const client = await daemon(worker.url);
  const { entries } = await client.agents.list();
  const live = entries.map((e) => e.agent).filter((a) => a.status !== "closed" && !a.archivedAt && !/retired/i.test(a.title ?? a.name ?? ""));
  const found = worker.lead
    ? live.filter((a) => plan && new RegExp(`^${plan.replace(/[^A-Za-z0-9-]/g, "")}\\b.*\\blead\\b`, "i").test(a.title ?? a.name ?? ""))
    : worker.title ? live.filter((a) => new RegExp(worker.title, "i").test(a.title ?? a.name ?? "")) // a session with no seat label, by its title
    : live.filter((a) => a.labels?.seat === worker.seat);
  if (!found.length) throw new Error(worker.lead ? `No lead session is running for ${plan || "that plan"}.` : `The ${worker.name} session is not running.`);
  return { client, agent: found.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0] };
}

const view = (job) => ({ id: job.id, task: job.task, to: job.to, status: job.status, steps: job.steps.slice(-4), reply: job.reply, started: job.started });

function delegate({ task, to, plan }, heard) {
  const workers = workersOf(config);
  const worker = workers.find((w) => w.name === to) ?? (workers.length === 1 ? workers[0] : null);
  if (!worker) return `There's no session called "${to}". Choose one of: ${workers.map((w) => w.name).join(", ")}.`; // never the wrong one
  // SIFT_DRY_DELEGATE=1 (for test calls): nothing is handed to anyone; the hand-off is only logged.
  if (/^(1|true|yes)$/i.test(process.env.SIFT_DRY_DELEGATE ?? "")) {
    console.log(`delegate DRY RUN, nothing sent: to ${worker.name}${plan ? ` (${plan})` : ""}: ${String(task ?? "").slice(0, 200)}`);
    return `Started: ${worker.name} is on it. Its result will be spoken when it's ready.`;
  }
  const job = { id: `job-${Date.now()}`, task: task?.trim() || heard, to: worker.lead && plan ? `the ${plan} lead` : worker.name, worker, plan, status: "queued", steps: [], reply: "", started: Date.now() };
  jobs.push(job);
  jobs.splice(0, Math.max(0, jobs.length - 20));
  broadcast({ type: "job", job: view(job) });
  const key = worker.lead ? `lead:${plan}` : worker.name;
  queues.set(key, (queues.get(key) ?? Promise.resolve()).then(() => run(job)).catch((error) => console.error("job failed", error)));
  return `Started: ${job.to} is on it. Its result will be spoken when it's ready.`;
}

/** The open questions waiting for the person, from the configured command (prints text or JSON). */
function needsQueue() {
  if (!config.needs?.command) return Promise.resolve("No needs queue is set up for this person.");
  return new Promise((resolve) => execFile("/bin/sh", ["-c", config.needs.command], { timeout: 15_000, maxBuffer: 1 << 20 },
    (error, stdout) => resolve(error ? `The needs queue couldn't be read: ${error.message}` : (stdout.trim() || "Nothing is waiting.").slice(0, 3000))));
}

// ---- Reading directly: answers in seconds, without asking another session.
const titleOf = (a) => a.title ?? a.name ?? "";
const bare = (address) => (/^\w+:\/\//.test(address) ? address : `tcp://${address}`).replace(/^ws:\/\/([^/]+).*$/, "tcp://$1");
/** Every daemon to read: the named Paseo hosts, then any worker's daemon they don't cover. */
function daemonsOf() {
  const seen = new Map();
  for (const [name, address] of Object.entries(config.paseo?.hosts ?? {})) seen.set(bare(address), name);
  for (const w of workersOf(config)) if (w.url && !seen.has(bare(w.url))) seen.set(bare(w.url), w.name);
  return [...seen].map(([url, name]) => ({ url, name }));
}
/** Sessions on a daemon that aren't archived; "closed" ones (stopped but resumable) only when asked for. */
async function liveOn(url, { closed = false } = {}) {
  const { entries } = await (await daemon(url)).agents.list();
  return entries.map((e) => e.agent).filter((a) => (closed || a.status !== "closed") && !a.archivedAt && !/retired/i.test(titleOf(a)));
}

// Spoken names against written titles: "sift two" is "Sift 2", "W01 4660" is "W01-4660".
const NUMBERS = Object.fromEntries("zero one two three four five six seven eight nine ten eleven twelve".split(" ").map((w, i) => [w, String(i)]));
const FILLER = new Set(["the", "my", "a", "an", "on", "in", "of", "s", "session", "sessions", "agent", "chat", "one's", "pro"]);
const tokens = (text) => String(text ?? "").toLowerCase().replace(/[^a-z0-9]+/g, " ").split(" ").filter(Boolean).map((w) => NUMBERS[w] ?? w);
function score(want, agent) {
  const have = [...tokens(titleOf(agent)), ...tokens(agent.labels?.seat)];
  const hits = want.filter((w) => have.includes(w) || (w.length >= 4 && have.some((h) => h.startsWith(w) || w.startsWith(h) && h.length >= 4)));
  return want.length ? hits.length / want.length : 0;
}

/** Live sessions on every daemon, read at once and digested: counts, seats, what's running, idle plan leads. */
async function sessions({ compact = false } = {}) {
  const hosts = await Promise.all(daemonsOf().map(async ({ url, name }) => {
    try { return { name, agents: await liveOn(url) }; } catch (error) { return { name, error: error.message }; }
  }));
  return digestSessions(hosts, { compact });
}

/** A session's latest ask and reply, with its steps since collapsed to a line. */
async function said(client, agent, host) {
  const page = await client.agents.ref(agent.id).timeline.refetch({ direction: "tail", limit: 80, projection: "projected" });
  return digestSession(agent, page.entries.map((e) => e.item), host);
}

/** The latest prompts and replies of the session that best matches the name, on any host. */
async function readSession({ name }) {
  const asked = String(name ?? "").toLowerCase().trim();
  if (!asked) return "Say which session to read.";
  // A configured worker's name ("Control") means that worker's session, however it's found.
  const worker = workersOf(config).find((w) => !w.lead && !w.command && w.name.toLowerCase() === asked);
  if (worker) {
    try {
      const { client, agent } = await session(worker);
      return await said(client, agent);
    } catch (error) { return error.message; }
  }
  let want = tokens(asked).filter((w) => !FILLER.has(w));
  // "on my MacBook": a host's name in the request means that host only.
  let hosts = daemonsOf();
  const named = hosts.filter((h) => { const t = tokens(h.name); return t.length && t.every((w) => want.includes(w)); });
  if (named.length) { hosts = named; const drop = new Set(named.flatMap((h) => tokens(h.name))); want = want.filter((w) => !drop.has(w)) ; }
  if (!want.length) return `Say which session on ${hosts.map((h) => h.name).join(" or ")}.`;
  let best = null;
  const failed = [];
  for (const { url, name: host } of hosts) {
    try {
      for (const agent of await liveOn(url, { closed: true })) {
        // Ties go to a current session (not an "old" one or one that hit its limit), then an open one, then the most recently active.
        const s = score(want, agent) - (/\bold\b|\blimit\b|handoff from|superseded/i.test(titleOf(agent)) ? 0.01 : 0) - (agent.status === "closed" ? 0.005 : 0);
        if (s > 0 && (!best || s > best.s || (s === best.s && String(agent.updatedAt) > String(best.agent.updatedAt)))) best = { s, agent, url, host };
      }
    } catch (error) { failed.push(`${host} (${error.message})`); }
  }
  const unread = failed.length ? ` I couldn't read ${failed.join(", ")}.` : "";
  if (!best || best.s < 0.49) return `No live session matches "${name}".${unread} Use sessions to see the titles.`;
  const close = best.s < 0.98 ? `Closest match for "${name}": ` : "";
  return close + (await said(await daemon(best.url), best.agent, best.host)) + unread;
}

/** A configured read-only source (a file or command), e.g. the god session's focus list. */
function readSource({ name }) {
  const source = (config.sources ?? []).find((s) => s.name.toLowerCase() === String(name ?? "").toLowerCase());
  if (!source) return Promise.resolve(`No source called "${name}". Sources: ${(config.sources ?? []).map((s) => s.name).join(", ") || "none"}.`);
  return new Promise((resolve) => execFile("/bin/sh", ["-c", source.command], { timeout: 15_000, maxBuffer: 1 << 20 },
    (error, stdout) => resolve(error ? `Couldn't read ${source.name}: ${error.message}` : (stdout.trim() || "It's empty.").slice(0, 9000)))); // the top: each source's command decides what it covers
}

function jobStatus() {
  if (!jobs.length) return "Nothing has been handed to a worker in this conversation.";
  return jobs.slice(-5).map((job) => {
    const minutes = Math.round((Date.now() - job.started) / 60_000);
    const step = job.steps.at(-1);
    return `${job.to}, "${job.task}": ${job.status}${job.status === "running" && step ? `, now ${step.toLowerCase()}` : ""}, ${minutes} min ago.` +
      (job.reply ? ` Reply: ${job.reply.slice(0, 800)}` : "");
  }).join("\n");
}

// ---- Read at the start of a call, so the common questions need no tool.
const zone = () => config.timezone || config.phoneTimezone;
/** A promise's text, or an "unavailable" line once ms have passed. */
const within = (promise, ms, label) => Promise.race([Promise.resolve(promise).catch((error) => `unavailable: ${label} (${error.message})`),
  sleep(ms).then(() => `unavailable: ${label} took longer than ${ms / 1000} s`)]);
const preloadSources = () => (config.sources ?? []).filter((s) => s.preload);

/** The "Already read for this call" block: needs, sessions, preload sources and recent call notes, in parallel. */
async function preload() {
  const started = Date.now();
  const [needs, live, sources, memory] = await Promise.all([
    config.needs?.command ? within(needsQueue(), 4000, "the needs queue") : "",
    within(sessions({ compact: true }), 4000, "sessions"),
    Promise.all(preloadSources().map(async (s) => ({ name: s.name, text: await within(readSource({ name: s.name }), 4000, s.name) }))),
    remembering(config) ? recentMemory(config).catch(() => "") : "",
  ]);
  const at = new Date().toLocaleString("en-GB", { timeZone: zone(), weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
  const block = contextBlock({ at, needs, sessions: live, sources, memory, person: config.person });
  console.log(`preload ${block.length} chars in ${Date.now() - started} ms`);
  return block;
}

/** "Catch me up" in one call, read fresh: needs, sessions and the preload sources together. */
async function catchUp() {
  const [needs, live, sources] = await Promise.all([
    config.needs?.command ? within(needsQueue(), 15_000, "the needs queue") : "",
    within(sessions({ compact: true }), 15_000, "sessions"),
    Promise.all(preloadSources().map(async (s) => `${s.name}:\n${String(await within(readSource({ name: s.name }), 15_000, s.name)).slice(0, 2000)}`)),
  ]);
  return [needs && `Needs ${config.person}:\n${needs}`, `Sessions:\n${live}`, ...sources].filter(Boolean).join("\n\n").slice(0, 7000);
}

const answered = []; // asks answered by voice ({ at, plan, title }), for the call's memory note
async function answerAskTool(args) {
  if (!answering(config)) return "Answering asks by voice isn't set up here.";
  const result = await answerAsk(config, args ?? {});
  if (/^(Recorded|Dry run)/.test(result)) answered.push({ at: Date.now(), plan: args.plan, note: result.slice(0, 200) });
  answered.splice(0, Math.max(0, answered.length - 50));
  return result;
}

/** A finished call's memory note: one cheap model call, appended to the day's file. */
async function remember({ started, turns }) {
  const at = Date.parse(started) || Date.now();
  const asks = answered.filter((a) => a.at >= at).map((a) => `- ${a.plan}: ${a.note}`).join("\n");
  const t0 = Date.now();
  const summary = await summariseCall(config, turns, asks ? `Asks answered in this call (from the tool):\n${asks}` : "");
  if (!summary) return console.log("memory: nothing to note for that call");
  const file = await writeMemory(config, at, summary);
  console.log(`memory wrote ${summary.split("\n").length} lines to ${file} in ${Date.now() - t0} ms`);
}

/** Hands one task to the worker and follows it until it finishes, then speaks the result. */
async function run(job) {
  // A moment's grace: a turn abandoned within it (the person carried on talking) never starts its task.
  await sleep(1200);
  if (job.cancelled) { job.status = "cancelled"; broadcast({ type: "job", job: view(job) }); return; }
  job.status = "running";
  broadcast({ type: "job", job: view(job) });
  const prompt = `(${config.person}, by voice through their assistant. Do this, then reply in a few short plain sentences; your reply is summarised aloud.)\n\n${job.task}`;
  if (job.worker?.command) {
    job.steps = [`Asking ${job.to}`];
    broadcast({ type: "job", job: view(job) });
    try {
      job.reply = await runCommand(job.worker, prompt);
      job.status = "done";
    } catch (error) {
      job.status = "failed";
      job.reply = `It failed: ${error.message ?? error}`;
    }
    broadcast({ type: "job", job: view(job) });
    return announce(job);
  }
  try {
    const { client, agent: live } = await session(job.worker, job.plan);
    const agent = client.agents.ref(live.id);
    let finished = false;
    let failure = null;
    agent.run(prompt, { timeoutMs: 15 * 60_000 }).then(() => (finished = true), (error) => ((failure = error), (finished = true)));
    let toolCalls = 0;
    let stepSince = Date.now();
    let warned = false;
    let lastNews = Date.now();
    let told = 0;
    for (;;) {
      await sleep(1500);
      const done = finished;
      const page = await agent.timeline.refetch({ direction: "tail", limit: 300, projection: "projected" });
      let start = -1;
      page.entries.forEach((entry, index) => {
        if (entry.item.type === "user_message" && (entry.item.text ?? "").includes(job.task)) start = index + 1;
      });
      if (start >= 0) {
        const after = page.entries.slice(start).map((entry) => entry.item);
        const labels = after.map(stepLabel).filter(Boolean).filter((label, i, all) => label !== all[i - 1]);
        const calls = after.filter((item) => item.type === "tool_call").length;
        if (calls !== toolCalls) { toolCalls = calls; stepSince = Date.now(); warned = false; }
        if (labels.length !== job.steps.length) {
          job.steps = labels;
          broadcast({ type: "job", job: view(job) });
          // News on events, tapering: a new step after 20 s of work, then less and less often.
          const step = labels.at(-1);
          if (step && step !== "Thinking" && Date.now() - job.started > 20_000 && Date.now() - lastNews > 30_000 * (told + 1)) {
            told += 1;
            lastNews = Date.now();
            await tell(`${job.to[0].toUpperCase()}${job.to.slice(1)} is ${step.replace(/^\w/, (c) => c.toLowerCase())}.`);
          }
        }
        job.reply = after.filter((item) => item.type === "assistant_message" && item.text).map((item) => item.text).join("\n\n");
        // One spoken heads-up per step that runs long, so silence never means "stuck?".
        if (!done && !warned && Date.now() - stepSince > 90_000) {
          warned = true;
          await tell(`${job.to}: ${progressLine(job.steps.at(-1), (Date.now() - stepSince) / 1000)}`);
        }
      }
      if (done) break;
    }
    job.status = failure ? "failed" : "done";
    if (failure) job.reply = `It failed: ${failure.message ?? failure}`;
  } catch (error) {
    job.status = "failed";
    job.reply = `It couldn't start: ${error.message ?? error}`;
  }
  broadcast({ type: "job", job: view(job) });
  return announce(job);
}

/** A call's WebRTC offer (and ICE candidates), passed to the Pipecat bot. */
async function offer(request, response) {
  const answer = await fetch(`${PIPECAT}/api/offer`, { method: request.method, headers: { "Content-Type": "application/json" }, body: await body(request), signal: AbortSignal.timeout(20_000) })
    .catch((error) => ({ ok: false, status: 502, text: async () => JSON.stringify({ error: `The voice engine isn't answering: ${error.message}` }) }));
  return send(response, answer.status ?? (answer.ok ? 200 : 502), await answer.text(), "application/json; charset=utf-8"); // already JSON
}

/** Speaks a finished job's result: a short summary, or an honest one-line fallback. */
async function announce(job) {
  // An open call speaks it in its own words and keeps the answer for follow-ups.
  if (bots.size) return toBots({ type: "finished", to: job.to, task: job.task, status: job.status, reply: job.reply.slice(0, 3000) });
  await serial(async () => {
    const text = (await summarise(config, history, job).catch(() => "")) || fallbackLine(job);
    broadcast({ type: "say", text, audio: await voice(text) });
  });
}

/** A short honest line when a summary couldn't be made. */
function fallbackLine(job) {
  const who = job.to || "The worker";
  const name = who[0].toUpperCase() + who.slice(1);
  if (job.status === "failed") return `${name} didn't finish that one.`;
  return job.reply ? `${name} has answered. It's on the card.` : `${name} finished but sent no reply.`;
}

/** One spoken turn, streamed back as lines of JSON: what was heard, the reply text and its speech. */
async function turn(request, response, typed) {
  const audio = typed ? null : await body(request);
  response.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" });
  let open = true;
  response.on("close", () => (open = false));
  const emit = (event) => open && response.write(JSON.stringify(event) + "\n");
  try {
    const words = typed ?? await transcribe(audio, request.headers["content-type"] ?? "audio/webm", config.language ?? "en");
    // What was said before a pause that cut the person off; this turn carries on from it.
    let before = "";
    try { before = decodeURIComponent(request.headers["x-said-before"] ?? "").slice(0, 2000); } catch {}
    if (isPhantom(words, config.language ?? "en") && !before) return emit({ type: "heard", text: "" });
    const heard = isPhantom(words, config.language ?? "en") ? before : `${before} ${words}`.trim();
    // Stopped mid-thought: show it and wait for the rest, at most twice, before answering.
    const waits = Number(request.headers["x-continuations"] ?? 0);
    if (!typed && waits < 2 && looksUnfinished(heard)) return emit({ type: "heard", text: heard, unfinished: true });
    emit({ type: "heard", text: heard });
    await serial(async () => {
      let text = "";
      let spoken = 0;
      let speech = Promise.resolve();
      const say = (part) => {
        for (const piece of pieces(plain(part))) {
          const clip = speakPiece(piece).catch(() => null);
          speech = speech.then(async () => { const data = await clip; if (data) emit({ type: "audio", data }); });
        }
      };
      const started = [];
      // The phone may have hung up already (it carried on talking): then nothing this turn starts may run.
      const abandon = () => started.forEach((job) => (job.cancelled = true));
      response.on("close", () => { if (!response.writableFinished) abandon(); });
      await respond(config, history, heard, { sessions, read_session: readSession, read_source: readSource, delegate: (args) => {
        const before = jobs.at(-1);
        const reply = delegate(args, heard);
        const job = jobs.at(-1);
        if (job && job !== before) { started.push(job); if (!open) abandon(); } // only a job this call created
        return reply;
      }, job_status: jobStatus, needs_queue: needsQueue, stay_quiet: () => "Staying quiet.",
        handoffLine: (calls) => {
          const workers = workersOf(config);
          const lines = calls.map(({ to }) => workers.find((w) => w.name === to)?.handoff ?? `I'll ask ${to ?? "the team"}`);
          return `${[...new Set(lines)].join(", and ")}. I'll come back to you when I hear.`;
        },
        paseo: (args) => paseo(config, args, open), skill: (args) => skill(config, args),
        catch_up: catchUp, answer_ask: (args) => {
          const said = history.filter((m) => m.role === "user" && !String(m.content).startsWith("(")).map((m) => String(m.content));
          return answerAskTool({ ...args, _heard: said.slice(-3).join(" "), _last: said.at(-1) ?? "", _turn: said.length });
        },
        recall: (args) => recall(config, args),
        end_conversation: () => { emit({ type: "end" }); return "Ended. The phone stops listening after your goodbye."; } }, (delta) => {
        text += delta;
        emit({ type: "text", text });
        const ready = settledLength(text);
        if (ready > spoken) { say(text.slice(spoken, ready)); spoken = ready; }
      });
      if (text.length > spoken) say(text.slice(spoken));
      await speech;
    });
  } catch (error) {
    console.error(error);
    emit({ type: "error", message: error.message ?? String(error) });
  } finally {
    emit({ type: "done" });
    response.end();
  }
}

async function body(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size <= MAX_AUDIO) chunks.push(chunk); // read the rest so the phone gets the answer
  }
  if (size > MAX_AUDIO) throw new Error("Recording too long.");
  return Buffer.concat(chunks);
}

function send(response, status, payload, type = "application/json") {
  response.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
  response.end(type === "application/json" ? JSON.stringify(payload) : payload);
}

const page_server = createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/") return send(response, 200, page, "text/html; charset=utf-8");
    // Home-screen app: the manifest names it after the assistant (or "Voice" when it has no name).
    if (request.method === "GET" && request.url === "/manifest.webmanifest") {
      const manifest = JSON.parse(await readFile(new URL("./manifest.webmanifest", import.meta.url), "utf8"));
      manifest.name = manifest.short_name = title();
      return send(response, 200, JSON.stringify(manifest), "application/manifest+json");
    }
    const icon = request.method === "GET" && request.url.match(/^\/icon-(180|192|512)\.png$/);
    if (icon) return send(response, 200, await readFile(new URL(`./icons/icon-${icon[1]}.png`, import.meta.url)), "image/png");
    if (request.method === "GET" && request.url.startsWith("/api/config")) {
      // The phone's timezone, so spoken times are right when config.json doesn't set one.
      const zone = new URL(request.url, "http://x").searchParams.get("tz");
      if (!config.timezone && zone && Intl.supportedValuesOf("timeZone").includes(zone)) config.phoneTimezone = zone;
      return send(response, 200, { title: title(), person: config.person, jobs: jobs.map(view) });
    }
    if (request.method === "GET" && request.url === "/api/events") {
      response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      response.write(": hello\n\n");
      listeners.add(response);
      const ping = setInterval(() => response.write(": ping\n\n"), 25_000);
      request.on("close", () => { clearInterval(ping); listeners.delete(response); });
      return;
    }
    // The call itself: the page's WebRTC offer (and its ICE candidates) go to the Pipecat bot.
    if ((request.method === "POST" || request.method === "PATCH") && request.url === "/api/offer") return await offer(request, response);
    if (request.method === "POST" && request.url === "/api/turn") return await turn(request, response);
    if (request.method === "POST" && request.url === "/api/text") {
      const { text } = JSON.parse((await body(request)).toString() || "{}");
      if (!text?.trim()) return send(response, 400, { error: "Nothing to send." });
      return await turn(request, response, text.trim().slice(0, 2000));
    }
    if (request.method === "POST" && request.url === "/api/metric") {
      // Time to first audio, measured on the phone. One line per turn in metrics.log.
      const { ms } = JSON.parse((await body(request)).toString() || "{}");
      if (Number.isFinite(ms)) await appendFile(new URL("./metrics.log", import.meta.url), `${new Date().toISOString()} ttfa_ms=${Math.round(ms)}\n`);
      return send(response, 204, "", "text/plain");
    }
    send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    if (!response.headersSent) send(response, 500, { error: error.message ?? String(error) });
  }
});
// SOCKET: a Unix socket for `tailscale serve unix:...`, where a firewall keeps other users off local TCP ports.
if (process.env.SOCKET) {
  await rm(process.env.SOCKET, { force: true });
  page_server.listen(process.env.SOCKET, async () => { await chmod(process.env.SOCKET, 0o660); console.log(`Voice assistant for ${config.person} on ${process.env.SOCKET}`); });
} else page_server.listen(PORT, "127.0.0.1", () => console.log(`Voice assistant for ${config.person} on http://127.0.0.1:${PORT}`));

// Connect to every Paseo host at start, so the first question doesn't wait for a handshake.
for (const address of Object.values(config.paseo?.hosts ?? {})) open(address).catch((error) => console.error(`Paseo host ${address.replace(/\?.*$/, "")}: ${error.message}`));

// ---- The Pipecat bot's side door: tools, its setup and the news feed. 127.0.0.1 only, never on the tailnet.
const botTools = {
  sessions, read_session: readSession, read_source: readSource, needs_queue: needsQueue, job_status: jobStatus,
  delegate: (args) => delegate(args, args?.task ?? ""), paseo: (args) => paseo(config, args, open), skill: (args) => skill(config, args),
  catch_up: catchUp, answer_ask: answerAskTool, recall: (args) => recall(config, args),
};
createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/bot/setup") {
      // Earlier work this server has seen, so a new call can pick up "how's that going?".
      const earlier = jobs.length ? `\n\nWork handed off earlier today (job_status has the latest):\n${jobStatus()}` : "";
      return send(response, 200, { person: config.person, assistant: config.assistant ?? "", timezone: config.timezone, prompt: systemPrompt(config) + earlier, tools: toolsFor(config), filler: config.filler === true });
    }
    // Read when the call starts, so "what needs me" and "what's running" need no tool.
    if (request.method === "GET" && request.url === "/bot/context") return send(response, 200, { context: config.preload ? await preload() : "" });
    // The call's words, once it ends: noted for the next call when config.memory.dir is set.
    if (request.method === "POST" && request.url === "/bot/call-ended") {
      let call = {};
      try { call = JSON.parse((await body(request)).toString() || "{}"); } catch {}
      send(response, 202, { ok: true });
      if (remembering(config)) remember(call).catch((error) => console.error(`memory: ${error.message}`));
      return;
    }
    if (request.method === "GET" && request.url === "/bot/events") {
      response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      response.write(": hello\n\n");
      bots.add(response);
      const ping = setInterval(() => response.write(": ping\n\n"), 25_000);
      request.on("close", () => { clearInterval(ping); bots.delete(response); });
      return;
    }
    const tool = request.method === "POST" && request.url.match(/^\/bot\/tool\/([a-z_]+)$/);
    if (tool) {
      const handler = botTools[tool[1]];
      if (!handler) return send(response, 404, { result: `Unknown tool ${tool[1]}.` });
      let args = {};
      try { args = JSON.parse((await body(request)).toString() || "{}"); } catch {}
      const started = Date.now();
      const result = String(await handler(args));
      const { _heard, _last, _turn, ...shown } = args;
      console.log(`tool ${tool[1]} ${JSON.stringify(shown).slice(0, 200)} -> ${result.length} chars in ${Date.now() - started} ms`);
      return send(response, 200, { result });
    }
    send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    if (!response.headersSent) send(response, 500, { result: `That failed: ${error.message ?? error}` });
  }
}).listen(BOT_PORT, "127.0.0.1", () => console.log(`Bot tools on http://127.0.0.1:${BOT_PORT}`));

// DEVICE_LISTEN (host:port): a voice gadget's way in, e.g. over a WireGuard link. It takes call offers
// only: no page, no tools, no job list. Retries while its interface isn't up yet.
if (process.env.DEVICE_LISTEN) {
  const [host, port] = [process.env.DEVICE_LISTEN.replace(/:\d+$/, ""), Number(process.env.DEVICE_LISTEN.match(/:(\d+)$/)?.[1])];
  const device = createServer(async (request, response) => {
    try {
      if ((request.method === "POST" || request.method === "PATCH") && request.url === "/api/offer") return await offer(request, response);
      send(response, 404, { error: "Not found" });
    } catch (error) { if (!response.headersSent) send(response, 500, { error: error.message ?? String(error) }); }
  });
  const listen = () => device.listen(port, host, () => console.log(`Device calls on http://${host}:${port}/api/offer`));
  device.on("error", (error) => { console.error(`Device listener on ${host}:${port}: ${error.message}; retrying in 10 s`); setTimeout(listen, 10_000); });
  listen();
}
