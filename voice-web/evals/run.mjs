// Evals for the front model: real questions from calls, run through front.mjs's respond (the same
// turn the server runs) in text mode. Tools are stubbed with recorded fixtures: nothing live is read,
// nothing is written and nothing is delegated. Scores tool choice and banned behaviours.
//
//   node evals/run.mjs [--front <voice-web dir>] [--only id,id] [--runs n] [--json out.json]
//
// --front runs another copy of the code (e.g. the version before a change) against the same cases.
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const arg = (name, fallback) => { const i = process.argv.indexOf(`--${name}`); return i > 0 ? process.argv[i + 1] : fallback; };
const dir = resolve(arg("front", join(HERE, "..")));
const only = arg("only", "")?.split(",").filter(Boolean);
const runs = Number(arg("runs", 1));
const load = async (file) => (existsSync(join(dir, file)) ? import(pathToFileURL(join(dir, file)).href) : null);

const fixtures = JSON.parse(await readFile(join(HERE, "fixtures.json"), "utf8"));
const cases = JSON.parse(await readFile(join(HERE, "cases.json"), "utf8")).filter((c) => !only?.length || only.includes(c.id));
const front = await load("front.mjs");
const tools = await load("tools.mjs");
const digest = await load("digest.mjs");
const asks = await load("asks.mjs");
const memory = await load("memory.mjs");

// Memory notes for today, yesterday and older days, in a scratch folder.
const memDir = await mkdtemp(join(tmpdir(), "voice-evals-"));
const config = { ...fixtures.config, memory: { dir: memDir } };
const day = (offset) => (memory?.dayAndTime ? memory.dayAndTime(Date.now() - offset * 86_400_000, config.timezone).day : new Date(Date.now() - offset * 86_400_000).toISOString().slice(0, 10));
await mkdir(memDir, { recursive: true });
await writeFile(join(memDir, `${day(0)}.md`), `# ${day(0)}\n${fixtures.memory.today}`);
await writeFile(join(memDir, `${day(1)}.md`), `# ${day(1)}\n${fixtures.memory.yesterday}`);
for (const [d, text] of Object.entries(fixtures.memory.older)) await writeFile(join(memDir, `${d}.md`), `# ${d}\n${text}`);

const needsText = fixtures.asks.filter((a) => a.state === "open").map((a) => `${a.plan}: ${a.question} Recommendation: ${a.recommendation}`).join("\n");
const pick = (list, key) => (list.find((f) => new RegExp(f.match, "i").test(key))?.result ?? `(no fixture for "${key}")`);
const source = (name) => pick(fixtures.tools.read_source, String(name ?? ""));

// The preload block, made by the code under test when it has one.
let context = "";
if (digest?.contextBlock) {
  const preload = (config.sources ?? []).filter((s) => s.preload).map((s) => ({ name: s.name, text: source(s.name) }));
  const at = new Date().toLocaleString("en-GB", { timeZone: config.timezone, weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
  context = digest.contextBlock({ at, needs: needsText, sessions: fixtures.sessions, sources: preload, memory: memory?.recentMemory ? await memory.recentMemory(config) : "", person: config.person });
}

const askList = async () => JSON.stringify({ asks: fixtures.asks });
const noWrite = async () => { throw new Error("evals never write"); };
const handlersFor = (calls, heard) => {
  const h = {
    needs_queue: () => needsText,
    sessions: () => fixtures.sessions,
    read_session: ({ name }) => pick(fixtures.tools.read_session, String(name ?? "")),
    read_source: ({ name }) => source(name),
    paseo: ({ command, host }) => pick(fixtures.tools.paseo, `${command ?? ""} ${host ?? ""}`.trim()),
    job_status: () => fixtures.tools.job_status,
    delegate: () => fixtures.tools.delegate,
    skill: (args) => tools.skill(config, args),
    catch_up: () => `Needs Jon:\n${needsText}\n\nSessions:\n${fixtures.sessions}\n\nfocus list:\n${source("focus list")}`,
    answer_ask: (args) => (asks ? asks.answerAsk({ ...config, asks: { ...config.asks, dryRun: true } }, { ...args, ...heard }, { list: askList, write: noWrite, log: () => {} }) : "Unknown tool."),
    recall: (args) => (memory ? memory.recall(config, args) : "Unknown tool."),
    stay_quiet: () => "Staying quiet.",
    end_conversation: () => "Ended.",
  };
  return Object.fromEntries(Object.entries(h).map(([name, fn]) => [name, async (args) => { const call = { name, args }; calls.push(call); call.result = String(await fn(args ?? {})); return call.result; }]));
};

/** Every check a case asks for, each as [passed, label]. */
function score(c, calls, rounds, text) {
  const names = calls.map((x) => x.name);
  const e = c.expect ?? {};
  const checks = [];
  if (e.none) checks.push([names.length === 0, "no tool"]);
  if (e.any) checks.push([names.some((n) => e.any.includes(n)), `uses ${e.any.join("|")}`]);
  if (e.anyOrNone) checks.push([names.every((n) => e.anyOrNone.includes(n)), `only ${e.anyOrNone.join("|")} or none`]);
  if (e.parallel) checks.push([rounds.some((r) => r.filter((n) => !["skill"].includes(n)).length >= e.parallel), `${e.parallel} lookups at once`]);
  for (const [name, n] of Object.entries(e.count ?? {})) checks.push([names.filter((x) => x === name).length >= n, `${n}× ${name}`]);
  // A write is a confirmed call the server carried out (a dry run here); refused confirms don't count.
  const wrote = calls.filter((x) => x.name === "answer_ask" && /^(Recorded|Dry run)/.test(x.result ?? "")).length;
  if (e.confirmedNever || e.noWrite) checks.push([wrote === 0, "no write without a yes"]);
  if (e.confirmedOnce) checks.push([wrote >= 1, "writes after the yes"]);
  for (const b of c.banned ?? []) checks.push([!names.includes(b), `no ${b}`]);
  for (const m of c.mention ?? []) checks.push([new RegExp(m, "i").test(text), `says /${m}/`]);
  for (const m of c.notSay ?? []) checks.push([!new RegExp(m, "i").test(text), `never says /${m}/`]);
  checks.push([text.trim().length > 0 || names.includes("stay_quiet"), "answers"]);
  return checks;
}

async function runCase(c) {
  asks?.forget?.();
  const said = [...(c.history ?? []).filter((m) => m.role === "user").map((m) => m.content), c.say];
  // A read-back given in an earlier turn of the case's history.
  for (const p of c.prime ?? []) await asks?.answerAsk({ ...config, asks: { ...config.asks, dryRun: true } }, { ...p, _turn: said.length - 1 }, { list: askList, write: noWrite, log: () => {} });
  const calls = [];
  const history = structuredClone(c.history ?? []);
  const at = history.length;
  let text = "";
  const started = Date.now();
  try {
    await Promise.race([
      front.respond(config, history, c.say, handlersFor(calls, { _heard: said.slice(-3).join(" "), _last: c.say, _turn: said.length }), (d) => (text += d), { context }),
      new Promise((_, no) => setTimeout(() => no(new Error("timed out")), 90_000)),
    ]);
  } catch (error) { text += ` [error: ${error.message}]`; }
  const rounds = history.slice(at).filter((m) => m.role === "assistant" && m.tool_calls?.length).map((m) => m.tool_calls.map((t) => t.function.name));
  const checks = score(c, calls, rounds, text);
  return { id: c.id, calls: calls.map((x) => (x.name === "answer_ask" ? `answer_ask(${x.args?.plan}${x.args?.confirmed ? ",yes" : ""})` : x.name)), args: calls.map((x) => x.args), rounds, text: text.trim(), checks, ms: Date.now() - started, pass: checks.every(([ok]) => ok) };
}

const results = [];
for (let r = 0; r < runs; r += 1) for (const c of cases) {
  const out = await runCase(c);
  results.push(out);
  const failed = out.checks.filter(([ok]) => !ok).map(([, l]) => l);
  console.log(`${out.pass ? "PASS" : "FAIL"} ${out.id.padEnd(24)} ${String(out.ms).padStart(6)} ms  ${(out.calls.join(", ") || "-").padEnd(40)} ${failed.length ? `missed: ${failed.join("; ")}` : ""}`);
  if (process.argv.includes("--verbose") || !out.pass) console.log(`     said: ${out.text.slice(0, 300)}`);
}
const passed = results.filter((x) => x.pass).length;
const checks = results.flatMap((x) => x.checks);
console.log(`\n${dir}\ncases ${passed}/${results.length} passed (${Math.round((100 * passed) / results.length)}%), checks ${checks.filter(([ok]) => ok).length}/${checks.length}` +
  `, median ${results.map((x) => x.ms).sort((a, b) => a - b)[Math.floor(results.length / 2)]} ms`);
if (arg("json")) await writeFile(arg("json"), JSON.stringify(results, null, 2));
await rm(memDir, { recursive: true, force: true });
