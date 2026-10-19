# Remote Pi 1.6.1

## What's new

- **The chat stops spending data while it sits idle.** Keeping a conversation
  open could leave a stream running at a steady few hundred KB/s — gigabytes a
  day on mobile data, with nothing being sent or received. The app was asking
  the relay for the same session state again and again; it now asks once and
  goes quiet. Plain text chat is back to a few KB/s.
- **The session list updates without the churn.** Those repeated requests were
  also the reason the phone and the relay kept re-sending presence and room
  snapshots to each other. A subscription is now established once per set of
  paired Pis, and only repeated when that set actually changes.
- **Fixed:** unpairing your last Pi and pairing the same one again could leave
  the session list empty until the app was restarted.

## Assets

- `remote-pi-1.6.1-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
