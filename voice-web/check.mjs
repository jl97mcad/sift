import assert from "node:assert";
import { plain, pieces, settledLength, stepLabel, progressLine, isPhantom, looksUnfinished } from "./speech.mjs";
assert.equal(plain("**Shop** is [merged](http://x).\n```sh\nrm -rf /\n```"), "Shop is merged.");
assert.deepEqual(pieces("One. Two. Three."), ["One.", "Two. Three."]);
assert.equal(settledLength("Done. Still writ"), 6);
assert.equal(settledLength("Run this.\n```sh\nrm -rf /\n"), 10);
assert.equal(stepLabel({ type: "tool_call", name: "Bash", detail: { command: "ssh paseo@x cat STATE.md" } }), "Reading the god session's notes");
assert.equal(stepLabel({ type: "assistant_message", text: "x" }), null);
assert.equal(stepLabel({ type: "tool_call", name: "task_notification", detail: {} }), null);
assert.equal(stepLabel({ type: "tool_call", name: "Bash", detail: { type: "shell" } }), "Running a command");
assert.equal(progressLine("Looking in Pocket", 90), "Still looking in Pocket. It's taking a while, but it's still going.");
assert.ok(isPhantom("Продолжение следует..."));
assert.ok(isPhantom("Bye. Bye. Okay. you"));
assert.ok(isPhantom(" Thank you."));
assert.ok(!isPhantom("Okay, check on the Mattel plan."));
assert.ok(!isPhantom("Bye for now, but first queue the plan."));
assert.ok(!isPhantom("Bye."));
assert.ok(!isPhantom("Привет", "ru"));
assert.ok(looksUnfinished("Take a look at"));
assert.ok(looksUnfinished("Take a look at the..."));
assert.ok(!looksUnfinished("Take a look at the god chat and the focuses it's raised."));
assert.ok(!looksUnfinished("What needs me?"));
assert.ok(!looksUnfinished("What is this for?"));
assert.ok(!looksUnfinished("Turn it on."));
console.log("ok");

// Paseo CLI by voice: reads run, actions wait for a yes, the rest is refused.
import { plan, skills, skill, words } from "./tools.mjs";
const cfg = { person: "Alex", paseo: { hosts: { main: "127.0.0.1:6767" } } };
assert.deepEqual(words(`send abc "hi there" --x`), ["send", "abc", "hi there", "--x"]);
assert.deepEqual(plan(cfg, { command: "ls" }).args, ["--host", "127.0.0.1:6767", "--no-color", "ls", "-g"]);
assert.deepEqual(plan(cfg, { command: "paseo agent logs abc -f --tail 500" }).args.slice(3), ["logs", "abc", "--tail", "40"]);
assert.deepEqual(plan(cfg, { command: "send abc hello" }).args.slice(3), ["send", "abc", "hello", "--no-wait"]);
assert.ok(plan(cfg, { command: "delete abc" }).refused);
assert.ok(plan(cfg, { command: "archive abc" }).refused);
assert.ok(plan(cfg, { command: "run 'do a thing'" }).refused);
assert.ok(plan(cfg, { command: "schedule delete x", confirmed: true }).refused);
assert.ok(plan(cfg, { command: "stop abc" }).refused); // no yes yet
assert.ok(plan(cfg, { command: "stop --all", confirmed: true }).refused);
assert.deepEqual(plan(cfg, { command: "stop abc", confirmed: true }).args.slice(3), ["stop", "abc"]);
assert.ok(plan(cfg, { command: "ls --host evil:1" }).refused);
assert.ok(plan(cfg, { command: "ls", host: "nope" }).refused);
assert.ok(skills({}).some((s) => s.name === "paseo" && s.description));
assert.ok(skill({}, { name: "catch-up" }).includes("catch_up"));
console.log("tools ok");
assert.deepEqual(words(`send abc don't deploy`), ["send", "abc", "don't", "deploy"]);
console.log("apostrophe ok");

// Digests: the latest ask and reply lead, tool steps collapse to a line, noise goes.
import { cleanText, commandGist, contextBlock, digestDeja, digestLogs, digestSession, digestSessions } from "./digest.mjs";
{
  const now = Date.parse("2026-11-10T12:00:00Z");
  const agent = { id: "7abd1f52aaaa", title: "Jon's Control — takeover after limit", status: "running", updatedAt: "2026-11-10T11:58:00Z" };
  const items = [
    { type: "assistant_message", text: "Earlier: plans queued." },
    { type: "user_message", text: "<board-runner>Pick up from the handoff</board-runner>" },
    { type: "tool_call", name: "Bash", detail: { command: "ssh x cat STATE.md" } },
    { type: "tool_call", name: "Bash", detail: { command: "board show JON-1" }, status: "failed" },
    { type: "tool_call", name: "Read", detail: { path: "/a/b.md" } },
    { type: "reasoning", text: "thinking hard" },
    { type: "assistant_message", text: "**Picked up.** See [PR](https://github.com/x/y/pull/1).\n```sh\nrm -rf /\n```\n{\"id\":\"0123456789abcdef0123\",\"payload\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}" },
  ];
  const d = digestSession(agent, items, "main", now);
  assert.ok(d.startsWith("Jon's Control — takeover after limit (running, on main, last active 2 min ago)"), d);
  assert.ok(d.includes("Latest ask: Pick up from the handoff"));
  assert.ok(d.includes("Latest reply: Picked up. See PR. [code] [data]"), d);
  assert.ok(d.includes("Since the ask: 3 tool steps (Bash ×2, Read), last: Read b.md; 1 failed"), d);
  assert.ok(d.includes("Earlier reply: Earlier: plans queued."));
  assert.ok(!/rm -rf|https:|thinking/.test(d));
  assert.ok(digestSession({ ...agent, status: "running" }, [{ type: "user_message", text: "Do X" }], undefined, now).includes("No reply to it yet; still working."));
  const logs = digestLogs(agent, items, 15, "main", now).split("\n");
  assert.deepEqual(logs.slice(1), ["Said: Earlier: plans queued.", "Asked: Pick up from the handoff", "Tools: 3 tool steps (Bash ×2, Read), last: Read b.md; 1 failed", "Said: Picked up. See PR. [code] [data]"]);
  const hosts = [{ name: "main", agents: [
    { id: "aaaaaaaa1", title: "Control", status: "idle", labels: { seat: "control" }, updatedAt: "2026-11-10T11:00:00Z" },
    { id: "bbbbbbbb1", title: "JON-1 lead: Do a thing", status: "running", updatedAt: "2026-11-10T11:59:00Z" },
    { id: "cccccccc1", title: "JON-2 lead: Other", status: "idle", updatedAt: "2026-11-10T10:00:00Z" },
    { id: "dddddddd1", title: "JON-3 worker", status: "idle", updatedAt: "2026-11-10T10:00:00Z" }] }, { name: "mac", error: "offline" }];
  const s = digestSessions(hosts, { now });
  assert.ok(s.includes("On main: 4 live, 1 running."));
  assert.ok(s.includes(`Seats: control aaaaaaaa idle, 1 h ago "Control"`), s);
  assert.ok(s.includes("Running: bbbbbbbb JON-1 lead: Do a thing"));
  assert.ok(s.includes("Idle plan leads: cccccccc JON-2 lead: Other"));
  assert.ok(s.includes("Other idle sessions: 1"));
  assert.ok(s.includes("On mac: unavailable (offline)"));
  const c = digestSessions(hosts, { compact: true, now });
  assert.ok(c.endsWith("On mac: unavailable (offline)") && c.includes("Seats: control idle, 1 h ago\n") && c.includes("Idle plan leads: JON-2\n") && !c.includes("aaaaaaaa"), c);
  assert.equal(commandGist("cd /home/paseo/.paseo/worktrees/2j/jon-4171 && git status --short | head; ls"), "git status --short | head");
  assert.equal(commandGist("cat /home/paseo/.config/x/STATE.md"), "cat …/STATE.md");
  assert.equal(cleanText("---\na: b\n---\n# Title\n- [ ] one `code`", { keepLines: true }), "Title\n- one code");
  const deja = digestDeja("<deja-recall>\nRecalled history from prior sessions.\n1. [pi] home/paseo · 01a14db6 · 4 matches · updated 2026-10-18 (Oct 18)\n[relevance]\n- The proxy goes on after the canary login test passes, said Jon\n  files it touched: /x\n</deja-recall>");
  assert.equal(deja, "* home/paseo, 2026-10-18:\n  The proxy goes on after the canary login test passes, said Jon");
  assert.equal(digestDeja("(answering from the index)\n[claude] imported:Developer/jons-control · Nov 8 · imported-…f753b66056 — 19 matches\n  … one snippet that is long enough to keep …\n  … two snippet that is long enough to keep …\n  … three snippet that is long enough to drop …"),
    "* Developer/jons-control, Nov 8:\n  one snippet that is long enough to keep\n  two snippet that is long enough to keep");
  const block = contextBlock({ at: "12:00 on Tuesday", needs: "JON-1: Yes?", sessions: "On main: 1 live", sources: [{ name: "focus list", text: "x".repeat(5000) }], memory: "- decided A", person: "Jon" });
  assert.ok(block.startsWith("Already read for this call, at 12:00 on Tuesday."));
  assert.ok(block.includes("JON-1: Yes?") && block.includes("decided A") && block.length <= 6001);
  assert.ok(contextBlock({ at: "now", memory: `old ${"x ".repeat(800)} newest` }).endsWith("newest"));
  assert.ok(digestSessions([{ name: "h", agents: [{ id: "eeeeeeee1", title: "Fix **bold** at https://x.y/z", status: "running" }] }]).includes("eeeeeeee Fix bold at [link]"));
  console.log("digest ok");
}

// Answering asks: a read-back first, the write only after a yes to it, the card wording never his words.
import { answerArgv, answerAsk, clearYes, consequence, findAsks, forget, notHeard, openAsks, planOf, summaryFor } from "./asks.mjs";
{
  const store = { asks: { a: { ask_id: "a1", plan: "JON-4119", state: "open", kind: "outside_send", title: "Send the partner note", question: "May I send it?", recommendation: "Send it.", created_at: "1" },
    b: { ask_id: "b1", plan: "JON-4164", state: "open", kind: "product", title: "Roll out", question: "Roll out?", recommendation: "Decide.", created_at: "2" },
    c: { ask_id: "c1", plan: "JON-4164", state: "open", kind: "product", title: "Second one about runners", question: "Runners?", recommendation: "Decide.", created_at: "3" },
    d: { ask_id: "d1", plan: "JON-4000", state: "answered", title: "Old" } } };
  assert.equal(openAsks(JSON.stringify(store)).length, 3);
  assert.deepEqual(planOf("John 4119"), { prefix: "JON", number: "4119" });
  assert.deepEqual(planOf("4119"), { prefix: null, number: "4119" });
  assert.equal(findAsks(openAsks(JSON.stringify(store)), "jon-4164").length, 2);
  assert.equal(findAsks(openAsks(JSON.stringify(store)), "JON-4164", "2")[0].ask_id, "c1");
  assert.equal(findAsks(openAsks(JSON.stringify(store)), "JON-4164", "runners")[0].ask_id, "c1");
  assert.equal(summaryFor("Yes, send it."), "Owner answered by voice: approved the recommendation.");
  assert.equal(summaryFor("No, don't send it."), "Owner answered by voice: declined the recommendation.");
  assert.equal(summaryFor("Yes but not yet"), "Owner answered by voice: gave direction.");
  assert.equal(summaryFor("Use the green one"), "Owner answered by voice: gave direction.");
  for (const words of ["Yes, send it.", "No, don't", "Use the green one"]) assert.ok(!summaryFor(words).toLowerCase().includes(words.toLowerCase().replace(/[.,]/g, "")));
  const ask = store.asks.a;
  assert.deepEqual(answerArgv(ask, "Yes, send it. It's fine; $(rm -rf /)"), ["board", "answered", "JON-4119", "--ask-id", "a1", "--text", "Yes, send it. It's fine; $(rm -rf /)", "--summary", "Owner answered by voice: approved the recommendation.", "--action", "answer"]);
  assert.ok(consequence(ask).startsWith("This lets Control send it outside the company"));
  assert.deepEqual(notHeard("Consider JON-4122 done", "Consider John forty-one twenty-two done.", "JON 4122"), []);
  assert.deepEqual(notHeard("approved", "Yes, send it"), ["approved"]);
  const writes = [], logs = [];
  let state = "open";
  const deps = { list: async () => JSON.stringify({ asks: { ...store.asks, a: { ...ask, state } } }), write: async (argv) => { writes.push(argv); state = "answered"; return { code: 0, out: "", err: "" }; }, log: (l) => logs.push(l) };
  const cfg = { person: "Jon", asks: { listCommand: "x", answerCommand: "y" } };
  forget();
  const first = await answerAsk(cfg, { plan: "JON 4119", answer: "Yes, send it", _heard: "Answer John 4119: yes, send it" }, deps);
  assert.ok(first.includes("Nothing is written yet") && first.includes("Recording your answer to Send the partner note: 'Yes, send it'. This lets Control send it outside the company"), first);
  assert.equal(writes.length, 0);
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Approved", _heard: "yes send it" }, deps)).startsWith("Not their words"));
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it", confirmed: true }, deps)).includes("no record of the person's reply")); // no turn given
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it, now", confirmed: true, _turn: 9, _last: "yes" }, deps)).includes("Not recorded yet")); // a yes to other words
  assert.equal(writes.length, 0);
  await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it" }, deps);
  const dry = await answerAsk({ ...cfg, asks: { ...cfg.asks, dryRun: true } }, { plan: "JON-4119", answer: "Yes, send it", confirmed: true, _turn: 9, _last: "Yes." }, deps);
  assert.ok(dry.startsWith("Dry run") && writes.length === 0 && logs.at(-1).includes('"--ask-id","a1"'), dry);
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it", confirmed: true, _turn: 9, _last: "Yes." }, deps)).includes("Not recorded yet")); // the dry run used up the read-back
  await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it" }, deps);
  const done = await answerAsk(cfg, { plan: "JON-4119", answer: "Yes, send it", confirmed: true, _turn: 9, _last: "Yes, go ahead." }, deps);
  assert.equal(done, "Recorded: Jon's answer to Send the partner note. The ask is now answered.");
  assert.equal(writes.length, 1);
  assert.ok((await answerAsk(cfg, { plan: "JON-4164", answer: "Yes" }, deps)).includes("has 2 open asks"));
  assert.ok((await answerAsk(cfg, { plan: "JON-9999", answer: "Yes" }, deps)).includes("no open ask"));
  // A yes in the same turn as its read-back (the model chaining calls) or a reply that isn't a yes never writes.
  state = "open";
  await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", _turn: 3 }, deps);
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", confirmed: true, _turn: 3, _last: "Yes" }, deps)).includes("hasn't answered the read-back yet"));
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", confirmed: true, _turn: 4, _last: "Yeah, hang on, what's the time?" }, deps)).includes("isn't a clear yes"));
  assert.equal(writes.length, 1);
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", confirmed: true, _turn: 4, _last: "Yes, record it." }, deps)).startsWith("Recorded"));
  assert.equal(writes.length, 2);
  assert.ok(clearYes("Yes, go ahead.") && clearYes("Record it please") && !clearYes("No") && !clearYes("Yes but don't send it") && !clearYes("What's the time?") && !clearYes("Please check the time") && !clearYes("Right, what else?"));
  assert.equal(summaryFor("I don't want to send it"), "Owner answered by voice: declined the recommendation.");
  assert.deepEqual(notHeard("Send 5 copies", "send copies"), ["5"]);
  assert.deepEqual(notHeard("Send five", "send it"), ["five"]);
  assert.deepEqual(notHeard("yes JON9999", "yes"), ["jon9999"]);
  assert.deepEqual(notHeard("JON-4164: yes", "John forty-one sixty-four yes", "JON-4164"), []);
  state = "open";
  await answerAsk(cfg, { plan: "JON-4119", answer: "Yes" }, deps);
  const failed = await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", confirmed: true, _turn: 9, _last: "yes" }, { ...deps, write: async () => ({ code: 1, out: "", err: "Linear 500" }) });
  assert.ok(failed.startsWith("The write failed (Linear 500). Don't retry"), failed);
  state = "open";
  // A read-back from another call never counts.
  await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", _turn: 1, _call: "call-a" }, deps);
  assert.ok((await answerAsk(cfg, { plan: "JON-4119", answer: "Yes", confirmed: true, _turn: 2, _last: "Yes", _call: "call-b" }, deps)).includes("Not recorded yet"));

  console.log("asks ok");
}

// Memory: dated notes, keyword recall, secrets scrubbed.
import { bullets, dayAndTime, recall as recallMemory, recentMemory, scoreMemory, scrub, transcriptText, writeMemory } from "./memory.mjs";
import { mkdir, mkdtemp, readFile as readText, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
{
  assert.deepEqual(dayAndTime("2026-11-10T23:30:00Z", "Europe/London"), { day: "2026-11-10", time: "23:30" });
  assert.deepEqual(dayAndTime("2026-07-10T23:30:00Z", "Europe/London"), { day: "2026-07-11", time: "00:30" });
  assert.equal(scrub("password is hunter2 and key sk-or-v1-abcdefghijklmnop"), "password is [redacted] and key [redacted]");
  const files = [{ day: "2026-11-09", text: "## Call at 22:10\n- Jon chose green for the header.\n- Restore drill approved." }, { day: "2026-11-10", text: "## Call at 09:35\n- The Cloudflare proxy goes on after the canary test." }];
  const hits = scoreMemory(files, "what did I decide about the header colour green");
  assert.equal(hits[0].line, "Jon chose green for the header.");
  assert.equal(hits[0].heading, "Call at 22:10");
  assert.equal(scoreMemory(files, "cloudflare")[0].day, "2026-11-10");
  assert.deepEqual(scoreMemory(files, "what did we say"), []);
  assert.equal(bullets("Here you go:\n- One\n* Two token: abc\nnot a bullet"), "- One\n- Two token: [redacted]");
  assert.equal(transcriptText([{ role: "user", text: "the password is hunter2" }], "Jon"), "Jon: the password is [redacted]");
  assert.equal(transcriptText([{ role: "user", text: "(The call just connected. Greet Jon.)" }, { role: "user", text: "What needs me?" }, { role: "assistant", text: "Two things." }], "Jon"), "Jon: What needs me?\nAssistant: Two things.");
  const dir = await mkdtemp(join(tmpdir(), "voice-memory-"));
  const cfg = { person: "Jon", timezone: "Europe/London", memory: { dir: join(dir, "m") } };
  const now = Date.now();
  await mkdir(cfg.memory.dir, { mode: 0o755 });
  const file = await writeMemory(cfg, now, "- Jon chose green.");
  await writeMemory(cfg, now, "- Second call.");
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(cfg.memory.dir)).mode & 0o777, 0o700);
  const text = await readText(file, "utf8");
  assert.ok(text.startsWith(`# ${dayAndTime(now, "Europe/London").day}\n`) && (text.match(/## Call at/g) ?? []).length === 2);
  assert.ok((await recentMemory(cfg)).includes("Today:") && (await recentMemory(cfg)).includes("Second call."));
  assert.ok((await recallMemory(cfg, { query: "green" })).includes("Jon chose green."));
  assert.equal(await recentMemory({ person: "Jon" }), "");
  await writeMemory(cfg, Date.parse("2026-03-29T12:00:00Z"), "- The day before the clocks changed.");
  assert.ok((await recentMemory(cfg, Date.parse("2026-03-30T00:30:00+01:00"))).includes("Yesterday:\n## Call at 13:00\n- The day before the clocks changed."));
  console.log("memory ok");
}
