# 0010 — Find new Lark messages from the chat list's activity order

- Status: accepted
- Date: 2026-11-06

## Context

Lark gives a user token no message push (0001), so Sift polls. Every poll,
collapsed or not, read the newest message of every pinned chat, the open
chat and three more chats in rotation: up to fourteen reads every five
seconds, and a chat outside the pins could wait minutes to be noticed.

0001 also meant the chat list to be sorted by activity, but Sift sent
`sort=active_time`, which Lark ignores. Measured on a live account: that
order equals no sort at all and has 101 of 190 chat pairs out of order
against their newest message. `sort_type=ByActiveTimeDesc` has 10 of 190 out
of order, with the newest chat first. A chat list item has no activity field.

## Decision

- List chats with `sort_type=ByActiveTimeDesc`.
- Each poll reads the top 20 chats by activity once. Previews are read only
  for the top two (more activity there keeps the order) and for chats that
  overtook a chat that was above them or entered the list above one. Chats
  that only shift because another left have overtaken nothing.
- A chat that moved is new activity: its newest message counts as unread
  and can raise a bubble even without an earlier preview.
- The open chat is read each poll. While the panel is open, the pins are
  too, since their unread state is on screen. If the list read fails, the
  pins are read instead.

## Consequences

- Collapsed: three reads per poll (one list, two previews) plus movers,
  instead of up to fourteen.
- Back-tested read-only on a live account for seven minutes at ten-second
  reads over the 50 most active chats: 9 of 9 new messages caught, 0 to 20
  seconds after they were sent (Lark reorders the list a little after the
  message); two preview reads per poll.
- A collapsed pinned chat can now take up to about 20 seconds, not five, to
  raise its bubble.
- All chats and the inbox now follow real activity order.
