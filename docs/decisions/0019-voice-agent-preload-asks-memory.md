# 0019 — The voice agent reads ahead, answers asks by voice and remembers calls

- Status: accepted
- Date: 2026-11-10

## Context

On calls, "what needs me" waited on a needs-queue lookup (about 5 s to first audio), lookups often
started in silence, Jon's yes to an open ask was handed to Control as a task, answers sometimes
linked facts the data didn't link, and nothing carried over from one call to the next.

## Decision

Each feature is off unless its config key is set, so other installs are unchanged.

- `preload: true`: when a call connects, the bot fetches `/bot/context` from the side port. The
  server reads the needs queue, the sessions list (compact) and each source marked `preload: true`
  in parallel, with a 4 s cap on each. It adds today's and yesterday's call notes and caps the whole
  block at about 1,500 tokens. The bot adds it to the system message as a dated "Already read for
  this call" snapshot. The prompt says to answer from it and to read again for fresh or detailed
  answers. `catch_up` returns the same reads, fresh, in one call.
- `filler: true`: when a tool starts and nothing has been said this turn, the bot says a short line
  ("One sec.") once, with `append_to_context=False`, so the tool call and its result stay next to
  each other in the context. Never for `skill`, `stay_quiet` or `end_conversation`.
- Lookups run at once. Pipecat runs function calls in parallel by default, and the server's
  `respond` now runs one round's calls together too.
- `asks.listCommand` + `asks.answerCommand`: `answer_ask` (plan, the person's exact words,
  confirmed). The first call writes nothing and returns a read-back that names what a yes allows.
  A write needs `confirmed: true` with the same words, within 10 minutes of that read-back. When the
  caller passes what was heard, every word of the answer must appear in it. The server writes
  `board answered <plan> --ask-id <id> --text <words> --summary <fixed plan wording> --action
  answer`. The argv goes as JSON on the stdin of `answerCommand`, so the words never pass through a
  shell. The summary is one of three fixed lines (approved, declined, gave direction) and never
  contains the person's words. Afterwards the server reads asks.json again to confirm the ask is no
  longer open. A failed write is reported and never retried. With `asks.dryRun: true` or
  `SIFT_ASKS_DRY_RUN=1`, everything runs except the write, and the server logs the argv instead.
- Tool output is digested in code before the model reads it. `read_session` shows the latest ask
  and the latest reply, with the tool steps since that ask on one line. `paseo logs` collapses each
  run of tool steps to one line. `sessions` shows counts, seats, what's running and idle plan leads.
  Markup, links, code and JSON are dropped from all three. The prompt adds grounding rules: say
  only what the data says, name the source, don't link facts the data doesn't link, and say "I
  don't have that" instead of guessing.
- `memory.dir`: when a call ends, the bot posts its user and assistant turns to `/bot/call-ended`.
  One DeepSeek Flash call (reasoning off) turns them into 5 to 10 bullet lines, with secrets
  scrubbed. The lines go to `<dir>/YYYY-MM-DD.md` (file 0600, folder 0700) under a heading with
  the call's start time. `recall` searches those notes by keyword. When `memory.dejaCommand` is
  set, it also searches the person's deja history, with the query passed on stdin.
- `voice-web/evals/` holds questions from real calls, with invented fixtures. The repo is public,
  so no live output goes in. `node evals/run.mjs` runs them through `respond` with every tool
  stubbed and scores tool choice and banned behaviour. `--front <dir>` runs another copy of the
  code against the same cases.

## Consequences

- Nothing is written for a real answer until the person says yes to a read-back. The first real
  write on Jon's install will be his own.
- A call's first answer can come from a snapshot up to a call's length old. The prompt says to read
  again when it matters.
- deja searches take about 15 s, so `recall` waits up to `memory.dejaTimeoutSeconds` (default 20).
