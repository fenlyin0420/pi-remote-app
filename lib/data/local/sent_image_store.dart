import 'dart:typed_data';

import 'package:app/data/attachments/attachment_store.dart';
import 'package:crypto/crypto.dart';

/// The phone's own archive of the pictures the user SENT.
///
/// A sent picture used to live in exactly two places: the Pi's session file
/// (base64 inside the user message's content) and this app's local room cache
/// (base64 inside the row). The second is not an archive — `session_history` is
/// applied as a WHOLESALE substitute for the room, so whatever the Pi no longer
/// replays (a cleaned or compacted session file, or the payload falling out of
/// the replay's byte budget) is written straight over the phone's copy, and the
/// picture disappears from the transcript.
///
/// This store takes the bytes out of the row: the row keeps [MessageImage.blob]
/// (a content hash) plus the pixel size, and the bytes live here. A replay can
/// then rewrite, truncate or drop a row without touching the picture on this
/// disk.
///
/// Content addressed on purpose: the same picture sent twice, or replayed by
/// every re-sync, is ONE file. The dir sits next to the Hive boxes and is shared
/// by all rooms — the phone's copy of a picture has nothing to do with which
/// chat asked for it.
class SentImageStore {
  /// Subdirectory of the app's data dir holding the blobs.
  static const String dirName = 'sent_images';

  /// Soft cap for the whole archive. Deliberately far above the attachment
  /// cache's: an attachment can always be fetched from the Pi again, a sent
  /// picture cannot — that is the whole point of this store. Past the cap the
  /// oldest blobs go first, because the Pi's own copy is the only other one and
  /// it may be exactly what was cleaned.
  static const int defaultMaxBytes = 256 * 1024 * 1024;

  /// The file mechanics, reused from [AttachmentStore] (same atomic writes and
  /// oldest-first sweep) on this store's own directory and budget.
  final AttachmentStore _files;

  SentImageStore(this._files);

  /// The store living beside [boxPath] (a Hive box file path).
  factory SentImageStore.forBox(String boxPath) => SentImageStore(
    AttachmentStore.forBox(
      boxPath,
      dirName: dirName,
      maxTotalBytes: defaultMaxBytes,
    ),
  );

  /// Blob name for [bytes]: `img_<sha256>.bin`. The hash IS the identity, so
  /// the same picture is never archived twice.
  static String blobName(Uint8List bytes) =>
      AttachmentStore.blobName(_idFor(bytes));

  static String _idFor(Uint8List bytes) => 'img_${sha256.convert(bytes)}';

  /// Archives [bytes] and returns their blob name, or null when the write
  /// failed — the caller then keeps the inline copy, because a picture that
  /// could not be cached is still worth showing.
  Future<String?> put(Uint8List bytes) async {
    final name = blobName(bytes);
    // Already archived (the same picture sent again, or a re-sync replaying
    // bytes this phone already has): nothing to write, nothing to prune.
    if (await _files.get(name) != null) return name;
    return _files.put(_idFor(bytes), bytes);
  }

  /// The archived bytes for [blob], or null when this phone has no copy.
  Future<Uint8List?> get(String blob) => _files.get(blob);

  /// Oldest-first housekeeping, see [defaultMaxBytes].
  Future<void> prune() => _files.prune();
}
