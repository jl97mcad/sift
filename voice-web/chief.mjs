// Chief-of-staff mode: the person talks straight to one worker session (their chief of staff).
// Off unless config.chief.worker names a worker. The Pipecat bot matches the phrases and holds each
// message for its grace window (pipecat/chief.py); this side checks a quick note is the person's own
// words, wraps the message, sends it, and makes the short spoken version of the reply.
import { key } from "./speech.mjs";
import { notHeard } from "./asks.mjs";

/** On only when chief.worker names a configured session worker (found by seat or title; never a plan lead or a command). */
export const chiefOn = (config) => Boolean(config.chief?.worker) && (config.workers ?? []).some((w) => w.name === config.chief.worker && !w.lead && !w.command);
/** Dry run (config chief.dryRun or SIFT_CHIEF_DRY_RUN=1): nothing is sent; the message is only logged. */
export const chiefDryRun = (config) => config.chief?.dryRun === true || /^(1|true|yes)$/i.test(process.env.SIFT_CHIEF_DRY_RUN ?? "");
export const chiefLabel = (config) => config.chief?.label || "Chief of staff";
/** The configured worker the chief messages go to, or null. */
export const chiefWorker = (config, workers = config.workers ?? []) => (chiefOn(config) ? workers.find((w) => w.name === config.chief.worker && !w.lead && !w.command) ?? null : null);

/** In every chief message, so a reply is read up to the next one (and not cut by other sessions' messages). */
export const CHIEF_MARK = "by voice (Sift Voice, verbatim transcript; may contain mishearings): ";

/** The one user message the chief gets: a fixed line, then the person's words exactly as heard. */
export function wrap(person, text) {
  return `${person || "The person"}, ${CHIEF_MARK}${String(text ?? "").trim()}`;
}

/**
 * Whether a quick note (note_to_chief) is the person's own words: every word must be in what was
 * heard in the last few turns. Returns "" when it is, else what to tell the model.
 */
export function notTheirWords(text, heard) {
  const words = String(text ?? "").trim();
  if (!words) return "No words given. Ask what they want to tell their chief of staff.";
  if (!String(heard ?? "").trim()) return "I have no record of what they said, so I can't check these are their words. Ask them to say the message again.";
  const missing = notHeard(words, heard);
  if (!missing.length) return "";
  return `Not their words: they didn't say "${missing.slice(0, 5).join(" ")}". Never paraphrase a note to the chief of staff: call note_to_chief again with exactly what they said, or ask them to say it again. What they said: "${String(heard).replace(/\s+/g, " ").trim().slice(0, 400)}"`;
}

export const CHIEF_TOOLS = (config) => chiefOn(config) ? [
  { type: "function", function: { name: "set_mode", description: `Switch the call to chief-of-staff mode, where ${config.person ?? "the person"}'s words go straight to their chief of staff verbatim and you stay silent; or back to normal. Call it with no words of your own: the switch says its own line.`, parameters: { type: "object", properties: { mode: { type: "string", enum: ["sift", "chief"], description: "chief: talk straight to the chief of staff. sift: back to you." } }, required: ["mode"] } } },
  { type: "function", function: { name: "note_to_chief", description: `Send one message to ${config.person ?? "the person"}'s chief of staff without switching modes ("tell my chief of staff...", "note for chief of staff: ..."). text is their exact words after the lead-in, verbatim: never paraphrased, tidied or added to. A receipt is spoken for you; say nothing yourself.`, parameters: { type: "object", properties: { text: { type: "string", description: "Their exact words, verbatim from what they said, without the lead-in (\"tell my chief of staff\")." } }, required: ["text"] } } },
] : [];

/** The chief's reply as one or two short spoken sentences, on the cheap model, with no tools. */
export async function spokenSummary(config, reply, deps = {}) {
  const text = String(reply ?? "").trim();
  if (!text) return "";
  const call = deps.complete ?? complete;
  const said = await call(config, [
    { role: "system", content: `You turn a message from ${config.person ?? "the person"}'s chief of staff into what their voice assistant says aloud. One or two short plain sentences, at most about 35 words, in the chief of staff's own meaning. Keep any question it asks them, and put it last. No lists, markdown, ids or links. Never add advice, facts or approval of your own. Don't start with "Your chief of staff says"; that is added for you.` },
    { role: "user", content: text.slice(0, 6000) },
  ]).catch(() => "");
  return String(said ?? "").replace(/\s+/g, " ").trim() || firstWords(text, 30);
}

/** The spoken line for a reply: "Your chief of staff says: ...". */
export const replyLine = (summary) => `Your chief of staff says: ${String(summary ?? "").trim()}`;

/** The first n words of plain text, for when no summary could be made. */
export function firstWords(text, n) {
  const words = String(text ?? "").replace(/[*_`#>\[\]]/g, "").replace(/\(https?:[^)]*\)/g, "").replace(/\s+/g, " ").trim().split(" ");
  return words.length > n ? `${words.slice(0, n).join(" ")}…` : words.join(" ");
}

async function complete(config, messages) {
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": config.assistant || "Voice assistant" },
    body: JSON.stringify({ model: config.chief?.model || config.frontModel || "deepseek/deepseek-v4.1-flash", max_tokens: 160, reasoning: { enabled: false }, messages }),
    signal: AbortSignal.timeout(20_000),
  });
  if (!response.ok) throw new Error(`Summary model failed: HTTP ${response.status}`);
  return (await response.json()).choices?.[0]?.message?.content ?? "";
}

/**
 * The reply to one chief message from the session's timeline items: the assistant messages after the
 * user message that carries it, up to the next chief message (which gets its own reply). Messages from
 * anyone else in between don't cut it. Unbounded, everything after it (how a delegated task's reply has
 * always been read). Returns null when the message isn't in the timeline yet.
 */
export function replyAfter(items, message, { bounded = true } = {}) {
  let start = -1;
  items.forEach((item, index) => { if (item.type === "user_message" && String(item.text ?? "").includes(message)) start = index + 1; });
  if (start < 0) return null;
  const after = items.slice(start);
  const next = bounded ? after.findIndex((item) => item.type === "user_message" && String(item.text ?? "").includes(CHIEF_MARK)) : -1;
  const mine = next >= 0 ? after.slice(0, next) : after;
  return { items: mine, reply: mine.filter((item) => item.type === "assistant_message" && item.text).map((item) => item.text).join("\n\n"), followed: next >= 0 };
}
