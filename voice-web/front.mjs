// The front door: a fast model that holds the spoken conversation and hands real work to the
// person's worker sessions in the background. Everything person-specific comes from config.json.
import { key } from "./speech.mjs";

const HISTORY = 30; // ponytail: messages kept in memory; one conversation per server, lost on restart
// Tools whose result must be spoken in a second round; the others are fire-and-forget.
const SPEAK_RESULT = new Set(["job_status", "needs_queue", "sessions", "read_session", "read_source"]);

/** The people's workers, from config: `workers`, or the older single `worker`. */
export function workersOf(config) {
  return config.workers ?? [{ ...config.worker, use: "Anything about their work" }];
}

function toolsFor(config) {
  const workers = workersOf(config);
  return [
    {
      type: "function",
      function: {
        name: "delegate",
        description: "Hand a task to one of the person's worker sessions, in the background. They can read the person's work and act through their agents.",
        parameters: {
          type: "object",
          properties: {
            task: { type: "string", description: "The task in the person's own words, with any detail from the conversation." },
            to: { type: "string", enum: workers.map((w) => w.name), description: workers.map((w) => `${w.name}: ${w.use}`).join(". ") },
            plan: { type: "string", description: "Only for a plan lead: the plan's number, e.g. JON-123." },
          },
          required: ["task", "to"],
        },
      },
    },
    { type: "function", function: { name: "sessions", description: "List the person's live agent sessions on every daemon: title, status and seat. Fast.", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "read_session", description: "Read the latest prompts and replies of one session, by its seat (control, god, voice) or words from its title (a plan number, a name). Fast.", parameters: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } } },
    ...((config.sources ?? []).length ? [{ type: "function", function: { name: "read_source", description: `Read a source directly. ${(config.sources ?? []).map((s) => `${s.name}: ${s.use}`).join(". ")}`, parameters: { type: "object", properties: { name: { type: "string", enum: config.sources.map((s) => s.name) } }, required: ["name"] } } }] : []),
    { type: "function", function: { name: "job_status", description: "What the workers are doing now and what they've finished, with their replies.", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "needs_queue", description: "The open questions waiting for the person's answer, newest first.", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "stay_quiet", description: "Say nothing this turn: the words weren't meant for you (background talk, a cough, thinking aloud, a fragment).", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "end_conversation", description: "Stop listening, after a few words of goodbye, when the person says goodbye, good night or that's all.", parameters: { type: "object", properties: {} } } },
  ];
}

export function systemPrompt(config) {
  const now = new Date().toLocaleString("en-GB", { timeZone: config.timezone, dateStyle: "full", timeStyle: "short" });
  const me = config.assistant ? `You are ${config.assistant}, ${config.person}'s` : `You are ${config.person}'s`;
  const workers = workersOf(config).map((w) => `- ${w.name}: ${w.use}${w.handoff ? ` (say something like "${w.handoff}")` : ""}`).join("\n");
  return `${me} voice assistant: the front door for everything they ask by voice. It is ${now} where they are.
${config.about}

You talk; these sessions do the work:
${workers}

How to talk:
- Like a quick, warm colleague on the phone. One or two short sentences, at most about 40 words. Contractions. No lists, markdown, ids or links. Short answer first; detail only if asked.
- Ask at most one question, and put it last.
- Vary your wording; never repeat the same opener twice in a row.
- Don't end with offers like "anything else?" or "want me to check?" unless a decision is genuinely theirs to make.

How to work:
- Look things up yourself first: sessions, read_session${(config.sources ?? []).length ? ", read_source" : ""} and needs_queue answer in seconds. Use them for "what's X doing", "where is Y up to", "what's on the focus list". Never say you can't see something you can read.
- Delegate only for actions, or when reading isn't enough to answer: call delegate at once with the task in their words, choosing the session that fits. In the same turn, say naturally who you've asked and that you'll come back to them, for example "Let me look deeper into that" or "I'll ask Control". If it may take a while, say roughly how long.
- Never say something is done, or state facts about their work you haven't read or been told. Never claim to have something you don't: if a session's reply is in the conversation, use it; if not, read it. You may say what hasn't happened yet.
- "How's that going?": call job_status and say where it's up to in a sentence.
- "What needs me?" or a catch-up: call needs_queue and give the most important one or two, then offer the rest.
- Only bring up what they asked about, results of work they asked for, and the needs queue. Don't volunteer other news.
- General questions and follow-ups about what was said: answer yourself.
- If the words weren't meant for you (background talk, a cough, a fragment, thinking aloud), call stay_quiet.
- "Yep", "ok", "thanks": a few words at most, or stay_quiet.
- Goodbye, good night or that's all: a short goodbye, then end_conversation.
- Never send anything outside the company yourself; sessions only propose such sends, and the person approves them.`;
}

/**
 * One turn. Streams spoken text through onText(delta) and runs tool calls through the handlers.
 * A second round is only for a result that has to be spoken, or a hand-off made in silence.
 */
export async function respond(config, history, userText, handlers, onText, { tools = true } = {}) {
  history.push({ role: "user", content: userText });
  let quiet = false;
  for (let round = 0; round < 4; round += 1) {
    let gap = round > 0 && history.some((m, i) => i > 0 && m.role === "assistant" && m.content); // later rounds start a new sentence
    const { text, calls } = await stream(config, history, (delta) => { onText(gap ? ` ${delta}` : delta); gap = false; }, tools);
    if (calls.some((call) => ["stay_quiet", "end_conversation"].includes(call.function.name))) quiet = true;
    if (!tools) { history.push({ role: "assistant", content: text }); break; } // no tools offered: never run any
    history.push({ role: "assistant", content: text || null, ...(calls.length ? { tool_calls: calls } : {}) });
    if (!calls.length) break;
    for (const call of calls) {
      let args = {};
      try { args = JSON.parse(call.function.arguments || "{}"); } catch {}
      const handler = handlers[call.function.name];
      const result = handler ? await handler(args) : "Unknown tool.";
      history.push({ role: "tool", tool_call_id: call.id, content: String(result) });
    }
    const names = calls.map((call) => call.function.name);
    if (names.includes("stay_quiet") || names.includes("end_conversation")) break;
    // A silent hand-off speaks its ready-made line now, instead of waiting on another model round.
    if (!text && names.length && names.every((name) => name === "delegate") && handlers.handoffLine) {
      const line = handlers.handoffLine(calls.map((call) => { try { return JSON.parse(call.function.arguments || "{}"); } catch { return {}; } }));
      onText(line);
      history.push({ role: "assistant", content: line });
      break;
    }
    if (!names.some((name) => SPEAK_RESULT.has(name)) && text) break;
  }
  // Lookups done but nothing said yet: one last round without tools, so every question gets an answer.
  if (!quiet && history.at(-1)?.role === "tool") { // a lookup's result was never spoken (even after "let me check")
    const { text } = await stream(config, history, onText, false);
    const answer = text || "I couldn't get to that just now.";
    if (!text) onText(answer);
    history.push({ role: "assistant", content: answer });
  }
  history.splice(0, Math.max(0, history.length - HISTORY));
  while (history[0] && history[0].role !== "user") history.shift(); // never start mid-exchange
}

async function stream(config, history, onText, tools = true) {
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": config.assistant || "Voice assistant" },
    body: JSON.stringify({
      // No hidden reasoning: it ate the token budget after long lookups and left nothing to say.
      model: config.frontModel, stream: true, max_tokens: 800, reasoning: { enabled: false }, ...(tools ? { tools: toolsFor(config) } : {}),
      messages: [{ role: "system", content: systemPrompt(config) }, ...history],
    }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`Front model failed: HTTP ${response.status}`);
  let text = "";
  const calls = [];
  let buffer = "";
  const decoder = new TextDecoder();
  for await (const chunk of response.body) {
    buffer += decoder.decode(chunk, { stream: true });
    let line;
    while ((line = buffer.indexOf("\n")) >= 0) {
      const raw = buffer.slice(0, line).trim();
      buffer = buffer.slice(line + 1);
      if (!raw.startsWith("data: ") || raw === "data: [DONE]") continue;
      const event = JSON.parse(raw.slice(6));
      if (event.error) throw new Error(`Front model: ${event.error.message ?? JSON.stringify(event.error)}`); // never fail silently
      const delta = event.choices?.[0]?.delta ?? {};
      if (delta.content) { text += delta.content; onText(delta.content); }
      for (const part of delta.tool_calls ?? []) {
        const call = (calls[part.index ?? 0] ??= { id: "", type: "function", function: { name: "", arguments: "" } });
        if (part.id) call.id = part.id;
        if (part.function?.name) call.function.name += part.function.name;
        if (part.function?.arguments) call.function.arguments += part.function.arguments;
      }
    }
  }
  return { text, calls: calls.filter(Boolean) };
}

/** A short spoken line when a delegated task finishes. */
export async function summarise(config, history, job) {
  let spoken = "";
  const at = history.length;
  await respond(config, history,
    `(System note, not ${config.person}: ${job.to} finished "${job.task}". Its reply: ${job.reply.slice(0, 3000) || "(no reply)"}. Tell ${config.person} the result in one or two short spoken sentences, starting with what it was about. If it needs their decision, ask that one question last.)`,
    {}, (delta) => (spoken += delta), { tools: false }); // a summary must be spoken, never a tool call
  // Keep what was said, not the note: later turns must never read it as words the person said.
  const note = history.findIndex((message, index) => index >= at && message.role === "user" && String(message.content).startsWith("(System note"));
  // Keep the answer itself, so a follow-up ("what did you find?") is answered from it, never contradicted.
  if (note >= 0) history.splice(note, 1, { role: "user", content: `(Not said by ${config.person}. ${job.to} finished "${job.task}" and replied: ${job.reply.slice(0, 2500) || "(nothing)"})` });
  return spoken;
}
