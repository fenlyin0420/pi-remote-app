import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';

/// Composer attachment state.
///
/// Models the pick lifecycle (empty → picking → attached) and carries
/// [visionSupported] so the image entry points can grey out for a text-only
/// model. `visionSupported` is tri-state: `true`/`false` once the model
/// catalogue is known, `null` while unknown (don't gate yet).
///
/// Vision never gates a *file*: any model can read a text file.
sealed class AttachmentState {
  const AttachmentState({required this.visionSupported});

  /// Whether the active model accepts images. `null` = not yet known.
  final bool? visionSupported;

  /// Convenience: gate the image options only when we *know* it's false.
  bool get imageBlockedByVision => visionSupported == false;
}

/// Nothing attached; composer behaves as text/voice.
final class AttachmentEmpty extends AttachmentState {
  const AttachmentEmpty({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentEmpty && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// One attachment in the composer's tray. Multiple items of any mix (image +
/// text files + binary files, Plan/63) coexist; each chip in the preview row
/// is one item and can be removed independently.
sealed class AttachmentItem {
  const AttachmentItem();
}

/// A picked, on-device-compressed image (base64-encodes at send time).
final class AttachedImage extends AttachmentItem {
  const AttachedImage(this.image);

  final PickedImage image;

  @override
  bool operator ==(Object other) =>
      other is AttachedImage && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
}

/// A text file whose content rides inline on the message (Plan/30).
final class AttachedTextFile extends AttachmentItem {
  const AttachedTextFile(this.file);

  final PickedTextFile file;

  @override
  bool operator ==(Object other) =>
      other is AttachedTextFile && identical(other.file, file);

  @override
  int get hashCode => file.hashCode;
}

/// A non-text file being streamed to the Pi (Plan/62). [landedPath] is null
/// while the upload is in flight; once set the item counts as sendable — the
/// message then references the file by path only. [progress] is 0–1 while
/// uploading and 1 when landed (null = not started, e.g. a cancelled pick).
final class AttachedBinaryFile extends AttachmentItem {
  const AttachedBinaryFile({
    required this.name,
    required this.size,
    this.landedPath,
    this.progress,
    this.phonePath,
  });

  final String name;
  final int size;
  final String? landedPath;
  final double? progress;

  /// Where the bytes live on the phone (the picker's cache path) — kept for
  /// the durable store so an unfinished upload can restart on re-entry.
  /// Excluded from equality: progress ticks rebuild the item.
  final String? phonePath;

  /// The Pi confirmed; the send path may reference [landedPath].
  bool get landed => landedPath != null;

  @override
  bool operator ==(Object other) =>
      other is AttachedBinaryFile &&
      other.name == name &&
      other.size == size &&
      other.landedPath == landedPath &&
      other.progress == progress;

  @override
  int get hashCode => Object.hash(name, size, landedPath, progress);
}

/// The tray holds at least one item and previews it in the composer, one chip
/// per item.
final class AttachmentAttached extends AttachmentState {
  const AttachmentAttached({required this.items, super.visionSupported});

  final List<AttachmentItem> items;

  /// Plan/63 — wait-all send gating: true while any binary upload is still in
  /// flight. Images and text files are instant (on-device), so only binaries
  /// hold the send back.
  bool get anyUploading =>
      items.any((i) => i is AttachedBinaryFile && !i.landed);

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      other.items.length == items.length &&
      [
        for (var i = 0; i < items.length; i++) other.items[i] == items[i],
      ].every((same) => same) &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hashAll(items) ^ visionSupported.hashCode;
}

/// One-shot hints the composer asks the host page to surface (snackbar /
/// settings deep-link), mirroring the voice [VoiceHint] pattern.
enum AttachHint {
  /// Camera permission denied — guide to system Settings (#10).
  cameraPermissionDenied,

  /// The picked file exceeds the Plan/62 upload cap (250 MiB).
  fileTooLarge,

  /// The chunked upload was rejected or timed out.
  uploadFailed,

  /// The Pi refused the session (concurrency cap or a foreign id) — a
  /// transient condition, not a connection problem.
  uploadRejected,

  /// Pick/read/compress failed for some other reason.
  pickFailed,
}
