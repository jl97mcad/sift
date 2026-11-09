# 0015 — Voice front door: a fast talker in front, the worker session behind

- Status: accepted
- Date: 2026-11-09
- Supersedes: the phone web app's one-turn flow (voice-web, PRs 13 to 16). Leaves the Mac
  app's one-turn voice (0014) as it is.

## Context

Jon wants voice on his phone to feel like talking to someone: quick replies, follow-ups
without pressing again, interrupting, and being kept posted while long work runs. He wants
it to be the front door to all his work, generic enough for Will to run on his own tailnet.
Every turn going through the Opus worker session took 5 to 60 seconds.

## Decision

- A fast front model, `anthropic/claude-haiku-5.5` through OpenRouter, holds the
  conversation. It starts answering in about 0.7 seconds; Gemini Flash took about 2.
- The front model has two tools:
  - `delegate`: hands a task to the worker session (Paseo label `seat=<worker>`) in the
    background.
  - `job_status`: reports what the worker is doing.
- The worker takes one task at a time.
- Background work shows as cards. When a task finishes, the front model says the result
  in one or two sentences. A step that runs over 90 seconds gets one spoken heads-up.
- The phone keeps the microphone open for the conversation:
  - It sends after 0.8 seconds of quiet.
  - Talking over it (above a higher loudness bar, with echo cancellation on) interrupts.
  - 45 seconds of silence pauses the conversation.
  - A tap stops it.
- Everything person-specific is in `voice-web/config.json`: names, timezone, about, the
  worker's seat label and the front model. `config.example.json` is the template. Nothing
  about Jon is in the code.

## Consequences

- The front model costs a few cents a day. Speech costs as before.
- Thresholds are fixed constants in the page. A loud room or speaker echo may need tuning.
- The conversation history lives in server memory and is lost on restart.
