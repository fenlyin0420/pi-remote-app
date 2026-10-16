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

/// Plan/30+62+63 — drives the composer's attachment tray: any mix of images,
/// text files, and binary files, one chip per item.
///
/// Owns the picked-attachment preview state and tracks whether the active
/// model accepts images (`vision`). Vision is resolved from the model
/// catalogue the app already fetches for the quick-actions picker (plan 28):
/// cached in [IActionsRepository], re-resolved whenever the active model
/// changes. It gates the camera/gallery entries only — a text file is fine on
/// any model.
///
/// Plan/62 durability: when [AttachmentStore] and a room key are wired in
/// (see [updateRoom]), the binary attachments survive leaving and re-entering
/// the room — landed files re-attach as sendable, unfinished uploads restart.
/// Images and text files ride the message inline and are not persisted.
///
/// Plan/63 — the tray holds several items at once. Each binary item streams
/// to the Pi in its own upload (concurrent, independent progress, independent
/// failure: a rejected file drops out of the tray without touching its
/// siblings). The send path takes the whole tray at once: the send button
/// stays gated while any binary upload is in flight (wait-all, see
/// [anyUploading]), then [takeForSend] hands over every landed image and file.
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

  /// The room this instance's tray belongs to; the host calls [updateRoom] as
  /// the peer/room identity resolves and on room switches.
  String? _roomEpk;
  String? _roomId;

  /// Re-entrancy guard for the (modal) pick sheets — the tray preview stays
  /// up while the sheet is open, so no "picking" state is emitted.
  bool _picking = false;

  StreamSubscription<ActiveRoomMeta>? _metaSub;
  bool _resolvingVision = false;

  final StreamController<AttachHint> _hints =
      StreamController<AttachHint>.broadcast();

  /// One-shot hints (permission denied / pick failed / oversized file) for
  /// the host page.
  Stream<AttachHint> get hints => _hints.stream;

  /// The tray's current items (empty outside [AttachmentAttached]).
  List<AttachmentItem> get _items {
    final s = state;
    return s is AttachmentAttached ? s.items : const [];
  }

  /// True while any attachment (image, text file, or binary) is set.
  bool get hasAttachment => _items.isNotEmpty;

  /// True while an *image* is set (drives the thumbnail chips + the
  /// image-specific send rules such as the empty-caption send).
  bool get hasImage => _items.any((i) => i is AttachedImage);

  /// Plan/63 wait-all gating: true while any binary upload is in flight.
  /// Images and text files are instant (on-device), so only binaries hold
  /// the send button back.
  bool get anyUploading {
    final s = state;
    return s is AttachmentAttached && s.anyUploading;
  }

  /// True when the active model cannot take images — the host greys out the
  /// camera/gallery entries and leaves files alone.
  bool get imageBlockedByVision => state.imageBlockedByVision;

  // ---------------------------------------------------------------------------
  // Picking (multi)
  // ---------------------------------------------------------------------------

  Future<void> pickFromCamera() => _pickImages(() async {
    final image = await _picker.pickFromCamera();
    return image == null ? null : [image];
  });

  /// Plan/63 — the gallery picks several images at once; each lands in the
  /// tray as its own chip.
  Future<void> pickFromGallery() => _pickImages(_picker.pickMultipleFromGallery);

  /// Pick files (unrestricted, multi), classified by content (never by
  /// name): text content attaches inline as before (Plan/30); anything else
  /// starts a Plan/62 chunked upload **on pick** — the user sees progress per
  /// file while typing the caption, and the message later references the
  /// landed files by path.
  ///
  /// An oversized pick aborts the whole batch (the [AttachHint.fileTooLarge]
  /// names the offender); the user re-picks the rest.
  Future<void> pickFile() async {
    if (_picking) return;
    _picking = true;
    try {
      final picked = await _anyPicker.pickFiles();
      if (picked == null) return; // cancelled — the tray stays as is
      final items = <AttachmentItem>[..._items];
      // Explicit `is`-blocks (not an if/else collection): the kernel
      // compiler only promotes inside plain if-blocks.
      for (final p in picked) {
        if (p is BinaryFilePick) {
          final item = AttachedBinaryFile(
            name: p.name,
            size: p.size,
            phonePath: p.path,
          );
          items.add(item);
          // ignore: unawaited_futures
          _uploadBinary(item, p);
        } else if (p is TextFilePick) {
          items.add(AttachedTextFile(p.file));
        }
      }
      _emitTray(items);
      _persist();
    } on FileTooLargeException {
      if (!_hints.isClosed) _hints.add(AttachHint.fileTooLarge);
    } catch (_) {
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    } finally {
      _picking = false;
    }
  }

  /// Streams one binary item to the Pi; the item flips to "landed" (sendable)
  /// on the Pi's confirmation, or the item is dropped out of the tray with an
  /// [AttachHint.uploadFailed] on rejection/timeout — siblings are untouched.
  Future<void> _uploadBinary(
    AttachedBinaryFile item,
    BinaryFilePick pick,
  ) async {
    bool cancelled() {
      final s = state;
      if (s is! AttachmentAttached) return true;
      return !s.items.any((i) => identical(i, item));
    }
    try {
      final uploaded = await _uploads.upload(
        path: pick.path,
        name: pick.name,
        onProgress: (sent, total) {
          if (cancelled()) return;
          _setBinaryProgress(item, sent / total);
        },
        shouldCancel: cancelled,
      );
      if (cancelled()) return; // the item was removed mid-flight
      _replaceItem(
        item,
        AttachedBinaryFile(
          name: item.name,
          size: item.size,
          phonePath: item.phonePath,
          landedPath: uploaded.path,
          progress: 1,
        ),
      );
      _persist();
    } on UploadError catch (e) {
      if (e.code == 'cancelled') return;
      if (cancelled()) return;
      final s = state;
      if (s is! AttachmentAttached) return;
      _emitTray([
        for (final i in s.items) if (!identical(i, item)) i,
      ]);
      _persist();
      if (!_hints.isClosed) {
        _hints.add(
          e.code == 'upload_rejected'
              ? AttachHint.uploadRejected
              : AttachHint.uploadFailed,
        );
      }
    }
  }

  void _setBinaryProgress(AttachedBinaryFile item, double fraction) {
    final s = state;
    if (s is! AttachmentAttached) return;
    _emitTray([
      for (final i in s.items)
        if (identical(i, item))
          AttachedBinaryFile(
            name: (i as AttachedBinaryFile).name,
            size: i.size,
            phonePath: i.phonePath,
            progress: fraction,
          )
        else
          i,
    ]);
  }

  void _replaceItem(AttachmentItem old, AttachmentItem replacement) {
    final s = state;
    if (s is! AttachmentAttached) return;
    _emitTray([
      for (final i in s.items) if (identical(i, old)) replacement else i,
    ]);
  }

  /// Shared lifecycle for the image sources: the picked images land in the
  /// tray as their own chips. Null means the user cancelled — the tray stays
  /// as it was.
  Future<void> _pickImages(Future<List<PickedImage>?> Function() pick) async {
    if (_picking) return;
    _picking = true;
    try {
      final images = await pick();
      if (images == null || images.isEmpty) return; // cancelled
      _emitTray([
        ..._items,
        for (final image in images) AttachedImage(image),
      ]);
    } on ImagePermissionDeniedException {
      if (!_hints.isClosed) _hints.add(AttachHint.cameraPermissionDenied);
    } catch (_) {
      if (!_hints.isClosed) _hints.add(AttachHint.pickFailed);
    } finally {
      _picking = false;
    }
  }

  /// Discard one tray item (the "X" on its chip, #4). A binary item's in-
  /// flight upload is aborted through its `shouldCancel` closure; the store
  /// is rewritten without it.
  void removeItem(int index) {
    final s = state;
    if (s is! AttachmentAttached) return;
    if (index < 0 || index >= s.items.length) return;
    final removed = s.items[index];
    _emitTray([
      for (final i in s.items) if (!identical(i, removed)) i,
    ]);
    if (removed is AttachedBinaryFile) _persist();
  }

  /// Hand the whole tray to the send path: every image as a base64
  /// [MessageImage], every text file with its content inline, every landed
  /// binary file (Plan/62) as a `{ name, path }` reference — then reset the
  /// tray to empty. The caller gates on [anyUploading] (wait-all), so a
  /// not-yet-landed binary never reaches this point.
  ({List<MessageImage> images, List<OutgoingFile> files}) takeForSend() {
    final s = state;
    if (s is! AttachmentAttached) {
      return (images: const [], files: const []);
    }
    final images = [
      for (final i in s.items)
        if (i is AttachedImage)
          MessageImage(data: base64Encode(i.image.bytes), mime: i.image.mime),
    ];
    final files = [
      for (final i in s.items)
        if (i is AttachedTextFile)
          OutgoingFile(name: i.file.name, text: i.file.text)
        else if (i is AttachedBinaryFile && i.landed)
          OutgoingFile(name: i.name, path: i.landedPath),
    ];
    // Reset the tray FIRST, then persist: _persist reads the tray from the
    // current state, so it must run after the reset or it would rewrite the
    // just-sent records instead of clearing them.
    _emitTray(const []);
    _persist();
    return (images: images, files: files);
  }

  // ---------------------------------------------------------------------------
  // Plan/62 — durable per-room binary references
  // ---------------------------------------------------------------------------

  /// The host calls this with the room's identity as it resolves (the peer
  /// record loads async, so the epk arrives a frame later) and on room
  /// switches. A key *change* drops the old room's tray (its records stay
  /// stored) and re-hydrates the binary items from [AttachmentStore]: landed
  /// files come back sendable; unfinished uploads restart from the phone
  /// copy when that file still exists.
  void updateRoom(String? epk, String? roomId) {
    if (epk == null || roomId == null) return;
    if (epk == _roomEpk && roomId == _roomId) return;
    _roomEpk = epk;
    _roomId = roomId;
    _emitTray(const []); // the old room's tray is done
    final store = _store;
    if (store == null) return;
    final items = <AttachmentItem>[];
    for (final record in store.read(epk, roomId)) {
      if (record.landed) {
        items.add(
          AttachedBinaryFile(
            name: record.name,
            size: record.size,
            phonePath: record.phonePath,
            landedPath: record.landedPath,
            progress: 1,
          ),
        );
        continue;
      }
      // Unfinished upload — resume it only when the phone-side bytes
      // survive.
      if (!File(record.phonePath).existsSync()) continue;
      final pick = BinaryFilePick(
        name: record.name,
        path: record.phonePath,
        size: record.size,
      );
      final item = AttachedBinaryFile(
        name: record.name,
        size: record.size,
        phonePath: record.phonePath,
      );
      items.add(item);
      // ignore: unawaited_futures
      _uploadBinary(item, pick);
    }
    if (items.isEmpty) return;
    _emitTray(items);
    _persist();
  }

  /// Rewrites the room's durable tray from the current binary items (the
  /// store keeps binary references only — images and text files ride the
  /// message).
  void _persist() {
    final store = _store;
    final epk = _roomEpk;
    final roomId = _roomId;
    if (store == null || epk == null || roomId == null) return;
    final records = [
      for (final i in _items)
        if (i is AttachedBinaryFile)
          AttachmentRecord(
            name: i.name,
            size: i.size,
            phonePath: i.phonePath ?? '',
            landedPath: i.landedPath,
          ),
    ];
    // ignore: unawaited_futures
    store.save(epk, roomId, records);
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

  void _emitTray(List<AttachmentItem> items) {
    final vision = state.visionSupported;
    emit(items.isEmpty
        ? AttachmentEmpty(visionSupported: vision)
        : AttachmentAttached(items: items, visionSupported: vision));
  }

  void _setVision(bool? vision) {
    if (vision == state.visionSupported) return;
    emit(switch (state) {
      AttachmentEmpty() => AttachmentEmpty(visionSupported: vision),
      AttachmentAttached(:final items) => AttachmentAttached(
        items: items,
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
