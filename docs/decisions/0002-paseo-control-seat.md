# 0002 — Control seat through the Paseo CLI

- Status: accepted
- Date: 2026-11-05

## Context

A pinned chat with Control would make the panel a single place to talk to a
running agent. Paseo is already installed on the machines that would use it and
exposes `paseo send`, `paseo logs`, `paseo inspect`. The alternative is to talk
to the Paseo daemon's socket directly, which is undocumented and versioned with
the daemon.

## Decision

Store an optional seat in `state.json` (`agent id` + title). Drive it through
the CLI with a restricted PATH so it works from a GUI app:

- `paseo inspect <id> --json` to validate the id and take its name.
- `paseo send <id> --prompt <text> --no-wait --json` to send.
- `paseo logs <id> --tail 60` to read the transcript. Paseo 0.14 prints
  prompts as `[Message received]`, assistant text untagged, and tool chatter
  behind `[Shell]`/`[Thought]`/`[Workflow]` tags, so the parser maps those
  explicitly and skips the rest.

The seat is off by default and hidden behind a triple click on the version
label, or `sift control set`.

## Consequences

- No daemon protocol to reverse engineer; works with any Paseo version that
  keeps the CLI surface.
- Requires Paseo on the same Mac; the app degrades to normal chats without it.
- `paseo logs` is a rendered transcript: long entries are abbreviated with
  `...`. Tool and thought events are dropped, but the latest one is surfaced as
  a one-line activity ("running a command…") in the Control header.
- Sending creates a real prompt on that agent, so the seat is a live control
  channel, not a read-only view.
