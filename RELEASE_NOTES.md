# Remote Pi 1.6.7

## What's new

- **Rooms that already ended on a thinking block fix themselves.** The previous
  version stopped new transcripts from ending on a reasoning block, but a room
  that already had one kept it until you switched away and back. Opening such a
  room now re-pulls its history once, which puts every block back above the
  answer it belongs to — no manual room switch, no re-pairing.

## Assets

- `remote-pi-1.6.7-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
