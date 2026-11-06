# 0008 — Every Lark and Paseo message type, faithfully

- Status: accepted
- Date: 2026-11-06
- Supersedes: 0004's rule that only user and assistant text leaves the
  Paseo reader

## Context

0004 kept reasoning and tool output out of Control replies by dropping them
in the reader. That stopped thoughts and command output masquerading as
replies, but it also hid everything else: tool targets, results and failures,
checklists, errors, notifications, plugin entries, and what a pending request
actually asks. On the Lark side, voice, video, stickers, shared chats and
contacts, forwarded bundles and other types became bare labels; replies,
threads, edits and bot senders were lost; a loaded row never picked up an
edit or recall.

The goal is a compact companion that shows every type honestly: a short
summary first, the detail on request, and a plain statement when Sift cannot
show something.

## Decision

Paseo:

- The reader passes every timeline entry with its typed payload, bounded in
  the script (long strings keep their start and end; lists and depth are
  capped). Only `user_message` and `assistant_message` become messages, so
  reply attention (0004) is unchanged.
- Everything between two messages is one collapsed work row: "6 steps ·
  3 commands, 2 edits · 1 failed". It opens to each step (command, file,
  query, URL, sub-agent, plan, message to another agent) and each step opens
  to its bounded output, diff or log. A checklist shows under the row.
  Thoughts are steps, never replies.
- Errors and notifications stay visible as notice rows.
- Pending requests keep their kind (tool, plan, question, mode), title,
  description, target or questions and the choices Paseo offers. They sit at
  the top with the open asks; "Answer in Paseo" opens the session through
  Paseo's own `paseo://h/<server>/agent/<id>` link. Answers stay in Paseo.
- "Earlier activity" lengthens the read tail by 80 entries, up to 400;
  leaving Control or collapsing the panel returns to 80.

Lark:

- Messages keep parent, thread, edited and app-sender metadata. Replies quote
  their loaded parent; edited, recalled and thread messages say so; bots are
  named "Bot" when the chat has no member name for them.
- Voice and video keep duration, cover and file key, and save through the
  resource API. Shared chats open in Sift when known. Contact cards show the
  member name when known. Forwarded bundles load their messages when opened.
  System messages fill in their template.
- Images in posts and cards show under the text. Images open full size, save
  and copy; previews are downsampled once and cached in memory (bounded).
- Each poll re-reads the newest 20 messages of the open chat and replaces
  loaded rows that changed, so edits and recalls appear.
- Three limit states stay distinct:
  - missing grant: Lark refused the resource for this app ("Lark does not
    give this app access…");
  - upstream limit: stickers, which Lark's resource API does not serve;
  - missing renderer: types Sift has no view for (calendar, task, poll,
    location, plugin entries…) show their name and summary with "Open in
    Lark" or the raw bounded content for Paseo.

## Consequences

- A Control read carries more data: about 100 KB for 80 entries on a busy
  session, against about 30 KB before. It still runs once per three polls.
- Paseo artifacts arrive only as live broadcasts, not in the timeline, so a
  per-refresh read cannot see them. They wait for a persistent connection.
- Reactions need `im:message.reactions:read`, which is not in the approved
  scope list; they are not shown.
- Older loaded Lark rows refresh only when the chat is reopened.
- Inline post formatting (bold, italic) is not shown; text, links, mentions,
  code and images are.
- Sending stays text, images and files; nothing new is sent automatically.
