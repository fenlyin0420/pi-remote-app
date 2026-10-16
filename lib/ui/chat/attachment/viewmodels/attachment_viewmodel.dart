import 'dart:async';
import 'dart:convert';

import 'dart:io';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/attachment_store.dart';
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
///
/// Plan/62 durability: when [AttachmentStore] and a room key are wired in
/// (see [updateRoom]), the binary attachment survives leaving and re-entering
/// the room — landed files re-attach as sendable, unfinished uploads restart.
class AttachmentViewModel extends ViewModel<AttachmentState> {
  /// [store] is optional so tests and non-persistent call sites keep the
  /// old four-argument form.
  AttachmentViewModel(
    this._picker,
    this._anyPicker,
    this._uploads,
    this._actions,
    [AttachmentStore? store])
      : _store = store,
        super(const AttachmentEmpty()) {
    _metaSub = _actions.activeRoomMetaStream.listen((_) => _refreshVision());
    // ignore: discarded_futures
    _refreshVision();
  }

  final IImagePickerService _picker;
  final IAnyFilePickerService _anyPicker;
  final IUploadService _uploads;
  final IActionsRepository _actions;
  final AttachmentStore? _store;

  /// The room this instance's attachment belongs to; the host calls
  /// [updateRoom] as the peer/room identity resolves and on room switches.
  String? _roomEpk;
  String? _roomId;

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
        _clearRecord(); // a text pick replaces any stored binary reference
        return;
      }
      final binary = picked as BinaryFilePick;
      final payload = AttachedBinaryFile(name: binary.name, size: binary.size);
      emit(AttachmentAttached(payload: payload, visionSupported: vision));
      _saveRecord(payload, binary.path, null);
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
      _saveRecord(payload, pick.path, uploaded.path);
    } on UploadError catch (e) {
      if (e.code == 'cancelled') return;
      if (cancelled()) return;
      emit(AttachmentEmpty(visionSupported: state.visionSupported));
      _clearRecord();
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
      if (payload == null) {
        emit(AttachmentEmpty(visionSupported: vision)); // cancelled
      } else {
        emit(AttachmentAttached(payload: payload, visionSupported: vision));
        _clearRecord(); // an image pick replaces any stored binary reference
      }
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
    final s = state;
    if (s is! AttachmentAttached) return;
    if (s.payload is AttachedBinaryFile) _clearRecord();
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
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
    _clearRecord(); // the reference rides along in the message now
    emit(AttachmentEmpty(visionSupported: s.visionSupported));
    return OutgoingFile(name: binary.name, path: binary.landedPath);
  }

  // ---------------------------------------------------------------------------
  // Plan/62 — durable per-room attachment reference
  // ---------------------------------------------------------------------------

  /// The host calls this with the room's identity as it resolves (the peer
  /// record loads async, so the epk arrives a frame later) and on room
  /// switches. A key *change* drops the old room's on-screen attachment (its
  /// record stays stored) and re-hydrates from [AttachmentStore]: a landed
  /// file comes back sendable; an unfinished upload restarts from the phone
  /// copy when that file still exists.
  void updateRoom(String? epk, String? roomId) {
    if (epk == null || roomId == null) return;
    if (epk == _roomEpk && roomId == _roomId) return;
    final s = state;
    if (s is AttachmentAttached && s.payload is AttachedBinaryFile) {
      emit(AttachmentEmpty(visionSupported: s.visionSupported));
    }
    _roomEpk = epk;
    _roomId = roomId;
    final store = _store;
    if (store == null) return;
    final record = store.read(epk, roomId);
    if (record == null) return;
    final vision = state.visionSupported;
    if (record.landed) {
      emit(AttachmentAttached(
        payload: AttachedBinaryFile(
          name: record.name,
          size: record.size,
          landedPath: record.landedPath,
          progress: 1,
        ),
        visionSupported: vision,
      ));
      return;
    }
    // Unfinished upload — resume it only when the phone-side bytes survive.
    if (!File(record.phonePath).existsSync()) return;
    final payload = AttachedBinaryFile(name: record.name, size: record.size);
    final pick = BinaryFilePick(
      name: record.name,
      path: record.phonePath,
      size: record.size,
    );
    emit(AttachmentAttached(payload: payload, visionSupported: vision));
    _saveRecord(payload, record.phonePath, null);
    // ignore: unawaited_futures
    _uploadBinary(payload, pick);
  }

  void _saveRecord(
    AttachedBinaryFile payload,
    String phonePath,
    String? landedPath,
  ) {
    final store = _store;
    final epk = _roomEpk;
    final roomId = _roomId;
    if (store == null || epk == null || roomId == null) return;
    // ignore: unawaited_futures
    store.save(
      epk,
      roomId,
      AttachmentRecord(
        name: payload.name,
        size: payload.size,
        phonePath: phonePath,
        landedPath: landedPath,
      ),
    );
  }

  void _clearRecord() {
    final store = _store;
    final epk = _roomEpk;
    final roomId = _roomId;
    if (store == null || epk == null || roomId == null) return;
    // ignore: unawaited_futures
    store.clear(epk, roomId);
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
