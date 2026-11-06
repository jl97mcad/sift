# 0005 — Needs you from Control's asks and Paseo permissions

- Status: superseded in part by 0006 (seen needs) and 0007 (where asks are read)
- Date: 2026-11-05
- Supersedes: 0003's rule that a "waiting" status pulses the head

## Context

Sift pulsed when Paseo reported a waiting status. Paseo has no such status:
its agent state is `initializing|idle|running|error|closed`, plus
`pendingPermissions` and `attentionReason` (`finished|error|permission`).
Paseo's own needs-input bucket is a pending permission request.

Questions for the owner already have one path: the Control runner's ask
rail (`board ask`). Asks live in the runner's journal and are answered on the
work board. A separate "needs you" status was retired in favour of asks.

## Decision

Needs you is live state, not a cue Sift invents:

- the seated Paseo session has a pending permission request
  (`pendingPermissions`, removed by the daemon when resolved; the stored
  `attentionReason` is only cleared by opening the session, so it is not used), or
- the runner has an open ask. This first version read the runner's published
  open-asks report through a private reporting API configured on one Mac;
  0007 replaced that with a read from the Control's own daemon.

Unseen needs pulse the edge head and rail. Each open ask is shown with its
plan, title, question, recommendation and a link to answer it on the board.
Sift never answers or withdraws asks. A missing source is "off". A stale or
unreadable one is "unknown", never "nothing needs you". Each ask notifies at
most once, only while unseen, with the existing opt-in and focus rules.
Replies keep the quiet dot (0003).

## Consequences

- No new service, credential or dependency.
- Question marks in replies, thoughts or log lines never create attention.
