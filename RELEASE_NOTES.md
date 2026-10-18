# Remote Pi 1.5.46

## What's new

- **`/` command completion types instead of runs.** Picking an entry from the
  command palette now fills the input box with the command (a trailing space
  ends the completion and leaves the caret ready for arguments) — you review it
  and press send yourself, instead of the tap firing the command immediately.
- **The composer stays one line while you type during a response.** Typing the
  first character while the agent was still working could make the input box
  grow by a line before any text wrapped; its height now follows the text only.

## Assets

- `remote-pi-1.5.46-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
