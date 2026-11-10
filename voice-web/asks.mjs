// Answering the person's open asks by voice. Off unless config.asks.answerCommand and
// config.asks.listCommand are set. Two calls: a read-back that writes nothing, then, only after
// a clear yes to that read-back, the write. The person's exact words go to the private ask store;
// the card gets a fixed line of plan wording that never contains them.
import { spawn } from "node:child_process";

const READBACK_MINUTES = 10; // a yes must follow its read-back within this long
const pending = new Map(); // ask_id -> { answer, at }: read-backs given, waiting on a yes

export const answering = (config) => Boolean(config.asks?.answerCommand && config.asks?.listCommand);
export const dryRun = (config) => config.asks?.dryRun === true || /^(1|true|yes)$/i.test(process.env.SIFT_ASKS_DRY_RUN ?? "");

/** Open asks from asks.json text (asks as a list or a map by id). */
export function openAsks(text) {
  const data = JSON.parse(text);
  const all = Array.isArray(data) ? data : Array.isArray(data.asks) ? data.asks : Object.values(data.asks ?? {});
  return all.filter((a) => a && a.state === "open" && a.ask_id && a.plan);
}

/** "JON 4119", "jon-4119", "John forty-one nineteen" heard as "John 4119", or just "4119". */
export function planOf(said) {
  const t = String(said ?? "").toUpperCase().replace(/\bJOHN\b/g, "JON");
  const full = t.match(/\b([A-Z]{2,10})[\s-]*(\d{1,6})\b/);
  if (full) return { prefix: full[1], number: full[2] };
  const bare = t.match(/\b(\d{1,6})\b/);
  return bare ? { prefix: null, number: bare[1] } : null;
}

/** The open asks for a plan, narrowed by `which` (its number in the list, or words from its title) when there are several. */
export function findAsks(asks, plan, which) {
  const want = planOf(plan);
  if (!want) return [];
  let found = asks.filter((a) => {
    const [, prefix, number] = String(a.plan).toUpperCase().match(/^([A-Z]+)-(\d+)$/) ?? [];
    return number === want.number && (!want.prefix || prefix === want.prefix);
  }).sort((a, b) => String(a.created_at ?? "").localeCompare(String(b.created_at ?? "")));
  if (found.length > 1 && which !== undefined && String(which).trim()) {
    const n = Number(String(which).trim());
    if (Number.isInteger(n) && n >= 1 && n <= found.length) return [found[n - 1]];
    const words = String(which).toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 2);
    const scored = found.map((a) => ({ a, s: words.filter((w) => `${a.title} ${a.question}`.toLowerCase().includes(w)).length }));
    const best = Math.max(...scored.map((x) => x.s));
    if (best > 0) found = scored.filter((x) => x.s === best).map((x) => x.a);
  }
  return found;
}

/** What a yes will let happen, named for the kinds that need a clear yes. */
export function consequence(ask) {
  const what = short(ask.title || ask.question, 120);
  switch (ask.kind) {
    case "outside_send": return `This lets Control send it outside the company: ${what}.`;
    case "money": return `This approves spending money: ${what}.`;
    case "access": return `This grants or changes access: ${what}.`;
    case "signature": case "signatures": return `This counts as your signature: ${what}.`;
    case "prod_write": return `This lets the team write to production: ${what}.`;
    case "signin": return "It records your answer; any sign-in is still yours to do.";
    default: return "";
  }
}

const SERIOUS = new Set(["outside_send", "money", "access", "signature", "signatures", "prod_write"]);

/** The fixed plan wording for the card, chosen from the answer but never containing it. */
export function summaryFor(answer) {
  const t = ` ${String(answer ?? "").toLowerCase().replace(/[^a-z' ]+/g, " ")} `;
  const no = / (no|nope|don't|do not|dont|not now|not yet|hold off|decline|reject|stop|cancel|never|leave it|skip it|drop it) /.test(t);
  const unnegated = t.replace(/ (don't|do not|dont|never|not) \S+( \S+)?/g, " "); // "don't send it" isn't "send it"
  const yes = / (yes|yeah|yep|yup|approve|approved|go ahead|go for it|do it|send it|ship it|sounds good|agreed|agree|fine|ok|okay|sure|confirmed|done|correct) /.test(unnegated);
  // Both ("yes, but not yet") is direction, never a bare approval.
  if (no && !yes) return "Owner answered by voice: declined the recommendation.";
  if (yes && !no) return "Owner answered by voice: approved the recommendation.";
  return "Owner answered by voice: gave direction.";
}

/** The exact argument list for the write; nothing here is ever run by a shell. */
export function answerArgv(ask, answer) {
  return ["board", "answered", ask.plan, "--ask-id", ask.ask_id, "--text", answer, "--summary", summaryFor(answer), "--action", "answer"];
}

const NUMBER_WORDS = new Set("oh zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty thirty forty fifty sixty seventy eighty ninety hundred thousand jon john plan number".split(" "));
const wordsOf = (text) => String(text ?? "").toLowerCase().replace(/[’']/g, "").split(/[^a-z0-9]+/).filter(Boolean);

/**
 * The words the person must actually have said: every word of the answer, leaving out plan numbers
 * (heard as "John forty-one nineteen", written JON-4119), must be in what was heard. Returns the
 * missing words; none means the answer is theirs.
 */
export function notHeard(answer, heard) {
  const have = new Set(wordsOf(heard));
  return wordsOf(answer).filter((w) => !have.has(w) && !NUMBER_WORDS.has(w) && !/^\d+$/.test(w) && !/^[a-z]{2,10}\d+$/.test(w));
}

/** A clear yes ("yes", "go ahead", "record it"), with no "no" or "don't" in it. */
export function clearYes(text) {
  const t = ` ${String(text ?? "").toLowerCase().replace(/[^a-z' ]+/g, " ")} `;
  const yes = / (yes|yeah|yep|yup|go ahead|go for it|do it|record it|confirm|confirmed|correct|that's right|right|sure|please|ok|okay) /.test(t);
  const no = / (no|nope|don't|do not|dont|not|wait|hang on|hold on|stop|cancel|actually|change) /.test(t);
  return yes && !no;
}

const short = (text, n) => { const t = String(text ?? "").replace(/\s+/g, " ").trim(); return t.length > n ? `${t.slice(0, n)}…` : t; };
const same = (a, b) => String(a).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim() === String(b).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

/** Runs a configured command with input on stdin; the command line itself is config, never the person's words. */
export function run(command, input, timeoutMs = 45_000) {
  return new Promise((resolve) => {
    const child = spawn("/bin/sh", ["-c", command], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "", err = "", done = false;
    const finish = (code, error) => { if (done) return; done = true; clearTimeout(timer); resolve({ code, out, err: error ? `${err}${error}` : err }); };
    const timer = setTimeout(() => { child.kill("SIGKILL"); finish(-1, `timed out after ${Math.round(timeoutMs / 1000)} s`); }, timeoutMs);
    child.stdout.on("data", (d) => { if (out.length < 4 << 20) out += d; });
    child.stderr.on("data", (d) => { if (err.length < 1 << 16) err += d; });
    child.on("error", (error) => finish(-1, error.message));
    child.on("close", (code) => finish(code));
    child.stdin.on("error", () => {});
    child.stdin.end(input ?? "");
  });
}

/**
 * The answer_ask tool. deps (for tests): list() gives asks.json text, write(argv) runs the write,
 * log(line) records what happened, now() the time.
 */
export async function answerAsk(config, { plan, answer, confirmed, which, _heard: heard, _turn: turn, _last: last } = {}, deps = {}) {
  const person = config.person || "the person";
  const list = deps.list ?? (async () => {
    const r = await run(config.asks.listCommand, "", 20_000);
    if (r.code !== 0) throw new Error((r.err || `exit ${r.code}`).trim().slice(0, 300));
    return r.out;
  });
  const write = deps.write ?? ((argv) => run(config.asks.answerCommand, JSON.stringify({ argv }), 60_000));
  const log = deps.log ?? ((line) => console.log(line));
  const now = deps.now ?? (() => Date.now());
  const words = String(answer ?? "").trim();
  if (!plan) return "Say which plan the answer is for, by its number.";
  if (!words) return `I need ${person}'s own words for the answer. Ask what they want to say.`;
  // When the caller knows what was heard, the answer has to be made of those words: never a paraphrase.
  if (heard && confirmed !== true) {
    const missing = notHeard(words, heard);
    if (missing.length) return `Not their words: they didn't say "${missing.slice(0, 5).join(" ")}". Call again with the answer exactly as they said it. What they said: "${short(heard, 400)}"`;
  }
  let asks;
  try { asks = openAsks(await list()); } catch (error) { return `I couldn't read the open asks just now (${error.message}). Nothing was recorded.`; }
  const found = findAsks(asks, plan, which);
  if (!found.length) return `There's no open ask on ${plan} right now. Nothing was recorded. It may already be answered or withdrawn.`;
  if (found.length > 1) {
    return `${plan} has ${found.length} open asks. Ask ${person} which one, then call again with which set to its number or words from its title:\n` +
      found.map((a, i) => `${i + 1}. ${short(a.title || a.question, 140)}`).join("\n");
  }
  const ask = found[0];
  const title = short(ask.title || ask.question, 140);
  const before = pending.get(ask.ask_id);
  const fresh = before && now() - before.at < READBACK_MINUTES * 60_000 && same(before.answer, words);
  // The yes has to come from the person after they heard the read-back: a later turn, and a clear yes.
  if (confirmed === true && fresh && turn !== undefined && !(Number(turn) > Number(before.turn ?? -1))) {
    return `Not recorded: ${person} hasn't answered the read-back yet. Speak it now and wait for their reply; call with confirmed true only in a later turn, after a clear yes.`;
  }
  if (confirmed === true && fresh && last !== undefined && !clearYes(last)) {
    return `Not recorded: "${short(last, 120)}" isn't a clear yes to the read-back. Ask again, or leave it.`;
  }
  if (confirmed !== true || !fresh) {
    pending.set(ask.ask_id, { answer: words, at: now(), turn });
    const serious = SERIOUS.has(ask.kind);
    const lead = confirmed === true ? "Not recorded yet: that yes didn't follow a read-back of these exact words. Read this back first. " : "";
    return `${lead}Nothing is written yet. Speak this read-back and wait for a clear yes: "Recording your answer to ${title}: '${words}'. ${consequence(ask)}${consequence(ask) ? " " : ""}Shall I?"` +
      `\nThe ask: ${short(ask.question, 300)} Recommendation: ${short(ask.recommendation, 160)}` +
      `\nOnly after ${person} clearly says yes to this read-back, call answer_ask again with the same plan and answer and confirmed true.${serious ? " This one needs a clear yes, not a vague one." : ""}`;
  }
  pending.delete(ask.ask_id);
  const argv = answerArgv(ask, words);
  if (dryRun(config)) {
    log(`answer_ask DRY RUN, nothing written. Would run ${JSON.stringify(argv)} through asks.answerCommand`);
    return `Dry run: nothing was recorded. It would have recorded ${person}'s answer to ${title}. Tell ${person} it's a test and nothing was written.`;
  }
  const result = await write(argv);
  log(`answer_ask wrote ${ask.plan} ask ${ask.ask_id}: exit ${result.code}${result.code ? ` ${short(result.err || result.out, 300)}` : ""}`);
  if (result.code !== 0) return `The write failed (${short(result.err || result.out || `exit ${result.code}`, 200)}). Don't retry: tell ${person} it didn't go through, and that Control can read the ask back and check.`;
  try {
    const after = JSON.parse(await list());
    const all = Array.isArray(after) ? after : Array.isArray(after.asks) ? after.asks : Object.values(after.asks ?? {});
    const state = all.find((a) => a?.ask_id === ask.ask_id)?.state ?? "missing";
    if (state === "open") return `The write ran, but the ask on ${ask.plan} still shows open. Don't retry: tell ${person} it may not have gone through and Control can check.`;
    return `Recorded: ${person}'s answer to ${title}. The ask is now ${state}.`;
  } catch (error) {
    return `The write ran, but I couldn't read the ask back (${error.message}). Don't retry: tell ${person} Control can check it.`;
  }
}

/** For tests: forget read-backs. */
export function forget() { pending.clear(); }
