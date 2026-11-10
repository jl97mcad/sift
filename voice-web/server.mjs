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
import { respond, summarise, workersOf } from "./front.mjs";

const PORT = Number(process.env.PORT ?? 8771);
const MAX_AUDIO = 20 * 1024 * 1024;
const config = JSON.parse(await readFile(new URL("./config.json", import.meta.url), "utf8").catch(() =>
  readFile(new URL("./config.example.json", import.meta.url), "utf8")));
const page = await readFile(new URL("./index.html", import.meta.url));
const LOCAL = "tcp://127.0.0.1:6767";
const clients = new Map(); // one Paseo connection per daemon, opened on first use

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
    : live.filter((a) => a.labels?.seat === worker.seat);
  if (!found.length) throw new Error(worker.lead ? `No lead session is running for ${plan || "that plan"}.` : `The ${worker.name} session is not running.`);
  return { client, agent: found.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0] };
}

const view = (job) => ({ id: job.id, task: job.task, to: job.to, status: job.status, steps: job.steps.slice(-4), reply: job.reply, started: job.started });

function delegate({ task, to, plan }, heard) {
  const workers = workersOf(config);
  const worker = workers.find((w) => w.name === to) ?? (workers.length === 1 ? workers[0] : null);
  if (!worker) return `There's no session called "${to}". Choose one of: ${workers.map((w) => w.name).join(", ")}.`; // never the wrong one
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
const daemonsOf = () => [...new Set(workersOf(config).map((w) => w.url).filter(Boolean))];
const titleOf = (a) => a.title ?? a.name ?? "";

/** Live sessions on every configured daemon: title, status, seat. */
async function sessions() {
  const lines = [];
  for (const url of daemonsOf()) {
    try {
      const client = await daemon(url);
      const { entries } = await client.agents.list();
      for (const a of entries.map((e) => e.agent)) {
        if (a.status === "closed" || a.archivedAt || /retired/i.test(titleOf(a))) continue;
        lines.push(`${titleOf(a).slice(0, 90)} | ${a.status}${a.labels?.seat ? ` | seat ${a.labels.seat}` : ""}`);
      }
    } catch (error) { lines.push(`(couldn't read ${url.replace(/\/\/.*@/, "//")}: ${error.message})`); }
  }
  return lines.length ? lines.slice(0, 80).join("\n") : "No live sessions.";
}

/** The latest prompts and replies of the session whose title or seat best matches the name. */
async function readSession({ name }) {
  const want = String(name ?? "").toLowerCase().trim();
  if (!want) return "Say which session to read.";
  for (const url of daemonsOf()) {
    try {
      const client = await daemon(url);
      const { entries } = await client.agents.list();
      const live = entries.map((e) => e.agent).filter((a) => a.status !== "closed" && !a.archivedAt);
      const match = live.find((a) => a.labels?.seat?.toLowerCase() === want) ?? live.find((a) => titleOf(a).toLowerCase().includes(want));
      if (!match) continue;
      const page = await client.agents.ref(match.id).timeline.refetch({ direction: "tail", limit: 60, projection: "projected" });
      const said = page.entries.map((e) => e.item).filter((i) => (i.type === "assistant_message" || i.type === "user_message") && i.text)
        .slice(-6).map((i) => `${i.type === "user_message" ? "Asked" : "Said"}: ${i.text.slice(0, 900)}`);
      return `${titleOf(match)} (${match.status})\n${said.join("\n") || "Nothing said yet."}`;
    } catch (error) { console.error("read session", error.message); }
  }
  return `No live session matches "${name}".`;
}

/** A configured read-only source (a file or command), e.g. the god session's focus list. */
function readSource({ name }) {
  const source = (config.sources ?? []).find((s) => s.name.toLowerCase() === String(name ?? "").toLowerCase());
  if (!source) return Promise.resolve(`No source called "${name}". Sources: ${(config.sources ?? []).map((s) => s.name).join(", ") || "none"}.`);
  return new Promise((resolve) => execFile("/bin/sh", ["-c", source.command], { timeout: 15_000, maxBuffer: 1 << 20 },
    (error, stdout) => resolve(error ? `Couldn't read ${source.name}: ${error.message}` : (stdout.trim() || "It's empty.").slice(-6000))));
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
            const line = `${job.to[0].toUpperCase()}${job.to.slice(1)} is ${step.replace(/^\w/, (c) => c.toLowerCase())}.`;
            broadcast({ type: "say", text: line, audio: await voice(line) });
          }
        }
        job.reply = after.filter((item) => item.type === "assistant_message" && item.text).map((item) => item.text).join("\n\n");
        // One spoken heads-up per step that runs long, so silence never means "stuck?".
        if (!done && !warned && Date.now() - stepSince > 90_000) {
          warned = true;
          const line = `${job.to}: ${progressLine(job.steps.at(-1), (Date.now() - stepSince) / 1000)}`;
          broadcast({ type: "say", text: line, audio: await voice(line) });
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

/** Speaks a finished job's result: a short summary, or an honest one-line fallback. */
async function announce(job) {
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

createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/") return send(response, 200, page, "text/html; charset=utf-8");
    // Home-screen app: the manifest names it after the assistant (or "Voice" when it has no name).
    if (request.method === "GET" && request.url === "/manifest.webmanifest") {
      const manifest = JSON.parse(await readFile(new URL("./manifest.webmanifest", import.meta.url), "utf8"));
      if (config.assistant) { manifest.name = config.assistant; manifest.short_name = config.assistant; }
      return send(response, 200, JSON.stringify(manifest), "application/manifest+json");
    }
    const icon = request.method === "GET" && request.url.match(/^\/icon-(180|192|512)\.png$/);
    if (icon) return send(response, 200, await readFile(new URL(`./icons/icon-${icon[1]}.png`, import.meta.url)), "image/png");
    if (request.method === "GET" && request.url === "/api/config") {
      return send(response, 200, { assistant: config.assistant ?? "", person: config.person, jobs: jobs.map(view) });
    }
    if (request.method === "GET" && request.url === "/api/events") {
      response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store", Connection: "keep-alive" });
      response.write(": hello\n\n");
      listeners.add(response);
      const ping = setInterval(() => response.write(": ping\n\n"), 25_000);
      request.on("close", () => { clearInterval(ping); listeners.delete(response); });
      return;
    }
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
}).listen(PORT, "127.0.0.1", () => console.log(`Voice assistant for ${config.person} on http://127.0.0.1:${PORT}`));
