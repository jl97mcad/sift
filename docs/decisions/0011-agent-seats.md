# 0011 — Agent seats: agents first, one live seat each

- Status: accepted
- Date: 2026-11-06
- Supersedes: the single-seat parts of 0002 (one optional `control` in
  `state.json`) and 0009 ("one helper per seat" now means one per configured
  seat)

## Context

Sift had one optional Control seat. The person runs several long-lived agents
(Control, Finance, others) that each hand off to new sessions of themselves,
and wanted Sift to be the place to talk to all of them, before Lark.

## Decision

- `state.json` holds `seats: [ControlSeat]` in rail order. A file with the old
  single `control` decodes as one seat. Each seat has a fixed `id` (its first
  agent id), a `name` and `color` the person chooses, and the current Paseo
  `agentId` and `title`. `AppState.control` stays as a computed view for the
  CLI: the seat named Control, or the only seat.
- Each seat is one `SeatSession`: its live connection (0009), attention,
  open needs, seen state and draft. Device-local state is keyed by the seat's
  fixed id, so a handoff keeps the draft and seen requests. Handoff following
  (0004) is per seat and unchanged.
- The rail shows seats first, then the Inbox, then pinned chats. Each seat is
  Sift's face in its own hue, chosen from the name unless set. The panel
  opens on the first seat when there is one.
- Notifications and bubbles name the seat (`seat:<id>`); the head's pulse is
  any seat's unseen need, and clicking it opens that seat.
- `sift agents list | add | set | remove` manage seats; `sift control …` keeps
  addressing the Control seat.

## Consequences

- Memory grows with seats: one Paseo helper (about 190 MB) per seat.
- A seat's label is the name or Paseo's title; two seats may share a name.
- Removing a seat drops its device-local seen state and draft.
