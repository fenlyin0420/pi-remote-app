# Remote Pi 1.6.2

## What's new

- **The model on screen now says who serves it.** The Pi reports the model's
  name and nothing else, so a row that read `Claude Opus 4.7` now reads
  `Claude Opus 4.7 · anthropic` — on the Home list, in the chat's top bar, in
  the session info and in the quick actions sheet. The provider comes from the
  model catalogue the app already downloads and is remembered for offline use;
  while it is still unknown, the name is shown on its own.
- **The agent's todo list moved out of the way.** The pill now sits in the
  transcript's top-right corner and unfolds downward, so an open list covers
  scrollback instead of the message being read. The chevron follows the
  direction the card moves.

Updating from 1.6.0, this release also carries 1.6.1's fix for a chat that kept
draining mobile data while it sat idle.

## Assets

- `remote-pi-1.6.2-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
