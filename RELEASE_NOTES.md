# Remote Pi 1.9.1

## What's new

- **Opening a long room no longer freezes.** The history is read off the phone
  in slices instead of one blocking pass, so the chat now shows a spinner the
  moment you enter and fills in as the transcript is decoded. Previously the
  page sat on "Nothing here" and then jumped to a full screen of messages, with
  the UI stalled for that whole window.
- **The model and thinking level no longer snap back.** Re-opening a room, or
  reconnecting, used to replay yesterday's model over the one you had just
  picked. A room's current model and thinking level now come from the Pi's own
  snapshot of the session, and a replay never overrides a newer choice.
- **A model switch that fails says so at once.** The Pi's error frame now
  resolves the pending request immediately, instead of leaving the picker
  waiting out a 15-second timeout with no explanation.

## Assets

- `remote-pi-1.9.1-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
