import assert from "node:assert";
import { plain, pieces, latestReply } from "./speech.mjs";
assert.equal(plain("**Shop** is [merged](http://x).\n```sh\nrm -rf /\n```"), "Shop is merged.");
assert.deepEqual(pieces("One. Two. Three."), ["One.", "Two. Three."]);
assert.equal(latestReply([{ item: { type: "assistant_message", text: "old" } }, { item: { type: "user_message", text: "q" } },
  { item: { type: "reasoning", text: "x" } }, { item: { type: "assistant_message", text: "A." } }, { item: { type: "assistant_message", text: "B." } }], "q"), "A.\n\nB.");
assert.equal(latestReply([{ item: { type: "user_message", text: "older" } }, { item: { type: "assistant_message", text: "old" } }], "q"), "");
console.log("ok");
