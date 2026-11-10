# 0020 — The voice agent reads deeper on its own

- Status: accepted
- Date: 2026-11-10

## Context

Sift Voice could read sessions, its own call notes, deja and three configured sources. Anything
deeper (a plan, a PR's checks, a note, the server, the web) went to a worker, which cost a
hand-off's delay for what is only reading.

## Decision

`config.reader` turns on read-only tools in `voice-web/reader.mjs`, each off unless its own key is set:

- `plan`, `plan_search`: Linear through the board app's cached token (`linearTokenFile`). Only
  `query` documents are sent; the token is never refreshed here and Jon's personal key is not used.
- `github`: `gh pr list`, `view` and `checks` on a validated `owner/name`. No reruns or writes.
- `vault`: search through recall-service `/v1/recall` with scope `vault`; read one `.md`/`.txt` note by
  path under `vault.root`. **The `Notes/God session` folder is excluded everywhere**: any path with a
  "God session" segment (any case, spacing, encoding, backslash) is refused before and after
  resolving links, and search hits from it are dropped.
- `server_status`: load, disk, configured services, status files and fixed read-only commands.
- `web`: search through OpenRouter's web plugin, and fetch one public page (no private or tailnet
  addresses, redirects re-checked, size capped).
- `look_into`: a background read. A cheap model (`reader.model`, default DeepSeek V4 Flash) chains
  these tools plus sessions, read_session, read_source and recall, at most `maxSteps` model calls
  (default 6) and `maxSeconds` (default 75), a few cents at most. It is a job like a hand-off:
  steps are spoken through the progress path ("I'm checking GitHub"), the answer through `finished`.

Every result is passed through `clean()`: secrets, emails and phone numbers are redacted before a
model, speech or a log sees them. `delegate` is described as actions only (writes, sends, merges,
deploys), Lark and Mac-only things; the prompt and skills say to read first. The prompt also tells
the front model what "that" and "it" refer to: the last plan, PR, note or topic of this call.

## Consequences

- The tools have no write path to remove: Linear refuses non-queries, GitHub allows three verbs.
- The look's token use is logged (`look finished: n steps, n tokens`), never its content.
