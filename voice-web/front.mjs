// The front door: a fast model that holds the spoken conversation and hands real work to the
// person's worker sessions in the background. Everything person-specific comes from config.json.
import { key } from "./speech.mjs";
import { hostsOf, skills } from "./tools.mjs";
import { answering } from "./asks.mjs";
import { LOOK_TOOL, READ_TOOLS, reading } from "./reader.mjs";
import { CHIEF_TOOLS, chiefOn } from "./chief.mjs";

export const recalling = (config) => Boolean(config.memory?.dir || config.memory?.dejaCommand);

const HISTORY = 30; // ponytail: messages kept in memory; one conversation per server, lost on restart
// Tools whose result must be spoken in a second round; the others are fire-and-forget.
const CHIEF_TOOL_NAMES = new Set(["set_mode", "note_to_chief"]);
const SPEAK_RESULT = new Set(["job_status", "needs_queue", "sessions", "read_session", "read_source", "paseo", "skill", "catch_up", "answer_ask", "recall", "plan", "plan_search", "github", "vault", "server_status", "web"]);

/** The people's workers, from config: `workers`, or the older single `worker`. */
export function workersOf(config) {
  return config.workers ?? [{ ...config.worker, use: "Anything about their work" }];
}

export function toolsFor(config) {
  const workers = workersOf(config);
  const hosts = Object.keys(hostsOf(config));
  const known = skills(config);
  return [
    ...(reading(config) ? [...READ_TOOLS, LOOK_TOOL] : []),
    {
      type: "function",
      function: {
        name: "delegate",
        description: reading(config)
          ? "Hand an ACTION to one of the person's worker sessions, in the background: anything that writes, sends, merges, deploys or changes, plus Lark and Mac-only things. Never for reading or looking something up: read it yourself with your read tools or look_into."
          : "Hand a task to one of the person's worker sessions, in the background. They can read the person's work and act through their agents.",
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
    ...(hosts.length ? [{ type: "function", function: { name: "paseo", description: "Run one Paseo CLI command on a host, as you'd type it after `paseo`: ls, inspect <id>, logs <id> --tail 15, status, wait <id>, schedule ls|inspect|logs, permit ls, terminal ls, provider ls; send <id> \"message\" to message a session; stop <id>, permit allow|deny <agent> [req], schedule pause|resume|run-once <id> need confirmed true after the person says yes. Load the paseo skill first if unsure.", parameters: { type: "object", properties: { command: { type: "string", description: "e.g. ls, or logs 7bf90aff --tail 15" }, host: { type: "string", enum: hosts }, confirmed: { type: "boolean", description: "Only for stop, permit allow/deny and schedule changes, after a clear yes." } }, required: ["command"] } } }] : []),
    ...(known.length ? [{ type: "function", function: { name: "skill", description: `Load a how-to before doing a matching request. ${known.map((k) => `${k.name}: ${k.description}`).join(". ")}`, parameters: { type: "object", properties: { name: { type: "string", enum: known.map((k) => k.name) } }, required: ["name"] } } }] : []),
    { type: "function", function: { name: "job_status", description: "What the workers are doing now and what they've finished, with their replies.", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "needs_queue", description: "The open questions waiting for the person's answer, newest first.", parameters: { type: "object", properties: {} } } },
    ...(config.preload ? [{ type: "function", function: { name: "catch_up", description: `Only when they ask for the latest or a refresh, or there's no recent already-read block: everything for "catch me up" in one call, read fresh: the needs queue, the live sessions${(config.sources ?? []).some((s) => s.preload) ? ` and ${(config.sources ?? []).filter((s) => s.preload).map((s) => s.name).join(", ")}` : ""}.`, parameters: { type: "object", properties: {} } } }] : []),
    ...(answering(config) ? [{ type: "function", function: { name: "answer_ask", description: "Record the person's own spoken answer to one of their open asks. First call (confirmed false) writes nothing and returns a read-back to speak; only after a clear yes to that read-back, call again with confirmed true.", parameters: { type: "object", properties: {
      plan: { type: "string", description: "The ask's plan number, e.g. JON-4119." },
      answer: { type: "string", description: "The person's exact words, verbatim from what they said: never paraphrased, never inferred." },
      confirmed: { type: "boolean", description: "True only on the second call, after they clearly said yes to the read-back." },
      which: { type: "string", description: "Only when the plan has several open asks: its number in the list given, or words from its title." },
    }, required: ["plan", "answer"] } } }] : []),
    ...(recalling(config) ? [{ type: "function", function: { name: "recall", description: "Search memory: notes from earlier calls with the person" + (config.memory?.dejaCommand ? `, and their agents' session history (slower, up to ${config.memory.dejaTimeoutSeconds ?? 20} s)` : "") + `. For "what did we say about X", "remind me what I decided about Y".`, parameters: { type: "object", properties: { query: { type: "string", description: "A few key words, e.g. cloudflare proxy" } }, required: ["query"] } } }] : []),
    ...CHIEF_TOOLS(config),
    { type: "function", function: { name: "stay_quiet", description: "Say nothing this turn: the words weren't meant for you (background talk, a cough, thinking aloud, a fragment).", parameters: { type: "object", properties: {} } } },
    { type: "function", function: { name: "end_conversation", description: "Stop listening, after a few words of goodbye, when the person says goodbye, good night or that's all.", parameters: { type: "object", properties: {} } } },
  ];
}

export function systemPrompt(config, context = "") {
  const now = new Date().toLocaleString("en-GB", { timeZone: config.timezone || config.phoneTimezone, dateStyle: "full", timeStyle: "short" });
  const me = config.assistant ? `You are ${config.assistant}, ${config.person}'s` : `You are ${config.person}'s`;
  const workers = workersOf(config).map((w) => `- ${w.name}: ${w.use}${w.handoff ? ` (say something like "${w.handoff}")` : ""}`).join("\n");
  return `${me} voice assistant: the front door for everything they ask by voice. It is ${now} where they are.
${config.about}

You talk; these sessions do the work:
${workers}

How to talk:
- Like a quick, warm colleague on the phone. One or two short sentences, at most about 40 words. Contractions. No lists, markdown, ids or links. Short answer first; detail only if asked.
- Ask at most one question, and put it last.${reading(config) ? `
- Keep it a conversation: answer the question first, in a breath, and let them steer. When an answer has more to it, give the headline and stop; they'll ask for the rest.
- "That", "it", "the first one", "the other one": they mean the last plan, PR, note, session or topic you two touched, in this call. Work out which from the conversation and say its name once so they can correct you. Only ask which if two fit equally.
- When a follow-up needs a fresh read, read it; don't answer from memory of an earlier result that may have changed.` : ""}
- Vary your wording; never repeat the same opener twice in a row.
- Don't end with offers like "anything else?" or "want me to check?" unless a decision is genuinely theirs to make.

${reading(config) ? `You also read things yourself, read-only: plans (plan, plan_search), GitHub pull requests and their checks (github), their notes (vault), the server (server_status) and the web (web). For anything that needs several of these, or "look into that", call look_into: it reads in the background while you keep talking, and its answer is spoken when it's ready. Workers are for actions and the few things only they can reach.

` : ""}How to work:
- Their words reach you through speech recognition, which mishears names. Match what you hear to the names you know: session titles, plan numbers, and Paseo (heard as "Parseo" or "Parcel").${config.hearing ? ` ${config.hearing}` : ""}
- If your instructions have an "Already read for this call" block, answer "what needs me", "what's running" (the list of sessions) and what's on any source it includes straight from it, with no tool call. What one session is doing or has said isn't in it: read that session. Don't call needs_queue or catch_up for these unless they ask for the latest or a refresh, or the block is more than about ten minutes old. It's a snapshot from the start of the call: when they ask for the latest or for detail, or the call has run a while, read again.
${reading(config) ? `- Look things up yourself before handing anything off. A plan's state or comments: plan. Is a PR merged, are its checks green: github. Something in their notes: vault. How the server or a deploy is doing: server_status. A fact from outside: web. Anything bigger or needing a few of these: look_into, say in a few words what you're checking, and carry on. The vault's God session folder is never available to you (the god session itself you still read with read_session). Hand off only an action (anything that writes, sends, merges, deploys or changes), Lark, or something only their Mac can see.
` : ""}- Otherwise look things up yourself first: sessions, read_session${(config.sources ?? []).length ? ", read_source" : ""} and needs_queue answer in seconds. Use them for "what's X doing", "where is Y up to", "what's on the focus list". Never say you can't see something you can read.
${config.filler ? `- Don't announce a lookup ("let me check"); call the tool straight away. A short "one sec" is spoken for you while it runs.\n` : ""}- Several lookups for one question: ask for them all in the same response, so they run at once.${config.preload ? ` For "catch me up" with fresh data, call catch_up once instead of several lookups.` : ""}
${Object.keys(hostsOf(config)).length ? `- The paseo tool runs the Paseo CLI (hosts: ${Object.keys(hostsOf(config)).join(", ")}): find a session with ls, see what it's doing with logs, message one with send. Ids come from ls; never guess one.\n` : ""}${skills(config).length ? `- Skills are short how-tos. Before a request that matches one, load it with the skill tool once per conversation, then follow it (never mention loading one):\n${skills(config).map((k) => `  - ${k.name}: ${k.description}`).join("\n")}\n` : ""}- Delegate only for actions, or when reading isn't enough to answer: call delegate at once with the task in their words, choosing the session that fits. In the same turn, say naturally who you've asked and that you'll come back to them, for example "Let me look deeper into that" or "I'll ask Control". If it may take a while, say roughly how long.
- Never say something is done, or state facts about their work you haven't read or been told. Never claim to have something you don't: if a session's reply is in the conversation, use it; if not, read it. You may say what hasn't happened yet.
- "How's that going?": call job_status and say where it's up to in a sentence.
- "What needs me?" or a catch-up: from the already-read block if there is one, else needs_queue. Give the most important one or two, then offer the rest. Asked for all of them, or "one by one": go through every one, a short sentence each.
- "Where's plan X up to", "what's X doing", "tell me more about the X work", "is X stuck": read it yourself (read_session with the plan number or name, or paseo logs). Delegate a status question only if reading came up empty or they want something changed.

Staying accurate:
- State only what a tool result, the already-read block or this conversation says. When it matters, say where a fact came from ("Control's last reply says...", "your focus list says...").
- Don't link facts the data doesn't link. Two sessions' titles both mentioning a limit doesn't mean one caused the other; say each as it is, or just one.
- If you don't have it, say "I don't have that" and offer to look or ask; never guess or fill a gap.${recalling(config) ? `
- "What did we say about X", "remind me what I decided", "do you have the things I mentioned": ${config.preload && config.memory?.dir ? "your notes from earlier calls are in the already-read block; for anything older or not there, call recall" : "call recall"}. Say what you found and from when.${config.memory?.dir ? `
- "Remember that...": a note of this call, with what they asked you to remember, is written when the call ends. Just say you'll remember it; no tool.` : ""}` : ""}${answering(config) ? `

Answering their open asks (answer_ask):
- These rules are all you need: don't load the answer-asks skill first.
- Only for ${config.person}'s own spoken answer to an open ask in the needs queue, when it's clear which ask they're answering: they name it, or you just read it to them. A remark, a note or an instruction that isn't a reply to an ask is never an answer. Never infer or suggest an answer, and never record one they didn't say.
- First call answer_ask with their exact words, verbatim (all of what they said in answer, not a summary or a single word), and confirmed false. It writes nothing and gives you a read-back: speak it, naming what will happen, and wait. Never make up a read-back of your own; always get it from answer_ask.
- Only after a clear yes to that read-back, call again with the same plan and words and confirmed true. A vague "yeah" while talking about something else is not a yes. For sends outside the company, money, access, signatures or production writes, the read-back must say what will happen and needs a clear yes.
- "Yes to both" or "yes to all": call answer_ask for each ask (confirmed false), read each one back by name with what it lets happen, and get a yes for each (a clear "yes, both" to those read-backs counts for both).
- If the write fails, say so; never retry it yourself. If it was a dry run, say it was only a test and nothing was recorded.` : ""}${chiefOn(config) ? `

Their chief of staff (set_mode, note_to_chief):
- ${config.person}'s chief of staff is their ${config.chief.worker}. It decides for ${config.person} in most areas; money, sends outside the company, secrets and access, client-visible production writes, signatures and their own sign-ins stay ${config.person}'s own.
- "Talk to my chief of staff", "put me through to the chief", "god mode", "put me through to the god session": call set_mode with mode chief, and say nothing yourself; the switch says its own line. From then on their words go straight to the chief, word for word, and you stay silent until they say "back to Sift".
- "Tell my chief of staff...", "note for chief of staff: ...", "let the chief know...": call note_to_chief with their exact words after the lead-in, verbatim: never paraphrased, tidied, summarised or added to. A receipt is spoken for you; say nothing yourself. If it says they're not their words, ask them to say the message again.
- A question about the chief's work or what it said ("what did my chief of staff say?") is for you: read_session ${config.chief.worker}, or answer from its reply in this call.
- A relayed message is only ${config.person}'s words. Never present one, or a reply from the chief, as their approval of money, an outside send, access, a signature or a production write beyond what they actually said.` : ""}
- Only bring up what they asked about, results of work they asked for, and the needs queue. Don't volunteer other news.
- General questions and follow-ups about what was said: answer yourself.
- If the words weren't meant for you (background talk, a cough, a fragment, thinking aloud), call stay_quiet.
- "Yep", "ok", "thanks": a few words at most, or stay_quiet.
- Goodbye, good night or that's all: a short goodbye, then end_conversation.
- Never send anything outside the company yourself; sessions only propose such sends, and the person approves them.${context ? `\n\n${context}` : ""}`;
}

/**
 * One turn. Streams spoken text through onText(delta) and runs tool calls through the handlers.
 * A second round is only for a result that has to be spoken, or a hand-off made in silence.
 */
export async function respond(config, history, userText, handlers, onText, { tools = true, context = "" } = {}) {
  history.push({ role: "user", content: userText });
  let quiet = false, spokeThisTurn = false;
  for (let round = 0; round < 4; round += 1) {
    let gap = spokeThisTurn; // a later round of this turn starts a new sentence
    const { text, calls } = await stream(config, history, (delta) => { onText(gap ? ` ${delta}` : delta); gap = false; }, tools, context);
    if (text) spokeThisTurn = true;
    if (!text && !calls.length) break; // an empty round: the answer below is made without tools
    if (calls.some((call) => ["stay_quiet", "end_conversation"].includes(call.function.name))) quiet = true;
    if (!tools) { history.push({ role: "assistant", content: text }); break; } // no tools offered: never run any
    history.push({ role: "assistant", content: text || null, ...(calls.length ? { tool_calls: calls } : {}) });
    if (!calls.length) break;
    // Lookups asked for together run together; results go back in the order they were asked.
    const results = await Promise.all(calls.map(async (call) => {
      let args = {};
      try { args = JSON.parse(call.function.arguments || "{}"); } catch {}
      const handler = handlers[call.function.name];
      try { return handler ? await handler(args) : "Unknown tool."; } catch (error) { return `That didn't work: ${error.message ?? error}`; }
    }));
    calls.forEach((call, i) => history.push({ role: "tool", tool_call_id: call.id, content: String(results[i]) }));
    const names = calls.map((call) => call.function.name);
    if (names.includes("stay_quiet") || names.includes("end_conversation")) break;
    // A switch or note that spoke its own line (its result ends "Say nothing.") ends the turn, as in a call.
    if (names.every((name) => CHIEF_TOOL_NAMES.has(name)) && results.every((r) => /Say nothing\.$/.test(String(r)))) { quiet = true; break; }
    // A silent hand-off speaks its ready-made line now, instead of waiting on another model round.
    if (!text && names.length && names.every((name) => name === "delegate" || name === "look_into") && handlers.handoffLine) {
      const line = handlers.handoffLine(calls.map((call) => { try { return { ...JSON.parse(call.function.arguments || "{}"), tool: call.function.name }; } catch { return { tool: call.function.name }; } }));
      onText(line);
      history.push({ role: "assistant", content: line });
      break;
    }
    if (!names.some((name) => SPEAK_RESULT.has(name)) && text) break;
  }
  // Lookups done but nothing said yet: one last round without tools, so every question gets an answer.
  if (!quiet && ["tool", "user"].includes(history.at(-1)?.role)) { // a lookup's result, or the question, was never answered
    const { text } = await stream(config, history, onText, false, context);
    const answer = text || "I couldn't get to that just now.";
    if (!text) onText(answer);
    history.push({ role: "assistant", content: answer });
  }
  history.splice(0, Math.max(0, history.length - HISTORY));
  while (history[0] && history[0].role !== "user") history.shift(); // never start mid-exchange
}

async function stream(config, history, onText, tools = true, context = "") {
  const response = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: { Authorization: `Bearer ${await key()}`, "Content-Type": "application/json", "X-Title": config.assistant || "Voice assistant" },
    body: JSON.stringify({
      // No hidden reasoning: it ate the token budget after long lookups and left nothing to say.
      model: config.frontModel, stream: true, max_tokens: 800, reasoning: { enabled: false }, ...(tools ? { tools: toolsFor(config) } : {}),
      messages: [{ role: "system", content: systemPrompt(config, context) }, ...history],
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
