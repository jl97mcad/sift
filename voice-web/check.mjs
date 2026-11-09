import assert from "node:assert";
import { plain, pieces, latestReply, settledLength, stepLabel, progressLine } from "./speech.mjs";
assert.equal(plain("**Shop** is [merged](http://x).\n```sh\nrm -rf /\n```"), "Shop is merged.");
assert.deepEqual(pieces("One. Two. Three."), ["One.", "Two. Three."]);
assert.equal(latestReply([{ item: { type: "assistant_message", text: "old" } }, { item: { type: "user_message", text: "q" } },
  { item: { type: "reasoning", text: "x" } }, { item: { type: "assistant_message", text: "A." } }, { item: { type: "assistant_message", text: "B." } }], "q"), "A.\n\nB.");
assert.equal(latestReply([{ item: { type: "user_message", text: "older" } }, { item: { type: "assistant_message", text: "old" } }], "q"), "");
assert.equal(settledLength("Done. Still writ"), 6);
assert.equal(settledLength("Run this.\n```sh\nrm -rf /\n"), 10);
assert.equal(stepLabel({ type: "tool_call", name: "Bash", detail: { command: "ssh paseo@x cat STATE.md" } }), "Reading the god session's notes");
assert.equal(stepLabel({ type: "assistant_message", text: "x" }), null);
assert.equal(stepLabel({ type: "tool_call", name: "task_notification", detail: {} }), null);
assert.equal(stepLabel({ type: "tool_call", name: "Bash", detail: { type: "shell" } }), "Running a command");
assert.equal(progressLine("Looking in Pocket", 90), "Still looking in Pocket. It's taking a while, but it's still going.");
console.log("ok");
