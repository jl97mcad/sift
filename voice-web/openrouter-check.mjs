// Every OpenRouter chat call names its allowed providers, and a model with none is never sent.
// Run: node openrouter-check.mjs (no network: fetch is replaced; the key is a dummy).
import assert from "node:assert";
import { readFileSync } from "node:fs";
import { CHAT_URL, chatBody, providerFor } from "./openrouter.mjs";
import { respond } from "./front.mjs";
import { spokenSummary } from "./chief.mjs";
import { summariseCall } from "./memory.mjs";
import { look, web } from "./reader.mjs";

process.env.OPENROUTER_API_KEY = "test-not-a-key";
const sent = [];
globalThis.fetch = async (url, init) => {
  assert.equal(String(url), CHAT_URL);
  const body = JSON.parse(init.body);
  sent.push(body);
  if (body.stream) return new Response(`data: ${JSON.stringify({ choices: [{ delta: { content: "Hi." } }] })}\n\ndata: [DONE]\n\n`);
  return Response.json({ choices: [{ message: { content: "- A note." } }] });
};

const base = { person: "Alex", frontModel: "deepseek/deepseek-v4.1-flash", reader: { model: "deepseek/deepseek-v4-flash" } };
const callers = {
  front: (c) => respond(c, [], "Hello?", {}, () => {}),
  chief: (c) => spokenSummary(c, "The plan is merged."),
  memory: (c) => summariseCall(c, [{ role: "user", text: "Remember the plan." }]),
  readerWeb: (c) => web(c, { action: "search", query: "weather" }),
  readerLook: (c) => look(c, "What changed?"),
};

// Defaults: each default model runs only on its first-party provider.
for (const [name, call] of Object.entries(callers)) {
  sent.length = 0;
  await call(base);
  assert.ok(sent.length >= 1, `${name} sent nothing`);
  for (const body of sent) assert.deepEqual(body.provider, { only: ["deepseek"] }, `${name} unrestricted`);
}

// Configured: the list in config.json is what goes out, by model id first, then by maker.
const configured = { ...base, openrouterProviders: { "deepseek/deepseek-v4.1-flash": ["deepinfra"], deepseek: ["deepseek"] } };
sent.length = 0;
await callers.front(configured);
assert.deepEqual(sent[0].provider, { only: ["deepinfra"] });
assert.deepEqual(chatBody(configured, { model: "deepseek/deepseek-v4-flash" }).provider, { only: ["deepseek"] });
assert.deepEqual(providerFor(base, "anthropic/claude-haiku-5.5"), { only: ["anthropic"] });

// An empty list, or a model with no entry, refuses before anything is sent.
for (const providers of [{ deepseek: [] }, { deepseek: [" "] }, {}, { openai: ["openai"] }]) {
  const empty = { ...base, openrouterProviders: providers };
  for (const [name, call] of Object.entries(callers)) {
    sent.length = 0;
    await call(empty).catch((error) => assert.match(error.message, /No allowed OpenRouter provider/, name));
    assert.equal(sent.length, 0, `${name} sent without a provider`);
  }
}
assert.throws(() => providerFor(base, ""), /No allowed OpenRouter provider/);
assert.throws(() => providerFor(base, "openai/gpt-5"), /No allowed OpenRouter provider/);

// The Pipecat bot: its setup carries the restriction for its own model, and the bot sends it or stops.
const server = readFileSync(new URL("./server.mjs", import.meta.url), "utf8");
const bot = readFileSync(new URL("./pipecat/bot.py", import.meta.url), "utf8");
assert.match(server, /providerFor\(config, new URL\(request\.url, "http:\/\/bot"\)\.searchParams\.get\("model"\)\)/);
assert.match(bot, /\/bot\/setup", params=\{"model": model\}/);
assert.match(bot, /"provider": provider\}/);
assert.match(bot, /if not provider\.get\("only"\):\s+raise RuntimeError/);
// No chat completion is posted anywhere but through the helper.
for (const file of ["front.mjs", "chief.mjs", "memory.mjs", "reader.mjs", "server.mjs", "speech.mjs", "tools.mjs", "asks.mjs", "digest.mjs"]) {
  assert.ok(!readFileSync(new URL(`./${file}`, import.meta.url), "utf8").includes("chat/completions"), `${file} posts directly`);
}
console.log("ok");
