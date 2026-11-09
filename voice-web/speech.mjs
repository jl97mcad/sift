// OpenRouter speech, the same models and files as the Sift app (ADR 0012).
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

const SUPPORT = join(homedir(), "Library", "Application Support", "Sift");
const API = "https://openrouter.ai/api/v1";

export async function key() {
  // OPENROUTER_API_KEY, or a file named by OPENROUTER_KEY_FILE, or the Sift Mac app's key file.
  if (process.env.OPENROUTER_API_KEY?.trim()) return process.env.OPENROUTER_API_KEY.trim();
  const file = process.env.OPENROUTER_KEY_FILE || join(SUPPORT, "openrouter-key");
  const value = (await readFile(file, "utf8").catch(() => "")).trim();
  if (!value) throw new Error("No OpenRouter key: run `sift voice key -` on the Mac.");
  return value;
}

/** Phrases Whisper invents from silence or noise (often in another language); never sent as speech. */
export function isPhantom(text, language = "en") {
  const t = text.trim().toLowerCase().replace(/[.!?,…\s]+$/u, "");
  if (!t) return true;
  // Whisper "hears" another script in English-only noise; only check when the language is English.
  if (language === "en" && /[^\u0000-\u024f\u2000-\u206f\u2018-\u201f]/u.test(t)) return true;
  if (/(thanks for watching|subtitles by|to be continued|like and subscribe|amara\.org)/.test(t)) return true;
  // Strings of filler words. A single real "Bye." or "Okay." gets through; "you" alone or a run of three doesn't.
  const words = t.split(/[^a-z']+/).filter(Boolean);
  const filler = new Set(["you", "thank", "thanks", "bye", "okay", "ok", "um", "uh", "hmm"]);
  if (words.length && words.every((w) => filler.has(w))) return words.join(" ") === "you" || words.join(" ") === "thank you" || words.length >= 3;
  return false;
}

export async function transcribe(audio, type, language = "en") {
  const extension = type.includes("mp4") || type.includes("m4a") ? "m4a" : type.includes("ogg") ? "ogg" : type.includes("wav") ? "wav" : "webm";
  const form = new FormData();
  form.append("model", "openai/whisper-large-v3-turbo");
  form.append("language", language); // a fixed language stops it inventing foreign "speech" from noise
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
  const command = item.detail?.command ?? "";
  if (["task_notification", "agent_message"].includes(item.name) || (item.name === "tool" && !command)) return null;
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
  if (item.name === "Edit" || item.name === "Write") return "Editing a file";
  if (item.name === "Grep" || item.name === "Glob") return "Searching files";
  if (item.name === "TodoWrite") return "Planning the steps";
  return item.name === "Bash" ? "Running a command" : "Working";
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

