# 0014 — Voice is one turn at a time

- Status: accepted
- Date: 2026-11-09
- Supersedes: the conversation mode in 0013

## Context

Jon tried conversation mode and prefers to speak, then hear the reply. He
also found three stacked status lines (the agent's activity, a red banner
for a voice note, and the voice line) cluttered.

## Decision

- No conversation mode: no double-tap, no listening on its own. The mic
  button and Option-Shift-Space talk, send, or cut the voice off; holding the
  key is push-to-talk.
- While voice is busy for a seat, or has a short note, it takes over that
  seat's one live-state line: level bars while you or the agent talk, the
  agent's own activity while it works, a pause button while it speaks. Voice
  notes ("Microphone allowed", "Didn't catch anything") show there for five
  seconds, never in the red error bar.
- The silence filter, pause and the head's glow from 0013 stay.
