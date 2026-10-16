import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';

/// Composer attachment state.
///
/// Models the one-attachment pick lifecycle (empty → picking → attached) and
/// carries [visionSupported] so the image entry points can grey out for a
/// text-only model. `visionSupported` is tri-state: `true`/`false` once the
/// model catalogue is known, `null` while unknown (don't gate yet).
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

/// A pick is in flight (camera/gallery/file sheet → read/compress).
final class AttachmentPicking extends AttachmentState {
  const AttachmentPicking({super.visionSupported});

  @override
  bool operator ==(Object other) =>
      other is AttachmentPicking && other.visionSupported == visionSupported;

  @override
  int get hashCode => visionSupported.hashCode;
}

/// What is attached: exactly one of an image, a text file, or a binary
/// file (Plan/62 — its upload runs on pick and the payload flips to
/// "ready" when the Pi confirms).
sealed class AttachmentPayload {
  const AttachmentPayload();
}

final class AttachedImage extends AttachmentPayload {
  const AttachedImage(this.image);

  final PickedImage image;

  @override
  bool operator ==(Object other) =>
      other is AttachedImage && identical(other.image, image);

  @override
  int get hashCode => identityHashCode(image);
}

final class AttachedTextFile extends AttachmentPayload {
  const AttachedTextFile(this.file);

  final PickedTextFile file;

  @override
  bool operator ==(Object other) =>
      other is AttachedTextFile && identical(other.file, file);

  @override
  int get hashCode => file.hashCode;
}

/// A non-text file being streamed to the Pi (Plan/62). [landedPath] is null
/// while the upload is in flight; once set the composer may send — the
/// message then references the file by path only. [progress] is 0–1 while
/// uploading and 1 when landed (null = not started, e.g. a cancelled pick).
final class AttachedBinaryFile extends AttachmentPayload {
  const AttachedBinaryFile({
    required this.name,
    required this.size,
    this.landedPath,
    this.progress,
  });

  final String name;
  final int size;
  final String? landedPath;
  final double? progress;

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

/// One attachment is set and previewed in the composer.
final class AttachmentAttached extends AttachmentState {
  const AttachmentAttached({required this.payload, super.visionSupported});

  final AttachmentPayload payload;

  /// The attached image, or null when the payload is a file.
  PickedImage? get image =>
      payload is AttachedImage ? (payload as AttachedImage).image : null;

  /// The attached text file, or null when the payload is an image.
  PickedTextFile? get file =>
      payload is AttachedTextFile ? (payload as AttachedTextFile).file : null;

  /// The attached binary file (Plan/62), or null otherwise.
  AttachedBinaryFile? get binaryFile => payload is AttachedBinaryFile
      ? payload as AttachedBinaryFile
      : null;

  @override
  bool operator ==(Object other) =>
      other is AttachmentAttached &&
      other.payload == payload &&
      other.visionSupported == visionSupported;

  @override
  int get hashCode => Object.hash(payload, visionSupported);
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
