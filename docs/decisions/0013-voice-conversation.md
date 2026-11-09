# 0013 — Voice conversation, pause and a visible voice

- Status: accepted
- Date: 2026-11-09
- Supersedes: the "no silence detection" and "talking again cuts the voice off"
  parts of 0012

## Context

Jon used voice mode and wanted a hands-free back-and-forth, a way to pause
the reply, and to see that Sift is listening. One near-silent recording was
also sent and transcribed as filler.

## Decision

- **Conversation:** double-tap Option-Shift-Space or tap the mic button. Sift
  listens, sends once you have been quiet for 1.2 seconds after speaking,
  reads the reply and listens again. It ends after 30 seconds with nothing
  said, on a double-tap, the End button, an error, or 15 minutes waiting on a
  reply, or after a 30-second turn that never went quiet (a loud room), which
  is dropped rather than sent. It does not listen while it speaks (no echo cancellation); a tap cuts
  in instead.
- Push-to-talk stays as in 0012: hold, or tap and tap again more than
  0.35 seconds later. Two taps within 0.35 seconds start a conversation.
- After the first microphone prompt, Sift never opens the microphone on its
  own: press again.
- **Pause:** pause and resume the reply, or stop it, from the status line.
- **Silence:** a recording whose loudest moment stays below -35 dBFS is not
  sent, and Whisper's usual inventions for silence ("you", "thank you") are
  dropped. Thresholds are fixed constants in `VoiceMode`.
- **Visible:** while voice is on, the head has a glow that swells with your
  voice (green) or the agent's (white), orange when paused. Above the
  composer, a line shows level bars and what is happening.

## Consequences

- A loud room can hold a turn open; a very quiet voice can be dropped. Tune
  the constants, or add echo cancellation later.
- The meter runs at 20 updates a second only while voice is on.
