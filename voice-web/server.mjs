// Sift voice on the phone: a tailnet-only page with one button. Tap, talk, tap; it says
// "okay, let me look", sends your words to the Voice session and reads its reply aloud.
// Listens on 127.0.0.1 only; `tailscale serve` puts it on the tailnet over HTTPS.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createPaseoClient } from "@getpaseo/client";
import { acknowledgement, pieces, plain, settledLength, speakPiece, stepLabel, transcribe } from "./speech.mjs";

const PORT = Number(process.env.PORT ?? 8771);
const MAX_AUDIO = 20 * 1024 * 1024;
const page = await readFile(new URL("./index.html", import.meta.url));
const paseo = createPaseoClient({ url: "ws://127.0.0.1:6767/ws", clientId: "sift-voice-web", connectTimeoutMs: 10_000 });
await paseo.connect();
let busy = false;

/** The live session labelled seat=voice, looked up fresh each time. */
async function voiceAgent() {
  const { entries } = await paseo.agents.list();
  const live = entries.map((e) => e.agent).filter((a) => a.labels?.seat === "voice" && a.status !== "closed" && !a.archivedAt);
  if (!live.length) throw new Error("The Voice session is not running.");
  return live.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))[0];
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

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * One turn, streamed to the phone as lines of JSON as it happens: what was heard, each step the
 * agent takes, the reply text so far, and speech for each finished sentence while it still writes.
 */
async function talk(request, response) {
  const audio = await body(request);
  response.writeHead(200, { "Content-Type": "application/x-ndjson", "Cache-Control": "no-store" });
  let open = true;
  response.on("close", () => (open = false));
  const emit = (event) => open && response.write(JSON.stringify(event) + "\n");
  try {
    const heard = await transcribe(audio, request.headers["content-type"] ?? "audio/webm");
    // Near-silence comes back empty or as Whisper's usual "you".
    if (!heard || /^(you|thank you)[.!]?$/i.test(heard)) return emit({ type: "heard", text: "" });
    emit({ type: "heard", text: heard });
    const agent = paseo.agents.ref((await voiceAgent()).id);
    let finished = false;
    let failure = null;
    agent.run(heard, { timeoutMs: 5 * 60_000 }).then(() => (finished = true), (error) => ((failure = error), (finished = true)));

    let speech = Promise.resolve();
    const say = (text) => {
      for (const piece of pieces(plain(text))) {
        const clip = speakPiece(piece).catch((error) => (console.error(error), null));
        speech = speech.then(async () => {
          const data = await clip;
          if (data) emit({ type: "audio", data });
        });
      }
    };
    let steps = [];
    let text = "";
    let spoken = 0;
    // ponytail: polls the local daemon every 0.6 s during a turn; a timeline subscription would
    // push instead, if polling ever shows up in the Mac's load.
    while (open) {
      await sleep(600);
      const done = finished; // read first, so the last fetch includes the whole reply
      const page = await agent.timeline.refetch({ direction: "tail", limit: 300, projection: "projected" });
      let start = -1;
      page.entries.forEach((entry, index) => {
        if (entry.item.type === "user_message" && (entry.item.text ?? "").includes(heard)) start = index + 1;
      });
      if (start >= 0) {
        const after = page.entries.slice(start).map((entry) => entry.item);
        const labels = after.map(stepLabel).filter(Boolean).filter((label, i, all) => label !== all[i - 1]);
        for (const label of labels.slice(steps.length)) emit({ type: "step", label });
        steps = labels;
        const reply = after.filter((item) => item.type === "assistant_message" && item.text).map((item) => item.text).join("\n\n");
        if (reply !== text) emit({ type: "text", text: (text = reply) });
        const ready = done ? reply.length : settledLength(reply);
        if (ready > spoken) {
          say(reply.slice(spoken, ready));
          spoken = ready;
        }
      }
      if (done) break;
    }
    await speech;
    if (failure) emit({ type: "error", message: failure.message ?? String(failure) });
  } catch (error) {
    console.error(error);
    emit({ type: "error", message: error.message ?? String(error) });
  } finally {
    emit({ type: "done" });
    response.end();
  }
}

function send(response, status, payload, type = "application/json") {
  response.writeHead(status, { "Content-Type": type, "Cache-Control": "no-store" });
  response.end(type === "application/json" ? JSON.stringify(payload) : payload);
}

createServer(async (request, response) => {
  try {
    if (request.method === "GET" && request.url === "/") return send(response, 200, page, "text/html; charset=utf-8");
    if (request.method === "GET" && request.url === "/api/ack") {
      const clip = await acknowledgement();
      return clip ? send(response, 200, clip, "audio/mpeg") : send(response, 204, "", "text/plain");
    }
    if (request.method === "POST" && request.url === "/api/talk") {
      if (busy) return send(response, 409, { error: "Still answering the last one." });
      busy = true;
      try {
        await talk(request, response);
      } finally {
        busy = false;
      }
      return;
    }
    send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    send(response, 500, { error: error.message ?? String(error) });
  }
}).listen(PORT, "127.0.0.1", () => console.log(`Sift voice on http://127.0.0.1:${PORT}`));
