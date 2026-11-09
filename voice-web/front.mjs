// The front door: a fast model that holds the spoken conversation and hands real work to a
// worker Paseo session in the background. Everything person-specific comes from config.json.
import { key } from "./speech.mjs";

const HISTORY = 30; // ponytail: messages kept in memory; one conversation per server, lost on restart

const tools = [
  {
    type: "function",
    function: {
      name: "delegate",
      description: "Hand a task to the worker agent, which can read the person's work (sessions, plans, notes, PRs, meetings, messages) and act through their agents. Use it for anything about their work you can't answer from this conversation.",
      parameters: { type: "object", properties: { task: { type: "string", description: "The task in the person's own words, with any detail from the conversation." } }, required: ["task"] },
    },
  },
  {
    type: "function",
    function: {
      name: "job_status",
      description: "What the worker is doing now and what it has finished, with its replies.",
      parameters: { type: "object", properties: {} },
    },
  },
];

export function systemPrompt(config) {
  const now = new Date().toLocaleString("en-GB", { timeZone: config.timezone, dateStyle: "full", timeStyle: "short" });
  return `You are ${config.assistant}, ${config.person}'s spoken assistant: the front door for everything he asks by voice. It is ${now} where he is.
${config.about}

You talk; the worker (${config.worker.name}) does the work. Rules:
- Speak like a quick, warm colleague. One or two short sentences per turn. No lists, markdown, ids or links.
- Anything about his work (plans, agents, meetings, people, PRs, messages, what needs him), or any action: call delegate at once with the task in his words, and in the same turn say briefly what you've asked for. Never make up facts about his work.
- When he asks how something is going, call job_status and tell him in a sentence, including what step it's on.
- General questions and quick follow-ups about what was said: answer yourself.
- If he says "yep", "ok" or "thanks", reply in a few words or just acknowledge.
- Never send anything outside the company yourself; the worker only proposes such sends, and he approves them.`;
}

/**
 * One turn. Streams spoken text through onText(delta) and runs tool calls through the given
 * handlers, then lets the model finish its reply.
 */
export async function respond(config, history, userText, handlers, onText) {
  history.push({ role: "user", content: userText });
  for (let round = 0; round < 3; round += 1) {
    const { text, calls } = await stream(config, history, onText);
    history.push({ role: "assistant", content: text || null, ...(calls.length ? { tool_calls: calls } : {}) });
    if (!calls.length) break;
    for (const call of calls) {
      let args = {};
      try { args = JSON.parse(call.function.arguments || "{}"); } catch {}
      const handler = handlers[call.function.name];
      const result = handler ? await handler(args) : "Unknown tool.";
      history.push({ role: "tool", tool_call_id: call.id, content: String(result) });
    }
    // It already spoke alongside a hand-off, so don't make it talk twice; a status check must be spoken.
    if (text && calls.every((call) => call.function.name === "delegate")) break;
  }
  history.splice(0, Math.max(0, history.length - HISTORY));
  while (history[0] && history[0].role !== "user") history.shift(); // never start mid-exchange
}

async function stream(config, history, onText) {
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": config.assistant },
    body: JSON.stringify({
      model: config.frontModel, stream: true, max_tokens: 300, tools,
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
      const delta = JSON.parse(raw.slice(6)).choices?.[0]?.delta ?? {};
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
    `(System note, not ${config.person}: ${config.worker.name} finished "${job.task}". Its reply: ${job.reply.slice(0, 3000) || "(no reply)"}. Tell ${config.person} the result in one or two short spoken sentences, starting with what it was about.)`,
    {}, (delta) => (spoken += delta));
  // Keep what was said, not the note: later turns must never read it as words the person said.
  const note = history.findIndex((message, index) => index >= at - 1 && message.role === "user" && String(message.content).startsWith("(System note"));
  if (note >= 0) history.splice(note, 1, { role: "user", content: `(${config.worker.name} finished: ${job.task})` });
  return spoken;
}
