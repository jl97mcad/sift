# 0012 — Voice: push-to-talk to a seat, OpenRouter speech both ways

- Status: accepted
- Date: 2026-11-09

## Context

Jon wants to talk to an agent seat and hear it answer, to steer his other
Paseo sessions hands-free. Paseo's own voice mode lags: it waits for a second
of silence, transcribes on the Mac and only speaks through a `speak` tool.

## Decision

- Hold Option-Shift-Space (or tap it to start and again to send, or the mic
  button in a seat's composer) to record. Releasing sends; there is no
  silence detection.
- The recording (16 kHz mono AAC) goes to OpenRouter
  `openai/whisper-large-v3-turbo`. The transcript is sent to the open seat as
  the person, with a one-line preamble asking for short spoken replies.
- Sift follows that seat's new assistant messages and reads them out with
  OpenRouter `fish-audio/drama-3`, finished sentences first while the agent is
  still writing, fetching the next piece while one plays. Markdown, code
  blocks and URLs are not read out. Talking again cuts the voice off. It stops
  following when the turn ends, or after 15 minutes.
- The OpenRouter key lives in `Application Support/Sift/openrouter-key`
  (0600), set with `sift voice key -` from stdin. `sift voice test` proves
  the key and both models with a round trip.
- No local speech model: loading one on Jon's Mac needs his yes each time.

## Consequences

- Audio leaves the Mac for OpenRouter and its providers; text-only use of
  Sift is unchanged.
- Cost: about $0.20 per hour of talking, about $2 per million characters
  spoken.
- The ad-hoc signed app may ask for microphone access again after an install.
