# 0018 — Voice calls run on Pipecat; the Node server keeps the page and the tools

- Status: accepted
- Date: 2026-11-10

## Context

The home-made turn-taking (record, upload, transcribe, answer) lagged and cut Jon off. A Pipecat
trial on the VPS (10 Nov) gave a median 2.1 s from end of speech to first audio, clean barge-in in
about 10 ms, and about a third of one CPU core per call. Jon wants that engine behind the Sift page
at the same tailnet address, able to use the Paseo CLI, and guided by written skills. Audio only.

## Decision

- The page at the same address opens one audio-only WebRTC call to `voice-web/pipecat/bot.py`.
  `server.mjs` proxies `/api/offer` to the bot, so the page keeps one origin. The tailnet carries
  the media directly; there's no media server, no STUN or TURN, and no video.
- Pipecat does the turn-taking: Silero VAD with Smart Turn v3, Qwen3 ASR, DeepSeek Flash with
  reasoning off, and Fish Drama 3, all through the existing OpenRouter key.
- `server.mjs` stays the one owner of the prompt, the tools and the background jobs. The bot reads
  its setup and calls each tool on a side port (`BOT_PORT`, 127.0.0.1 only and never served on the
  tailnet). Job news goes to the bot's event feed and is spoken inside the open call in a quiet
  moment. With no call open, it falls back to clips on the page.
- The `paseo` tool runs the Paseo CLI without a shell, on hosts named in `config.paseo.hosts`.
  Reads run freely: `ls`, `inspect`, `logs`, `status`, `wait`, and the schedule, permit,
  terminal and provider lists. `send` always uses `--no-wait`. Stop, permit allow or deny, and
  schedule pause, resume or run-once each need `confirmed: true` after the person's yes.
  Everything else is refused, including create, delete, archive, restart and edits.
- Skills are short how-tos in `voice-web/skills/*.md`, with a name and description in their
  front matter. The prompt lists them, and the `skill` tool loads one on demand.
- The bot runs as `sift-voice-pipecat.service`. Its Python packages are pinned in
  `pipecat/requirements.txt` and installed in `/opt/sift-voice/pipecat-venv`.

## Consequences

- Each open call holds about 260 MB and a third of a core on the VPS; an idle call hangs up after
  5 minutes of silence.
- The old `/api/turn` and `/api/text` routes remain in the server but the page no longer uses them.

## Running one for someone else (10 Nov)

Everything person-specific is in `config.json`:
- `title`: the page heading and home-screen name. It defaults to `assistant`, then "Voice".
- `assistant`: the name the assistant uses for itself; it may be empty.
- `hearing`: a line about names that speech recognition mishears, such as their plan prefix.
- `workers`: each worker is found by `seat` label or by `title`, a regex on the session title.
- `paseo.hosts`, `needs.command` and `sources`.
- `timezone`: if it isn't set, the phone's timezone is used.

Run both services as that person's user, with their own OpenRouter key file and their own tailnet.
