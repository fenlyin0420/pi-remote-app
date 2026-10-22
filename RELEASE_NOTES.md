# Remote Pi 1.8.0

## What's new

- **Tool cards show whether the call writes.** Every tool row now carries a bar
  on its left edge when the call changes something on the Pi — files, git or
  package state, or other persistent state — so a transcript reads at a glance:
  what only looked, and what changed. The bar takes the card's own left padding,
  so nothing moves when it appears.
- **Verdicts arrive whenever they are ready.** Known tools and clear shell
  commands are decided on the Pi as the call starts; the hard cases (`bash` with
  a heredoc, a script, an unknown command) are decided by a small classifier and
  can land after the result. Both orders mark the same card.
- **Markers survive a re-sync.** The verdict is stored with the row and replayed
  with the session history, so reopening a room, reconnecting, or restarting the
  Pi's daemon keeps every marker. Read-only calls store nothing.

Requires the matching `pi-remote` plugin on the Pi (`0.17.0` or newer). Older
plugins send no verdicts, and the cards render exactly as before.

## Assets

- `remote-pi-1.8.0-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
