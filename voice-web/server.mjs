// Sift voice on the phone: a tailnet-only page with one button. Tap, talk, tap; it says
// "okay, let me look", sends your words to the Voice session and reads its reply aloud.
// Listens on 127.0.0.1 only; `tailscale serve` puts it on the tailnet over HTTPS.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { createPaseoClient } from "@getpaseo/client";
import { acknowledgement, latestReply, speakText, transcribe } from "./speech.mjs";

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
        const audio = await body(request);
        const heard = await transcribe(audio, request.headers["content-type"] ?? "audio/webm");
        // Near-silence comes back empty or as Whisper's usual "you".
        if (!heard || /^(you|thank you)[.!]?$/i.test(heard)) return send(response, 200, { heard: "", reply: "", clips: [] });
        const agent = paseo.agents.ref((await voiceAgent()).id);
        await agent.run(heard, { timeoutMs: 5 * 60_000 });
        const page = await agent.timeline.refetch({ direction: "tail", limit: 80, projection: "projected" });
        const reply = latestReply(page.entries);
        // If speech fails, the words still reach the phone.
        const clips = reply ? await speakText(reply).catch((error) => (console.error(error), [])) : [];
        return send(response, 200, { heard, reply, clips });
      } finally {
        busy = false;
      }
    }
    send(response, 404, { error: "Not found" });
  } catch (error) {
    console.error(error);
    send(response, 500, { error: error.message ?? String(error) });
  }
}).listen(PORT, "127.0.0.1", () => console.log(`Sift voice on http://127.0.0.1:${PORT}`));
