# Sift — Opus continuation

## Task and ownership

Continue implementation in **/Users/jonathan/Developer/sift-sol**, branch
**sol-polish**. This is an exclusive writer handoff from Codex Sol. Sol stops
editing before your launch. Do not edit /Users/jonathan/Developer/lark-mini,
install, push, merge or change another agent's checkout. Commit in stages here.
Read the repo instructions and relevant accepted ADRs first. Jon's explicit
implementation request supersedes AGENTS.md's setup-only restriction.

Jon explicitly requested **Claude Opus 5.5 xhigh** for this continuation.

## Jon's latest requests, in priority order

1. **Inspect the existing needs-you system before implementing more.** Jon
   repeated this during handoff: "Also, it should Look at the needs you stuff."
   Find the actual implementation, inputs and policy with recall/deja and
   read-only source inspection. Reuse existing authoritative state and decisions
   instead of inventing a second attention system. The prior system has NOT yet
   been investigated by Sol. jons-control runner/plugins are reserved to Control;
   this task may read them but should implement the integration in Sift.
2. Control handed off to **7d3ed881-9543-405d-8ff5-d5390f43ca86**. Make Sift follow
   the correct current Control session and automate future handoffs. Inspect
   authoritative seat/session-link metadata and actual host; don't guess from a
   title or arbitrary newest session. No switch has been made yet. Verify
   read-only; do not send this Control session a prompt merely to test routing.
3. Improve what arrives from Lark and Paseo: readable useful replies, proper
   sender/provenance, preserved Markdown, no thought/tool noise or raw transport
   envelopes. Consecutive same-sender messages in the same minute should group.
4. Keep Sift a useful, minimal companion at the screen edge. New Control replies
   should be subtle; **Needs you is a pulse**, not just a dot. No auto-opening.
5. An ongoing action should visibly be alive. Jon highlighted the frozen
   "running a command" row, said "no motion or animation on the actions", then
   clarified **"it needs it"**: implement a small activity indicator for current
   work, not message animation or constant movement. Derive the label from current
   state rather than an old tool log. Avoid duplicated header/footer status.

Jon asked whether a small local model such as Cactus could distill Control.
This was a question, NOT permission to load one. **Never start, download or load
a local model without asking Jon every time.** None was added. First improve the
source fidelity and presentation. Originals must remain accessible if a future
optional summarizer is approved.

## Hard stop: no more screen interaction

Jon said "whoaaaa you're taking over my screen a lot!" Sol stopped GUI testing,
closed its own Sift/System Settings processes, restored Reduce Motion false and
promised **no further GUI interaction**. Do not launch Sift, open windows,
activate apps, use CGEvent/Accessibility clicks, take screenshots or change OS
preferences. Continue with code, CLI and focused tests. Explicitly report the
remaining visual/runtime verification gaps. Don't ask for permission to resume
GUI work as a routine final step.

## Current state

Sift is a native SwiftUI macOS panel: green edge head, expanded 400x560 dark
panel, persistent rail (Inbox, Control, pinned chats, add/search/settings).
Preserve the merged Astra visual baseline. Executable is LarkMini, bundle Sift.
Starting baseline was 632bb10. Three local commits are complete:

- **58801b3 — Make Control attention quiet, persistent and readable.** Quiet
  unread vs needs-you attention, background polling, notification/sound settings,
  actual permission/error hints, focused suppression, readable Markdown blocks,
  truthful connection settings and persisted 400–480 width normalization.
- **85358fa — Discover hidden chats and save received message files safely.**
  Rotating batch of 3 loaded untracked chats, explicit All chats pagination and
  partial-scope label, authenticated resource download/save with pending/error,
  atomic safe replacement and 0600 files.
- **1f0b36b — Group chat messages and retain verified native interactions.**
  Lark same-sender/minute grouping; compact composers; expanded header drag,
  clamped persisted position; real live Reduce Motion observation; richer demo;
  actual delivered-notification receipt. Unverified collapsed-head drag removed.

See **docs/sol-handoff/README.md** and its evidence receipts for precise claims.
No install, push, live Lark send, local model or new dependency. Credentials,
tokens, state-file JSON formats and CLI output contracts remain unchanged.
Device-only UI preferences use UserDefaults.

## Uncommitted work you inherit

These changes compile and pass 13 tests, but are unfinished and NOT integrated
through the UI or accepted in the native app:

- Sources/LarkMini/PaseoClient.swift — replace lossy text-log parsing with a
  bounded typed timeline read using the **installed Paseo SDK**, native IDs and
  timestamps, only user/assistant messages. Derive a current action from typed
  entries. Adds AgentReading and AgentMessage speaker/displayText/group helpers.
- Sources/LarkMini/AgentProvider.swift — read snapshot replaces logs/activity;
  inspect/send/options remain. Check every caller.
- Sources/LarkMini/Store.swift — refreshControl uses one snapshot for messages,
  status/activity/hasOlder; publishes controlHasOlder. Clean indentation in the
  new refresh block. No automatic seat switch yet.
- Sources/LarkMini/ControlAttention.swift — last actual assistant message is the
  reply key; excludes interagent context. Existing content-fingerprint behavior
  still limits repeated identical replies.
- Sources/LarkMini/CLI.swift — digest/logs use snapshot, preserve output keys.
- Tests/LarkMiniTests/IncomingInformationTests.swift — regression fixture proves
  reasoning/tool output excluded, native IDs retained, Markdown unchanged.
- docs/sol-handoff/incoming-red.txt — old parser fails four assertions.
- docs/sol-handoff/incoming-current-tests.txt — current 13 tests, zero failures.

Do NOT assume these WIP changes are the final design. Keep the smallest correct
solution. If retaining the installed-SDK read adapter, document the new decision
in a new MADR ADR (likely 0004), superseding only the relevant reading choice in
0002 rather than editing accepted ADRs. Validate it through Swift end to end.

## Diagnosed information bug / actual Paseo evidence

The old text parser changed skip/user -> assistant on blank lines. It therefore
leaked multi-paragraph thoughts and tool output as Control replies. The installed
`paseo logs --json` advertises JSON but actually emits curated text. Its
`--filter text` includes reasoning. Logs also fetch all timeline entries before
tailing and lose message IDs/timestamps. Don't restore text parsing heuristics.

Read-only inspection of the installed /Applications/Paseo.app found the shipped
SDK path. An actual bounded 80-entry projected timeline read succeeded using:

```
const { connectToDaemon } = require(root + '/node_modules/@getpaseo/cli/dist/utils/client.js')
const { selectDaemonTarget } = require(root + '/node_modules/@getpaseo/cli/dist/utils/daemon-target.js')
const client = await connectToDaemon({ target: selectDaemonTarget({host}), timeout: 10000 })
const {agent} = await client.fetchAgent({agentId: id})
const timeline = await client.fetchAgentTimeline(agent.id, {
  direction: 'tail', limit: 80, projection: 'projected', timeout: 10000
})
// finally client.close()
```

`root` is /Applications/Paseo.app/Contents/Resources/app.asar.
Run with Paseo Helper executable under Contents/Frameworks, **not the GUI app**,
ELECTRON_RUN_AS_NODE=1 and PASEO_NODE_ENV=production; use its existing unpacked
dist/daemon/node-entrypoint-runner.js `node-script` runner. The current embedded
readerScript in PaseoClient contains exact proven paths and invocation.
This uses shipped auth/host resolution; never print credentials.

The actual sample contained 36 tool_call, 15 reasoning, 22 assistant_message,
5 user_message and 2 plugin entries. Only type counts/metadata were logged.
Each entry has item.type, ISO timestamp, seqStart/seqEnd; assistant/user have
item.messageId and text. Tool has status and detail.type (shell/read/etc).
Root has agent.status, hasOlder and entries. Current script projects only
user/assistant text into its output, never tool output or reasoning.

The raw private timeline probe in dist/paseo-input.json was removed at handoff.
dist/read-paseo.mjs and extracted installed JS source are disposable probes;
don't commit dist or use GUI helpers there. The JS read succeeded, but the new
**Swift read() adapter has only compiled, not been exercised live end to end**.

## Remaining implementation

- Wire ControlChatView/PaseoBubble to AgentMessage speaker/displayText/ts/groups
  and controlHasOlder. The current UI still labels non-mine items Control and
  renders message.text, so agent envelopes remain raw until this is fixed.
  Show clear partial history; no invented completeness. Original APIs retain
  actual user prompts, assistant replies and interagent context provenance.
- Add the tiny live action indicator requested above, using current status and
  action. Existing custom EnvironmentValues.siftReduceMotion is live and tested;
  use it rather than reworking motion. No further screen testing.
- LarkAPI.parseMessage and flattenPost still need information-fidelity work.
  Current flatten supports simple post only, loses hrefs/localized wrappers,
  and interactive cards become "Card". Preserve actual text, names, paragraphs,
  links and useful card title/body with honest unsupported placeholders. Do not
  invent card actions or change Lark API/token semantics. Check every caller and
  add focused fixtures. Mention replacement order can collide _user_1/_user_10.
- UpdateText.short strips URLs/paths/UUIDs/SHAs and flattens content; revisit
  to avoid losing facts or exposing raw Markdown markers. Plain text should not
  accidentally become arbitrary Markdown. Reuse existing ReplyBlock renderer.
- Inspect existing needs-you infrastructure and session handoff metadata FIRST;
  do not implement another rule based on question marks or every thought line.
- Verify/review the earlier notifications/discovery/files policies as necessary;
  avoid reopening already completed work without a reason.

## Original requirements still apply

- Notifications: no duplicates, none while expanded and focused, useful denied/
  unavailable feedback; notification and sound toggles. Distinguish a reply from
  actual needs input/finished-away attention. No log-line notifications.
- Settings: real Lark/Paseo seat/title/host/session/notification state. Width
  stored honestly. No regression to Astra styling.
- Header drag clamped and persisted. Collapsed head remains docked; its deliberate
  dragging was not verified and intentionally left out.
- Bounded rotating discovery and explicit All chats next page; state partialness.
- Received files open/download through authenticated message-resource API with
  failure/loading feedback. Don't expose tokens or alter resource semantics.
- Remove replaced dead code. No new local-model integration or dependency needed.
- Never change provider sending behavior, credential/token/state-file formats,
  CLI JSON contracts, or weaken existing tests.

## Verification and limits

Required final code checks in this worktree:

```
swift build
.build/debug/LarkMini --cli selftest
CFFIXED_USER_HOME=$PWD/dist/test-home swift test
```

All 10 original CLI selftests and the 3 original Inbox tests must remain intact.
Last committed state passed 12 tests, 10 selftests, swift build and make app.
Current WIP passes swift build and all **13 tests**. Re-run selftests after final
changes. Test receipts under docs/sol-handoff. A local make app is allowed as a
build if useful, but no launch; **never make install**.

Prior real-input verification: expanded header moved from (200,200) to (342,305);
OS Reduce Motion true gave 0 changed pixels vs 6367 with it false, then restored
false; actual Notification Center delivered list confirmed tests with sound
requested and silent. This proves delivered-list presence and sound metadata,
not audible playback or a visible banner.

Unverified: live Lark downloads/catalogue pagination, multi-monitor/restart drag
acceptance, notification-click navigation, denied permissions, duplicate/focus
policy on live traffic, final grouped/Markdown UI, the WIP adapter integration,
new Control switching and needs-you reuse. No more GUI may be used to close those
gaps; report them honestly.

Progress dashboard: paseo-progress T01/T02/T03 done with limitations; T04
"Make incoming Lark and Control information useful" is working. Continue it.
No Linear plan/PR/external send was created. No push is authorized.

## References already inspected

- https://reui.io/blocks/ai-agents/ai-chat — Jon's reference. Corner chat13's
  fixed composer/minimal launcher and chat10's structured answer patterns suit
  Sift; do not import a React UI into SwiftUI.
- https://open.larksuite.com/document/server-docs/im-v1/faq — localized rich post
  (`zh_cn`, title/content rows; text, a.href/text, at.user_id/user_name).
- https://open.larksuite.com/document/ukTMukTMukTM/uYzM3QjL2MzN04iNzcDN/send-message-card/send-messages-using-card-json-data
  — card header/title and div text elements. Use primary docs when unsure.
- Cactus Swift README supports macOS, but no model was loaded or approved.

## Acceptance and report

Complete source changes with focused meaningful tests and preserve contracts.
Make incoming messages useful and attention truthful using existing needs-you
and authoritative current-Control metadata. Record behavior and remaining gaps
under docs/sol-handoff, commit in stages on sol-polish, then report commit titles/
SHAs, what changed, what was actually checked and what remains unverified.
Local commits are not merged, installed or visually accepted. Never claim they
are. Jon values working behavior over description; keep the response concise.
