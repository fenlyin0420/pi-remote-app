# Remote Pi 1.6.0

## What's new

- **Much less mobile data.** Two changes, both invisible in use:
  - A chat you already have open is no longer downloaded again every time the
    app reconnects or you re-enter the room. The app now tells the Pi where it
    left off, and only the new part of the conversation travels. On a busy
    session that alone used to be a few megabytes per reconnect.
  - Streaming replies arrive in fewer, larger pieces instead of one network
    frame per token. The text still appears as it is written — it just stops
    paying an envelope per character.
- **Pictures you send stay in the chat.** They used to live inline in the
  message, so a history re-sync — after a restart, a room switch, or a
  compacted session on the Pi — could erase them. The bytes now live in the
  phone's own archive, so the picture survives whatever the Pi forgets. Tap one
  to open it full screen (pinch or double-tap to zoom, drag to pan).
- **A message reads the way you typed it.** The Pi appends notes to your own
  text for the model's benefit ("original 1080x2400, displayed at 900x2000…");
  a re-sync used to surface them as a bubble above the picture. Your text and
  each picture are now separate cards, with nothing extra between them.
- **The agent's todo list sits in the chat.** If the Pi runs the `pi-todo`
  extension, its task list appears as a small pill over the transcript showing
  how many tasks are done (`3/7`). Tap it to read the whole list — what is
  running right now, what is queued, what waits on something else — and tap
  again to put it away. Nothing appears when the agent keeps no list.
- **Ask dialogs take a note.** When the agent asks you questions, there is now
  an optional note at the end of the form for anything that does not fit an
  answer. It can stay empty.
- **Opening a session from a notification lands on that session.** Some
  notifications carried the peer id in a spelling the app did not recognise, so
  tapping one landed nowhere. They resolve now, and the room the notification
  named is the room the chat binds to.

The data savings need the matching Pi plugin release (0.16.0). Until it is
updated, the app behaves exactly as before.

## Assets

- `remote-pi-1.6.0-arm64-signed.apk` — Android arm64
- `SHA256SUMS` — checksums for the assets above
- `latest.json` — auto-update manifest
