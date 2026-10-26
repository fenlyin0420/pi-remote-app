# Remote Pi 1.9.0

## What's new

- **Any file, not only pictures and small text.** The agent's `send_to_phone`
  tool now delivers whatever it has on disk — a PDF, an archive, a video, a
  200 MB export — by streaming it in chunks instead of refusing anything that
  does not fit one frame. Images still arrive instantly and inline; everything
  else gets a card with a progress bar while it streams, and can be saved to the
  phone once it lands.
- **Nothing half-written is ever shown.** The phone verifies the whole-file
  checksum the Pi declares before the bytes become the card's content, so an
  interrupted transfer leaves the familiar "tap to load" instead of a broken
  file. Transfers are point-to-point and restart from the beginning if the link
  drops.
- **A file that is not text reads as a file.** A PDF or an archive now gets a
  card that says it is on the phone and offers saving, instead of a text preview
  full of raw PDF source. Large files are never read into memory just to draw
  the card.

Requires the matching `pi-remote` plugin on the Pi (`0.18.0` or newer) for
streamed files. Older plugins keep working for images and small text files.

## Assets

- `remote-pi-1.9.0-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
