# 0009 — One live Paseo connection per seat

- Status: accepted
- Date: 2026-11-06
- Supersedes: 0004's "one short script per refresh" for the app (the CLI
  keeps one-shot reads)

## Context

The app started a Paseo Helper process for every Control read, every third
poll (15 s), collapsed or not. Each start loads Node and the CLI modules,
runs for one to two seconds at high CPU and exits. The installed Paseo
client (app 0.14 against a 0.15 daemon, protocol 1) offers timeline
subscriptions: subscribed, it pushed every change of a running Control
session (39 events in 45 s during one turn). Reconnects do not replay missed
history, so a client has to reconcile on its own.

## Decision

- The reader script gains a watch mode. The app keeps one helper per seat,
  connected for as long as the seat is set. It subscribes to the seat's
  timeline and, on any event, refetches the bounded tail with the same
  snapshot the one-shot read uses. A refetch is the reconcile: a missed,
  replayed or out-of-order event, a new epoch or a reconnect needs no
  sequence bookkeeping.
- Requests and turn boundaries (permission requested or resolved, attention,
  turn started, finished, failed or cancelled) are sent at once. Other
  changes are sent at most every 3 s while Control is open and every 15 s
  otherwise. A snapshot every 30 s covers open asks (they have no events)
  and anything missed. A snapshot equal to the last one is not sent.
- The app talks to the helper over stdin: `refresh`, `gap <s>`,
  `tail <n>`. It runs in its own process group; stopping the seat ends the
  group, and the helper exits when its stdin closes, so it cannot outlive
  Sift.
- Three failed snapshots in a row or a disposed connection end the helper.
  Sift restarts it after 5 s, doubling to at most a minute, and polls with
  the one-shot read meanwhile.

## Consequences

- No process starts per refresh. One resident helper uses about 190 MB of
  memory and close to no CPU between events.
- Paseo artifacts are broadcast without a session id, so Sift cannot tell
  which session produced one; they stay unshown.
- The watch still depends on the Paseo app's internal client modules, like
  0004. If they change, the helper fails, Sift falls back to polling and
  shows the read error.
