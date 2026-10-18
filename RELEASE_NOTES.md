# Remote Pi 1.5.47

## What's new

- **Pictures you send stay in the chat.** They used to live inline in the
  message, so a history re-sync — after a restart, a room switch, or a
  compacted session on the Pi — could erase them. The bytes now live in the
  phone's own archive, so the picture survives whatever the Pi forgets. Tap one
  to open it full screen (pinch or double-tap to zoom, drag to pan).
- **The agent's todo list sits in the chat.** If the Pi runs the `pi-todo`
  extension, its task list appears as a small pill over the transcript showing
  how many tasks are done (`3/7`). Tap it to read the whole list — what is
  running right now, what is queued, what waits on something else — and tap
  again to put it away. Nothing appears when the agent keeps no list.
- **Ask dialogs take a note.** When the agent asks you questions, there is now
  an optional note at the end of the form for anything that does not fit an
  answer. It can stay empty.
- **Opening a session from a notification now lands on that session.** Some
  notifications carried the peer id in a spelling the app did not recognise, so
  tapping one landed nowhere. They resolve now, and the room the notification
  named is the room the chat binds to.

## Assets

- `remote-pi-1.5.47-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
