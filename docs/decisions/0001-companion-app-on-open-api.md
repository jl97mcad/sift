# 0001 — Companion app on the Lark Open API

- Status: accepted
- Date: 2026-11-05

## Context

MINI, the app this copies, pairs with WhatsApp as a linked device: it speaks
WhatsApp's multi-device protocol and runs as a second client. Lark has no
comparable pairing protocol. Its desktop app keeps messages in an encrypted
local store (`~/Library/Application Support/LarkInternational/.../messages.db`
starts with non-SQLite bytes), so reading the client's cache would need a
reverse-engineered key and would break on every update.

## Decision

Build a standalone macOS app that talks to Lark's public Open API with a user
access token from a self-built app:

- `GET /open-apis/im/v1/chats?types=p2p,group&sort=active_time` for the chat
  list, including direct messages.
- `GET /open-apis/im/v1/messages` for history.
- `POST /open-apis/im/v1/messages` with `im/v1/images` / `im/v1/files` for
  sending as the user.

No local database access, no UI automation, no injection into the Lark client.

## Consequences

- Works with documented, supported endpoints and survives Lark updates.
- Needs a Lark app registration and admin-approved user scopes per person.
- No push for personal messages: the app polls. Reads lag by the poll interval.
- No unread counts from the API: unread is derived from the newest message id
  the panel has seen.
- Chat ordering comes from the API's `active_time` sort; local reordering is
  limited to the pinned grid.
