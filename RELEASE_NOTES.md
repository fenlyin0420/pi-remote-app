# Remote Pi 1.6.4

## What's new

- **The chat no longer shows the same thing twice.** Reconnecting, or coming back
  to a room you already had open, could print a message, a reasoning block or a
  screenshot a second time — one tool card holding the same picture twice, the
  same sentence twice in a row. A re-sync now brings in only what arrived since
  the last one and stands in for the rows it repeats instead of stacking new
  copies next to the ones already on screen.
- **Nothing you sent while a sync was in flight can disappear.** If the phone was
  re-syncing at that moment, the reply could not include what was sent after it
  was asked for; the bubble stays on screen and is picked up by the next sync.
  That includes a picture you had just sent, which used to be able to vanish
  along with its message.

## Assets

- `remote-pi-1.6.4-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
