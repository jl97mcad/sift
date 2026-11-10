---
name: paseo
description: Using the Paseo CLI: find sessions, see what one is doing, message it, permissions, schedules
---
The paseo tool runs one Paseo CLI command. Pick the host: the main daemon by default; the laptop only for things on the laptop.

Finding a session
- `ls` lists live sessions with id, title, status and age. Pick by title or plan number. Use the short id (first 8 characters) from that list in later commands. Never make up an id.
- `ls --label seat=control` finds a seat; `ls --label role=lead` lists plan leads.

What a session is doing
- `logs <id> --tail 15`: its latest steps and replies, newest last. Say in one sentence what it's on now; mention a tool it's stuck on only if it's been on it a long time.
- `inspect <id>`: model, status, labels, when it last did something.

Messaging a session
- `send <id> "message"`: only when the person asked to tell that session something. Put their words in the message, starting "From <person>, by voice:". It returns at once; read its answer later with logs, or tell them you'll check back.
- For Control, the god session, a plan lead, OpenClaw or Taro Twin, prefer delegate: it follows the work and speaks the result.

Actions that need a yes first
- `stop <id>` interrupts one session. `permit ls` shows waiting permission requests; `permit allow <agent> <request>` or `permit deny ...` answers one. `schedule pause|resume|run-once <id>`.
- Say exactly what you'll do in one sentence ("Stop the JON-4122 lead?"), wait for a clear yes, then call with confirmed true. A "yeah" to something else isn't a yes.

Never
- Create, delete, archive, restart or reconfigure sessions by voice: the tool refuses. Hand those to Control.
