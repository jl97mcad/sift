// OpenRouter speech, the same models and files as the Sift app (ADR 0012).
import { readFile, readdir } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const SUPPORT = join(homedir(), "Library", "Application Support", "Sift");
const API = "https://openrouter.ai/api/v1";
// ponytail: long replies are cut here; raise it if Jon wants long answers read in full.
const MAX_SPOKEN = 2000;

export async function key() {
  const value = (await readFile(join(SUPPORT, "openrouter-key"), "utf8").catch(() => "")).trim();
  if (!value) throw new Error("No OpenRouter key: run `sift voice key -` on the Mac.");
  return value;
}

export async function acknowledgement() {
  const folder = join(SUPPORT, "acknowledgements");
  const files = (await readdir(folder).catch(() => [])).filter((name) => name.endsWith(".mp3"));
  if (!files.length) return null;
  return readFile(join(folder, files[Math.floor(Math.random() * files.length)]));
}

export async function transcribe(audio, type) {
  const extension = type.includes("mp4") || type.includes("m4a") ? "m4a" : type.includes("ogg") ? "ogg" : type.includes("wav") ? "wav" : "webm";
  const form = new FormData();
  form.append("model", "openai/whisper-large-v3-turbo");
  form.append("file", new Blob([audio], { type }), `speech.${extension}`);
  const response = await fetch(`${API}/audio/transcriptions`, {
    method: "POST", headers: { Authorization: `Bearer ${await key()}` }, body: form, signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`Transcription failed: HTTP ${response.status}`);
  return ((await response.json()).text ?? "").trim();
}

async function speak(text, apiKey) {
  const response = await fetch(`${API}/audio/speech`, {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json", "X-Title": "Sift" },
    body: JSON.stringify({ model: "fish-audio/drama-3", input: text, voice: "alloy", response_format: "mp3" }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`Speech failed: HTTP ${response.status}`);
  return Buffer.from(await response.arrayBuffer()).toString("base64");
}

/** Markdown that reads well aloud. Mirrors Spoken.plain in the app. */
export function plain(markdown) {
  const rules = [
    [/```[\s\S]*?(```|$)/g, " "], [/\[([^\]]+)\]\([^)]*\)/g, "$1"], [/https?:\/\/\S+/g, "a link"],
    [/`([^`]*)`/g, "$1"], [/^\s{0,3}(#{1,6}|>|[-*+]|\d+[.)])\s+/gm, ""], [/^\s*\|?[-:| ]+\|[-:| ]*$/gm, ""],
    [/\|/g, ", "], [/(\*\*|__|\*|_|~~)(?=\S)(.+?)(?<=\S)\1/g, "$2"], [/\*\*|__|~~/g, ""], [/[ \t]+/g, " "],
  ];
  let text = markdown;
  for (const [pattern, template] of rules) text = text.replace(pattern, template);
  return text.trim();
}

/** Sentences joined up to a length; the first goes alone so the voice starts sooner. */
export function pieces(text, limit = 280) {
  const sentences = text.match(/[^.!?\n]+[.!?]*["')\]]*|\n+/g)?.map((s) => s.trim()).filter(Boolean) ?? [];
  const out = [];
  let current = "";
  for (const sentence of sentences) {
    if (current && (out.length === 0 || current.length + sentence.length + 1 > limit)) { out.push(current); current = sentence; }
    else current = current ? `${current} ${sentence}` : sentence;
  }
  if (current) out.push(current);
  return out;
}

/** The assistant's words since this prompt; empty if the prompt is not in the page. */
export function latestReply(entries, prompt) {
  let start = -1;
  entries.forEach((entry, index) => {
    if (entry.item.type === "user_message" && (entry.item.text ?? "").includes(prompt)) start = index + 1;
  });
  if (start < 0) return ""; // the prompt fell out of the page: never read an older reply
  return entries.slice(start).filter((e) => e.item.type === "assistant_message" && e.item.text).map((e) => e.item.text).join("\n\n");
}

/** End of the last complete sentence: what can be spoken while the agent is still writing. */
export function settledLength(text) {
  const fences = text.split("```").length - 1;
  const usable = fences % 2 ? text.slice(0, text.lastIndexOf("```")) : text;
  let end = 0;
  for (const match of usable.matchAll(/[.!?:;]["')\]]*\s|\n/g)) end = match.index + match[0].length;
  return end;
}

/** A plain label for what the agent is doing, from one timeline item; null for noise. */
export function stepLabel(item) {
  if (item.type === "reasoning") return "Thinking";
  if (item.type !== "tool_call") return null;
  // Background-task notices, messages from other agents and empty tool records say nothing useful.
  if (["task_notification", "agent_message", "tool"].includes(item.name)) return null;
  const command = item.detail?.command ?? "";
  const rules = [
    [/STATE\.md/, "Reading the god session's notes"],
    [/scratchpad/, "Reading Control's scratchpad"],
    [/overnight-|day log/, "Reading Control's day log"],
    [/asks\.json/, "Checking what needs you"],
    [/[Pp]ocket/, "Looking in Pocket"],
    [/vault/, "Reading your vault"],
    [/linear|\bboard\b/i, "Reading the board"],
    [/paseo (agent )?(ls|list)/, "Checking sessions"],
    [/paseo (agent )?logs/, "Reading a session"],
    [/paseo (agent )?send/, "Messaging a session"],
    [/gh (api|pr)/, "Checking GitHub"],
    [/\bdeja\b/, "Searching memory"],
    [/\bdate\b/, "Checking the time"],
    [/\bssh\b/, "Reading files on the box"],
  ];
  for (const [pattern, label] of rules) if (pattern.test(command)) return label;
  if (item.name === "Read") return "Reading a file";
  if (item.name === "WebSearch" || item.name === "WebFetch") return "Searching the web";
  return "Running a command";
}

/** What Sift says when the agent has been quiet a while, so a voice-only user knows it's working. */
export function progressLine(label, secondsOnStep) {
  const doing = (label ?? "Working").replace(/^\w/, (c) => c.toLowerCase());
  if (secondsOnStep > 60) return `Still ${doing}. It's taking a while, but it's still going.`;
  return `Still working. ${label ?? "Thinking"}.`;
}

/** One piece of text as speech. */
export async function speakPiece(text) {
  return speak(text, await key());
}

export async function speakText(text) {
  let spoken = plain(text);
  if (spoken.length > MAX_SPOKEN) spoken = spoken.slice(0, MAX_SPOKEN).replace(/\s+\S*$/, "") + ". That's the start; the rest is in Paseo.";
  const apiKey = await key();
  return Promise.all(pieces(spoken).map((part) => speak(part, apiKey)));
}
