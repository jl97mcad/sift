# 0021 — Talking straight to the chief of staff by voice

- Status: accepted
- Date: 2026-11-11

## Context

Jon's chief of staff is a Paseo session (the god session) that decides for him in most areas. By
voice he could only reach it through `delegate`, so Sift rephrased his words as a task, and every
message went through the front model.

## Decision

Off unless `chief.worker` names a configured worker, so other installs are unchanged.

- `set_mode` (sift | chief) switches a call into chief-of-staff mode. On entering, Sift says one fixed
  line and sends the page and board a `{type: "mode", mode, label}` server message. The page shows
  the label in its status chip and dock hint.
- In chief mode the model never runs. A gate between the user aggregator and the LLM takes each of
  the person's turns before inference (typed text too). Exit phrases ("back to Sift", "that's all for
  the chief", "exit chief mode") and scrap phrases ("scrap that", "cancel that", "don't send that")
  are matched locally with forgiving regexes in `pipecat/chief.py`. A command said in the same breath
  as a message ("Cancel the offsite. Scrap that.") counts too. Anything else is queued as the
  person's words. Text that speech recognition invents from noise (other scripts, "Thank you.") is
  dropped.
- Grace window: queued words wait about 4 s after the person's turn ends. Consecutive utterances
  join one message. A receipt with the first few words is spoken at the start ("Sending: '...'").
  Recognition and turn-taking run seconds behind the audio, so a small RMS detector before speech
  recognition holds the window while there's speech that no finished turn has caught up with yet
  (at most 12 s). This lets a late "scrap that" still count. A scrapped message is never sent.
- After the window, server.mjs sends the message as one user message, exactly
  `<person>, by voice (Sift Voice, verbatim transcript; may contain mishearings): <words>`. It uses
  the Paseo client's `run` with `activeTurnBehavior: "steer"` (the CLI's default for agents), so a
  running turn is never interrupted. It follows the timeline like `delegate` does, with a job card
  "your chief of staff". Each message's reply runs to the next chief message.
- The reply is summarised by the cheap model with no tools into one or two sentences and spoken as
  "Your chief of staff says: ..." in a quiet moment. The full text goes on the card and into the
  call's context. Other job news waits until the person is back with Sift.
- `note_to_chief` sends one message from normal mode ("tell my chief of staff ..."), with the same
  window and receipt. Its words must all be in what was heard (the `answer_ask` check), or it's
  refused and the model asks again.
- The call's memory note marks messages "To chief of staff".
- `chief.dryRun` or `SIFT_CHIEF_DRY_RUN=1` logs the exact message instead of sending it. Only in a dry
  run, `POST /bot/chief/fake-reply {text}` on the 127.0.0.1 side port injects a made-up reply through
  the real reply path.

## Consequences

- A relayed message carries only the person's words. The prompt and skill say Sift never presents
  it, or the chief's reply, as approval of money, outside sends, access, signatures or production
  writes beyond those words.
- The first real message on Jon's install is his own: every test ran in dry-run.
- The reply path against a live session (a steered message in the timeline) has only been tested
  with the fake reply.
