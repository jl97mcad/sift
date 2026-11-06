# 0006 — Seen needs go quiet

- Status: accepted
- Date: 2026-11-05
- Supersedes: 0005's steady ring for seen open asks

## Context

0005 kept a steady ring on the edge head and the Control rail item while any
seen ask stayed open. Asks can stay open for hours, so on the installed app the
ring became a permanent grey outline that crowded the running-work dot.

## Decision

Only unseen needs show a ring, and that ring pulses (steady under Reduce
Motion). Seeing them in the focused Control view clears the cue, as reading
clears a reply dot. Open asks stay listed at the top of Control until they are
answered or withdrawn. A new ask or permission request pulses again.

## Consequences

The edge stays quiet between new needs. Open asks are found in Control, on the
board and in their existing notifications, not on the head.
