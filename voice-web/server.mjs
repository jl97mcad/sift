// Sift voice: a tailnet-only page you just talk to. A fast front model holds the conversation;
// real work goes to the worker Paseo session in the background, and its news is spoken when ready.
// Listens on 127.0.0.1 only; `tailscale serve` puts it on the tailnet over HTTPS.
// Person-specific settings live in config.json (see config.example.json), so anyone can run one.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createPaseoClient } from "@getpaseo/client";
import { isPhantom, pieces, plain, progressLine, settledLength, speakPiece, stepLabel, transcribe } from "./speech.mjs";
import { respond, summarise } from "./front.mjs";

const PORT = Number(process.env.PORT ?? 8771);
const MAX_AUDIO = 20 * 1024 * 1024;
const config = JSON.parse(await readFile(new URL("./config.json", import.meta.url), "utf8").catch(() =>
  readFile(new URL("./config.example.json", import.meta.url), "utf8")));
const page = await readFile(new URL("./index.html", import.meta.url));
const paseo = createPaseoClient({ url: "ws://127.0.0.1:6767/ws", clientId: "sift-voice-web", connectTimeoutMs: 10_000 });
await paseo.connect();

const history = [];
const jobs = [];
const listeners = new Set();
let conversation = Promise.resolve(); // one turn or job summary at a time touches the history
let workQueue = Promise.resolve(); // the worker takes one task at a time
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

/** The live worker session, looked up fresh each time. */
async function worker() {
  const { entries } = await paseo.agents.list();
  const live = entries.map((e) => e.agent).filter((a) => a.labels?.seat === config.worker.seat && a.status !== "closed" && !a.archivedAt);
  if (!live.length) throw new Error(`The ${config.worker.name} session is not running.`);
  return live.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
}

const view = (job) => ({ id: job.id, task: job.task, status: job.status, steps: job.steps.slice(-4), reply: job.reply });

function delegate(task) {
  const job = { id: `job-${Date.now()}`, task, status: "queued", steps: [], reply: "", started: Date.now() };
  jobs.push(job);
  jobs.splice(0, Math.max(0, jobs.length - 20));
  broadcast({ type: "job", job: view(job) });
  workQueue = workQueue.then(() => run(job)).catch((error) => console.error("job failed", error)); // one bad job never blocks the rest
  return `Started: the ${config.worker.name} session is on it. Its result will be spoken when it's ready.`;
}

function jobStatus() {
  if (!jobs.length) return "Nothing has been handed to the worker in this conversation.";
  return jobs.slice(-5).map((job) => {
    const minutes = Math.round((Date.now() - job.started) / 60_000);
    const step = job.steps.at(-1);
    return `"${job.task}": ${job.status}${job.status === "running" && step ? `, now ${step.toLowerCase()}` : ""}, ${minutes} min ago.` +
      (job.reply ? ` Reply: ${job.reply.slice(0, 800)}` : "");
  }).join("\n");
}

/** Hands one task to the worker and follows it until it finishes, then speaks the result. */
async function run(job) {
  job.status = "running";
  broadcast({ type: "job", job: view(job) });
  const prompt = `(From ${config.assistant}, ${config.person}'s voice front door. Do this, then reply in a few short plain sentences; your reply is summarised aloud.)\n\n${job.task}`;
  try {
    const agent = paseo.agents.ref((await worker()).id);
    let finished = false;
    let failure = null;
    agent.run(prompt, { timeoutMs: 15 * 60_000 }).then(() => (finished = true), (error) => ((failure = error), (finished = true)));
    let toolCalls = 0;
    let stepSince = Date.now();
    let warned = false;
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
        if (labels.length !== job.steps.length) { job.steps = labels; broadcast({ type: "job", job: view(job) }); }
        job.reply = after.filter((item) => item.type === "assistant_message" && item.text).map((item) => item.text).join("\n\n");
        // One spoken heads-up per step that runs long, so silence never means "stuck?".
        if (!done && !warned && Date.now() - stepSince > 90_000) {
          warned = true;
          const line = `${config.worker.name}: ${progressLine(job.steps.at(-1), (Date.now() - stepSince) / 1000)}`;
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
  await serial(async () => {
    const text = await summarise(config, history, job).catch(() => `${config.worker.name} finished "${job.task}".`);
    broadcast({ type: "say", text, audio: await voice(text) });
  });
}

/** One spoken turn, streamed back as lines of JSON: what was heard, the reply text and its speech. */
async function turn(request, response) {
  const audio = await body(request);
  response.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" });
  let open = true;
  response.on("close", () => (open = false));
  const emit = (event) => open && response.write(JSON.stringify(event) + "\n");
  try {
    const heard = await transcribe(audio, request.headers["content-type"] ?? "audio/webm", config.language ?? "en");
    if (isPhantom(heard, config.language ?? "en")) return emit({ type: "heard", text: "" });
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
      await respond(config, history, heard, { delegate: ({ task }) => delegate(task?.trim() || heard), job_status: jobStatus,
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
    if (request.method === "GET" && request.url === "/api/config") {
      return send(response, 200, { assistant: config.assistant, person: config.person, worker: config.worker.name, jobs: jobs.map(view) });
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
    send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    if (!response.headersSent) send(response, 500, { error: error.message ?? String(error) });
  }
}).listen(PORT, "127.0.0.1", () => console.log(`${config.assistant} voice on http://127.0.0.1:${PORT}`));
