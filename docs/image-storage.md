# Images in the transcript — where the bytes live, and how they get back on screen

Maintainer note. Two different kinds of picture reach the chat, and they are
stored differently on purpose:

|Aspect|**User's pictures**|**Files the Pi sends**|
|---|---|---|
|Direction|phone → Pi|Pi → phone (`send_to_phone`, a tool result)|
|Bytes on the Pi|base64 `image` block inside the room's session file|a real file on the Pi's disk (path in the row)|
|Bytes on the phone|`sent_images/<content hash>.bin`|`attachments/<id>.bin`, only once fetched|
|Re-fetchable from the Pi?|**no** — the Pi's copy is the Pi's session file, which can be compacted or cleaned|**yes** — `file_get` on the path in the row|
|Row stores|`blob` + mime + pixel size|name, path, mime, size, `blobName`|

The asymmetry is the whole design: an attachment can always be asked for
again, so its cache may be small and disposable. A picture the user *sent*
cannot be asked for again, so its bytes are taken out of the message row and
archived on the phone where a history re-sync cannot reach them.

## Where each byte lives

```text
<app data dir>/
  msgs_<epk>__<roomId>.hive     rows: text, images[{blob,mime,w,h}], files, attachments
  sent_images/img_<sha256>.bin  the phone's archive of pictures the user SENT
  attachments/att_<id>.bin      cache of files the Pi sent (fetch-on-demand)
```

On the Pi's side of the connection:

```text
<pi session>.jsonl              user message content blocks, images inline (base64)
<pi cwd>/<file the agent made>   the file behind a send_to_phone card
```

## A. A picture the user sends

**Write path** (`AttachmentViewModel` → `ChatViewModel` → `SyncService`)

1. Picker → compressor: JPEG, longest side ≤ 1568 px, q80, hard ceiling 1500 KB
   (a few extra passes at −15 quality and ×0.85 dimensions if it overshoots).
   No original ever leaves the phone.
2. `takeForSend()` hands the tray over as `MessageImage{data: base64, mime}`.
3. `SyncService.sendMessage` writes the optimistic row through `_upsert`, which
   calls `_archiveImages`: `base64Decode` → `SentImageStore.put` (name =
   `img_<sha256>.bin`; skipped when that blob already exists) → the row keeps
   `{blob, mime, w, h}` and **no bytes**. `w`/`h` come from `probeImageSize`, so
   layout never has to wait for a decode.
4. The wire frame is unchanged and still inline base64 (`UserMessage.images`):
   the Pi injects it as an `image` content block, and pi persists it in the
   room's session file.
5. The Pi echoes `user_input`; the echo dedupes by message id onto the same row
   and only flips `pending:false`. The Pi's **history replay**, by contrast,
   renumbers rows to `sync_<ts>` and carries the bytes again — `_applyHistory`
   archives them (idempotent: same bytes, same blob, no write) and, when the
   replay arrives *without* them, restores the row's references instead:

   > keep the old row's pictures when the new row sits at the same position, has
   > the same id and the same text, and comes back byte-less.

   A delta (incremental `session_history`) replaces the rows this device wrote
   from live frames, and those carry the archive references under the app's own
   id. The replayed row's id differs (`sync_<ts>`), so the two are paired by
   message text — in transcript order, one slot per message, and only when both
   sides hold the same number of messages with that text. A reply that brings a
   different count cannot say which one carries the picture, and a picture on the
   wrong bubble is worse than no picture at all.

   That is what keeps a picture on screen after the Pi cleaned up its session
   file, or after the payload fell out of the replay's byte budget.

   A reply only replaces the live rows it brings back. Anything it cannot
   account for — written a moment before it was asked for, or never persisted on
   the Pi's side — stays on screen to be picked up by the next reply, at the end
   of the loaded window rather than at its own timestamp.

A write that fails (no space) leaves the bytes inline in the row: a picture that
cannot be cached is still worth showing.

**Read path** (`ChatViewModel` → `UserBubble` → `ImageBubble`)

1. `SessionReadRepository.watchMessages` reads rows from Hive (incremental, per
   box event) and projects them to `UserMsg` — no bytes are touched here.
2. `MessageList` passes the archive reader down (`loadSentImageBytes:
   vm.sentImageBytes`); `UserBubble` gives it to each `ImageBubble`.
3. `ImageBubble._read()`:
   - row has inline `data` (a row written before the archive existed) →
     base64 in memory, header probed on the spot;
   - row has `blob` → the box is sized from the recorded `w`/`h` **before**
     anything is read, then the bytes come from `SentImageStore.get`;
   - the bytes are memoised process-wide (`_PayloadCache`, 32 MB, LRU) keyed by
     the blob name, so scrolling back past a picture neither re-reads the disk
     nor re-decodes the bitmap (`Image.memory`'s cache keys on byte-list
     identity).
4. `ImageFrame(keepRatio: true)` reserves the box: the picture is scaled down to
   fit 300 × 220 pt at its **own ratio** — a square stays square, a phone
   screenshot stays a tall strip, nothing is cropped. The bitmap is decoded at
   the painted width (`cacheWidth = box width × dpr`).
5. Tap → `ImagePreview` (black page, `ZoomableImage`: pinch, double-tap 2.5×,
   max 6×). The preview gets the bytes the bubble already has — no re-read.
6. A row whose blob is gone (pruned, or from an install that predates the
   archive) draws the broken-image glyph instead of an empty bubble.

The row's pictures are also what `UserBubble` uses to lay out a multi-picture
message: one `ImageBubble` per image, stacked in send order, each with its own
ratio.

## B. An image (or file) the Pi sends

**Write path** (`send_to_phone`, or a tool whose result carries an image)

1. The Pi writes the file, then sends an `attachment` entry — metadata in a
   history replay, a `file_offer` frame live. The row it becomes carries name,
   path, mime, size, note, `resized`/`original_size`, no bytes.
2. If the offer carried `data`, `_writeAttachment` decodes it and
   `AttachmentStore.put(id, bytes)` writes `attachments/att_<id>.bin`
   (temp-file + rename, so a crash cannot leave a half-written blob); the row
   keeps `blobName`.
2b. A file too big or too binary for one envelope arrives as `file_send_start`
   → `file_send_chunk` ×N → `file_send_end` instead. The row is created on the
   start frame (metadata only, so the transfer is visible where it will live),
   the chunks append to `attachments/.incoming/<id>.part` under
   `IncomingFiles`, and only a matching size + sha256 renames that part into
   the row's `blobName`. Progress lives in memory (`SyncService.fileReceiveOf`)
   and is never written to the row; an interrupted transfer leaves the card
   with no bytes, which is the same "tap to load" state a history replay has.
3. A card rebuilt from history arrives as metadata only — `_applyHistory`
   carries the old row's `blobName` over, so a room full of already-seen
   screenshots does not turn back into "tap to load" on every re-sync.

**Read path** (`AttachmentCard` / `AttachmentViewer`)

1. `loadBytes(blobName)` → `AttachmentStore.get` → the inline thumbnail
   (`ImageSizeCache` remembers the header per blob, 220 pt cap, `BoxFit.cover`
   because this card spans the row like any other card).
2. No local bytes → "tap to load from the Pi": `requestAttachment` sends
   `file_get` for the row's path; the Pi answers with a `file_offer` for the
   same card id and the bytes flow back through the normal writer path.
3. Tap the image → `AttachmentViewer`: full screen, zoom, and "save to phone"
   (`MediaSaver` → gallery for images, Downloads otherwise).
4. Text files render a capped monospace preview instead, and "show all" opens
   the same viewer. A blob over 4 MiB is never read into memory just to draw a
   card: it shows its metadata and saves through the platform channel, which
   copies from the file path.

## What survives what

|Event|User's pictures|Pi's files|
|---|---|---|
|Pi's session file cleaned / compacted (replay loses the bytes)|**kept** — the row keeps its archive references (restore rule A.5)|kept while the phone's copy exists; otherwise "tap to load" fails if the Pi's file is gone too|
|`session_history` replay carries the bytes again|archived again → same blob, no write, no growth|unchanged|
|Reconnect / re-sync / app restart|kept|kept (`blobName` is carried across replays)|
|Replay window truncated (the Pi's byte budget drops the oldest events)|the **row** goes, so the picture leaves the transcript; its bytes stay orphaned on disk|same|
|`session_new` / session picker switch|the room's rows are cleared, so the pictures leave the transcript|same|
|`sent_images/` past its cap (256 MB, oldest first)|the oldest pictures drop out of history|n/a|
|`attachments/` past its cap (64 MB, oldest first)|n/a|thumbnails drop out; the Pi can send them again|
|App data cleared|gone (the Pi's session file is the only copy left)|gone (the Pi's files are the only copy left)|

## Why the archive exists at all

`session_history` is applied as a **wholesale substitute** for the room's rows,
not as a merge. An incremental reply (`mode: "delta"`) adds the events that came
after the cursor this device sent, and replaces only the live-written rows it
brings back — a row it cannot account for stays on screen and waits for the
reply that owns it, because dropping it would lose it for good (that reply's own
cursor is already past it). Before the
archive, a user picture lived only inside its row, so
any replay that dropped the payload — a cleaned session file, or the replay's
3 MB budget trimming the oldest events — wrote over the phone's copy and the
picture vanished from the transcript. Keeping the bytes in a separate,
content-addressed store makes the row the only thing a replay can touch.

## File map

|Path|Role|
|---|---|
|`lib/data/local/sent_image_store.dart`|The archive: content-addressed put/get, 256 MB cap|
|`lib/data/attachments/attachment_store.dart`|Same file mechanics for Pi-sent files (64 MB cap) + text preview/decode|
|`lib/data/local/records/message_record.dart`|Row JSON: `images: [{blob, data?, mime, w, h}]`, `attachment: {…, blob}`|
|`lib/data/sync/sync_service.dart`|Single writer: `_archiveImages`, `_upsert`, `_applyHistory` (restore rule), `_writeAttachment`, `sentImageBytes`, `attachmentBytes`|
|`lib/domain/session_state.dart`|`MessageImage` (inline **or** archived), `MessageFile`, `AttachmentMsg`|
|`lib/domain/value_objects/image_size.dart`|`probeImageSize` — PNG, GIF, WebP, BMP, JPEG headers|
|`lib/data/images/image_picker_service.dart`|Pick + compress before anything leaves the phone|
|`lib/ui/chat/widgets/image_bubble.dart`|A sent picture: archive read, reserved box, tap to preview|
|`lib/ui/chat/widgets/image_frame.dart`|The reserved box (`keepRatio` for the user's pictures)|
|`lib/ui/chat/widgets/image_preview.dart`|Full-screen look at a sent picture|
|`lib/ui/chat/widgets/zoomable_image.dart`|Pinch + eased double-tap zoom, shared by both viewers|
|`lib/ui/chat/widgets/attachment_card.dart`|A Pi-sent file in the transcript|
|`lib/ui/chat/widgets/attachment_viewer.dart`|Full-screen look at a Pi-sent file|
