import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/30 — drives the composer's single attachment (one image or one text
/// file).
///
/// Owns the picked-attachment preview state and tracks whether the active
/// model accepts images (`vision`). Vision is resolved from the model
/// catalogue the app already fetches for the quick-actions picker (plan 28):
/// cached in [IActionsRepository], re-resolved whenever the active model
/// changes. It gates the camera/gallery entries only — a text file is fine on
/// any model.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  AttachmentViewModel(this._picker, this._anyPicker, this._uploads, this._actions)
    : super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  final IImagePickerService _picker;
  final IAnyFilePickerService _anyPicker;
  final IUploadService _uploads;
  final IActionsRepository _actions;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed / not a text file) for
  /// the host page.
  Stream<AttachHint> get hints => _hints.stream;

  /// True while any attachment (image or file) is set.
  bool get hasAttachment => state is AttachmentAttached;

  /// True while an *image* is set (drives the thumbnail preview + the
  /// image-specific send rules such as the empty-caption send).
  bool get hasImage {
    final s = state;
    return s is AttachmentAttached && s.image != null;
  }

  /// True when the active model cannot take images — the host greys out the
  /// camera/gallery entries and leaves files alone.
  bool get imageBlockedByVision => state.imageBlockedByVision;

  // ---------------------------------------------------------------------------
  // Picking
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pick(() async {
    final image = await _picker.pickFromCamera();
    return image == null ? null : AttachedImage(image);
  });

  Future<void> pickFromGallery() => _pick(() async {
    final image = await _picker.pickFromGallery();
    return image == null ? null : AttachedImage(image);
  });

  /// Pick any file, classified by content (never by name): text content
  /// attaches inline as before (Plan/30); anything else starts a Plan/62
  /// chunked upload **on pick** — the user sees progress while typing the
  /// caption, and the message later references the landed file by path.
  Future<void> pickFile() async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final picked = await _anyPicker.pickFile();
      if (picked == null) {
        emit(AttachmentEmpty(visionSupported: vision)); // cancelled
        return;
      }
      if (picked is TextFilePick) {
        emit(AttachmentAttached(
          payload: AttachedTextFile(picked.file),
          visionSupported: vision,
        ));
        return;
      }
      final binary = picked as BinaryFilePick;
      final payload = AttachedBinaryFile(name: binary.name, size: binary.size);
      emit(AttachmentAttached(payload: payload, visionSupported: vision));
      // Awaited (not fire-and-forget) so the host page's hint subscription
      // is still alive when an early rejection lands.
      await _uploadBinary(payload, binary);
    } on FileTooLargeException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.fileTooLarge);
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Streams the picked binary file to the Pi; the payload flips to
  /// "landed" (sendable) on the Pi's confirmation, or the attachment is
  /// dropped with an [AttachHint.uploadFailed] on rejection/timeout.
  Future<void> _uploadBinary(
    AttachedBinaryFile payload,
    BinaryFilePick pick,
  ) async {
    bool cancelled() {
      final s = state;
      if (s is! AttachmentAttached) return true;
      final p = s.payload;
      return p is! AttachedBinaryFile ||
          p.name != payload.name ||
          p.size != payload.size;
    }
    try {
      final uploaded = await _uploads.upload(
        path: pick.path,
        name: pick.name,
        onProgress: (sent, total) {
          if (cancelled()) return;
          _setBinaryProgress(payload, sent / total);
        },
        shouldCancel: cancelled,
      );
      if (cancelled()) return; // the attachment was removed mid-flight
      emit(AttachmentAttached(
        payload: AttachedBinaryFile(
          name: payload.name,
          size: payload.size,
          landedPath: uploaded.path,
          progress: 1,
        ),
        visionSupported: state.visionSupported,
      ));
    } on UploadError catch (e) {
      if (e.code == 'cancelled') return;
      if (cancelled()) return;
      emit(AttachmentEmpty(visionSupported: state.visionSupported));
      if (!_hints.isClosed) {
        _hints.add(
          e.code == 'upload_rejected'
              ? AttachHint.uploadRejected
              : AttachHint.uploadFailed,
        );
      }
    }
  }

  void _setBinaryProgress(AttachedBinaryFile payload, double fraction) {
    final s = state;
    if (s is! AttachmentAttached || s.payload is! AttachedBinaryFile) return;
    emit(AttachmentAttached(
      payload: AttachedBinaryFile(
        name: payload.name,
        size: payload.size,
        progress: fraction,
      ),
      visionSupported: state.visionSupported,
    ));
  }

  /// Shared lifecycle for the image sources: picking → attached, or back to
  /// empty with a one-shot hint. A null payload means the user cancelled.
  Future<void> _pick(Future<AttachmentPayload?> Function() pick) async {
    if (state is AttachmentPicking) return;
    final vision = state.visionSupported;
    emit(AttachmentPicking(visionSupported: vision));
    try {
      final payload = await pick();
      emit(
        payload == null
            ? AttachmentEmpty(visionSupported: vision) // cancelled
            : AttachmentAttached(payload: payload, visionSupported: vision),
      );
    } on ImagePermissionDeniedException {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      emit(AttachmentEmpty(visionSupported: vision));
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    }
  }

  /// Discard the attached item (the "X" on the preview, #4).
  void removeAttachment() {
    if (state is! AttachmentAttached) return;
    emit(AttachmentEmpty(visionSupported: state.visionSupported));
  }

  /// Hand the attached image to the send path as a base64 [MessageImage] and
  /// reset to empty. Returns null when no image is attached.
  MessageImage? takeImageForSend() {
    final s = state;
    if (s is! AttachmentAttached) return null;
    final image = s.image;
    if (image == null) return null;
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return MessageImage(data: base64Encode(image.bytes), mime: image.mime);
  }

  /// Hand the attached file to the send path and reset to empty. A text
  /// file's content travels inline; a landed binary file (Plan/62) travels
  /// as a `{ name, path }` reference. Returns null when no file is attached
  /// or the binary upload has not been confirmed yet.
  OutgoingFile? takeFileForSend() {
    final s = state;
    if (s is! AttachmentAttached) return null;
    final file = s.file;
    if (file != null) {
      emit(AttachmentEmpty(visionSupported: s.visionSupported));
      return OutgoingFile(name: file.name, text: file.text);
    }
    final binary = s.binaryFile;
    if (binary == null || !binary.landed) return null;
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return OutgoingFile(name: binary.name, path: binary.landedPath);
  }

  // ---------------------------------------------------------------------------
  // Vision tracking (#9)
  // ---------------------------------------------------------------------------

  Future<void> _refreshVision() async {
    if (_resolvingVision) return;
    _resolvingVision = true;
    try {
      // Cached per (peer, room) by the repo; only the round-trip after a real
      // model change actually hits the Pi.
      final catalogue = await _actions.listModels();
      _setVision(_resolveVision(catalogue));
    } catch (_) {
      // Offline / no catalogue yet → leave vision unknown (don't gate).
    } finally {
      _resolvingVision = false;
    }
  }

  bool? _resolveVision(ModelsCatalogue catalogue) {
    final current = catalogue.current;
    if (current != null) return current.vision;
    // No explicit current — match the active room's model name.
    final name = _actions.activeRoomMeta.model;
    if (name != null) {
      for (final m in catalogue.models) {
        if (m.name == name) return m.vision;
      }
    }
    return null;
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentPicking() => AttachmentPicking(visionSupported: vision),
      AttachmentAttached(:final payload) => AttachmentAttached(
        payload: payload,
        visionSupported: vision,
      ),
    });
  }

  @override
  void dispose() {
    _metaSub?.cancel();
    _hints.close();
    super.dispose();
  }
}
