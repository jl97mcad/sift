# 0003 — Quiet Control attention

- Status: accepted
- Date: 2026-11-05

## Context

Sift stays at the screen edge. The owner wants new replies to be subtle, with a pulse
when Control needs him and readable messages when he opens it.

## Decision

Use a small dot for replies and a gentle ring pulse for an agent waiting for
input. Reduce Motion keeps the ring steady. Clicking the head opens Control
when it has unread attention. No automatic opening. macOS banners are opt-in;
sound defaults off. Suppress notifications while the expanded panel has focus.

Use the existing Paseo inspect status and transcript, with a content fingerprint
rather than shifting log indices. Poll Control independently of Lark sign-in.
Keep preferences, delivery deduplication and the pending cue in device-local
UserDefaults; the shared state JSON and CLI contracts stay unchanged.

Render reply structure and inline Markdown without distilling or deleting facts.
Keep long replies expandable. No local model is loaded or downloaded: inference
is a separate product decision and needs the owner's explicit approval on that Mac.

## Consequences

The edge head remains useful without notification permission. System-level
Focus/alert preferences still decide whether an optional banner appears.
Transcript rendering remains bounded by Paseo's existing log truncation.
