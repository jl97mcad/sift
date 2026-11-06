# 0007 — Open asks from the Control's own daemon

- Status: accepted
- Date: 2026-11-06
- Supersedes: the ask source in 0005

## Context

0005 read open asks from a private reporting API with a client configuration
that existed on one Mac. Any other person with their own Control could not
see their asks, and the app carried that installation's paths.

Sift already holds a connection to the Control's Paseo daemon for the
conversation. The runner that owns the asks runs beside that daemon, and its
`control-plugins` suite can serve read-only plugin RPCs.

## Decision

Read open asks in the same daemon session as the conversation:
`client.invokePluginRpc("control-plugins", "asks.open", {})`. The suite runs
the runner's own journal reader and returns open asks, oldest first, with id,
plan, title, question, recommendation and an http(s) board link.

- No `control-plugins` suite running on the daemon: asks are "off".
- An older suite without `asks.open`, an unreadable journal or a malformed
  reply: "unknown", never an empty list.
- Sift stays read-only: answers remain on the board.

## Consequences

- Each person's Sift sees exactly their own Control's asks, with no extra key,
  port or service, and no installation-specific path in the app.
- Asks need a `control-plugins` release that serves `asks.open` on that
  person's daemon.
- Asks refresh with the conversation, every few polls.
