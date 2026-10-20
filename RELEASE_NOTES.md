# Remote Pi 1.6.5

## What's new

- **A long room opens without the history twitching first.** Opening a room with
  a lot of history used to rebuild the whole transcript once per row that came
  back — the list jumped and re-settled for seconds before it held still. A
  history that arrives in one reply now lands on screen as one update.
- **Leaving a room mid-sync no longer costs you the whole history again.** If you
  stepped out while a room was still catching up, the phone forgot how far it had
  got and pulled the entire room down again the next time — megabytes for a long
  one. That progress is now kept, so the next visit only brings what is new.

## Assets

- `remote-pi-1.6.5-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
