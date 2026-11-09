# 0017 — The voice front door runs on the VPS and reaches every daemon

- Status: accepted
- Date: 2026-11-09

## Context

Jon wants his phone to reach the voice assistant from anywhere, with one server, and to be
able to ask OpenClaw, Control, the god session, sessions on jon-control and sessions on his
MacBook. The Mac is often off.

## Decision

- The server runs on the VPS under systemd. `tailscale serve` (not Funnel) puts it on the
  tailnet over HTTPS. The Mac copy stops.
- A worker's `url` is any address the Paseo CLI takes: `host:port`, `tcp://`, `ws://` or a
  `relay://` pairing address. The MacBook is reached through Paseo's end-to-end encrypted
  relay, so its sessions work wherever the laptop is, while it's on.
- A worker can be a command instead of a Paseo session. The prompt goes in a file and the
  output is the reply. OpenClaw runs as `openclaw agent --json`, without `--deliver`, so it
  only replies to the caller and nothing is sent to any chat.
- The speech key comes from `OPENROUTER_API_KEY` or a file named by `OPENROUTER_KEY_FILE`.
  The relay address and key stay in 0600 files on the VPS, never in the repo.
