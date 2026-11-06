# 0004 — Typed Paseo timeline and Control seat following

- Status: accepted
- Date: 2026-11-05
- Supersedes: the transcript-reading part of 0002 (`paseo logs` parsing) and
  0003's content fingerprint for replies

## Context

Sift parsed `paseo logs --tail 60`. That text changes speaker on blank lines,
so multi-paragraph thoughts and tool output appeared as Control replies.
`paseo logs --json` prints the same curated text. `--filter text` includes
reasoning. Logs fetch the whole timeline before tailing and lose message ids
and times. Paseo 0.14 has no CLI command for a typed, bounded timeline.

Control also hands off to a new session. The handoff starts the successor
with the Paseo label `seat=control`, records its id on the Control host, and
archives the old session. Sift kept reading the archived
session, whose timeline read times out.

## Considered options

1. Keep parsing logs with better heuristics.
2. Talk to the daemon's WebSocket protocol directly.
3. Run the installed Paseo app's own CLI client modules (`utils/client.js`,
   `daemon-target.js`, `agent-directory.js`) with its bundled Node runtime.
4. Follow the newest session whose title says "Control".
5. Read the Control host's own record of the current session.

## Decision

Option 3. One short script per refresh runs under the Paseo Helper executable
(`ELECTRON_RUN_AS_NODE=1`, its `node-script` runner). It uses the CLI's own
daemon target and auth. It calls `fetchAgent`, then a tail of 80 projected
timeline entries (CLI `logs`: up to 200). Only `user_message` and
`assistant_message` text leaves the script, with native message ids and
timestamps. Reasoning, tool calls and plugin entries never do; the newest
entry's type, status and tool kind give the current-step label. Credentials
are never printed. Sending stays `paseo send` (0002).

Reply attention keys on the native message id, not content.

For handoffs, follow Paseo's own seat label on the seat's host. When the seat
is archived and carries `seat=<value>`, list live sessions with that label.
Move the shared seat only if exactly one live session has it and the seat in
`state.json` is still the one that was read. Otherwise keep it and say it is
archived. Titles and "newest" are never used (rejects option 4).
That host record is authoritative, but a desktop client cannot reach it
without SSH, so option 5 is out.

Prompt provenance comes from Paseo metadata: an agent's message carries the
daemon's `paseo-system` envelope with the agent title. Paseo's apps id the
person's prompts `msg_<ms>_<random>`. Sift remembers hashes of its own sends
(device-local), because the CLI gives them random ids, as it does for scripts.
Other prompts show as compact, expandable automation context.

## Consequences

- Depends on the installed Paseo app layout (helper path, unpacked runner,
  CLI module paths). A Paseo update can break the read; it fails visibly with
  "Paseo conversation data is unavailable" and the seat keeps its last messages.
- Every refresh starts one helper process; the live read took about 1.7 s.
- An archived seat with zero or several live labelled sessions stays put
  until Paseo's state becomes unambiguous. Seats without a `seat` label are
  never moved.
- Prompts that a person sends through another CLI or script are shown as
  automation, not as theirs.
