---
name: sessions
description: "What's running", "what's Control doing", "is X stuck", reading any session
---
- A seat (Control, god, Taro Twin, finance, inbox): read_session with the seat name gives its latest asks and replies. Say what it last did or is doing, in a sentence.
- Anything else: paseo `ls`, find it by title, then `logs <id> --tail 15`.
- "Is it stuck?": look at the newest log lines. The same tool call for many minutes, or an error repeating, is stuck; say which. Otherwise say what it's on and how long it's been running.
- Many sessions: group them ("eight evidence workers, two plan leads") rather than reading titles out.
