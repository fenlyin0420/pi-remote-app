import 'dart:convert';

import 'package:app/data/local/boxes.dart';

/// Plan/62 — one durable reference to the room's attached binary file.
///
/// `phonePath` is where the bytes live on the phone (the picker's path; the
/// upload service streams from it). `landedPath` is set once the Pi confirms
/// the upload: with it the attachment re-attaches as *sendable* on re-entry,
/// without it the room knows an upload was left unfinished and restarts it.
class AttachmentRecord {
  const AttachmentRecord({
    required this.name,
    required this.size,
    required this.phonePath,
    this.landedPath,
  });

  final String name;
  final int size;
  final String phonePath;
  final String? landedPath;

  bool get landed => landedPath != null;

  String toJson() => jsonEncode({
    'name': name,
    'size': size,
    'phone': phonePath,
    if (landedPath != null) 'landed': landedPath,
  });

  /// Null when the stored value is missing or malformed — a corrupt record
  /// must never resurrect a phantom attachment.
  static AttachmentRecord? fromJson(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map<String, dynamic>) return null;
      final name = m['name'];
      final size = m['size'];
      final phone = m['phone'];
      if (name is! String || size is! int || phone is! String) return null;
      final landed = m['landed'];
      return AttachmentRecord(
        name: name,
        size: size,
        phonePath: phone,
        landedPath: landed is String ? landed : null,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Per-room durable attachment reference (mirrors [DraftStore]: same key
/// space, same box-open-at-bootstrap rule, sync read / async write).
class AttachmentStore {
  final LocalBoxes _boxes;

  AttachmentStore(this._boxes);

  /// The stored record for (peer, room), or null when none was left behind.
  AttachmentRecord? read(String epk, String roomId) {
    final box = _boxes.attachmentsBox();
    final value = box.get(LocalBoxes.sessionKey(epk, roomId));
    return value is String ? AttachmentRecord.fromJson(value) : null;
  }

  Future<void> save(String epk, String roomId, AttachmentRecord record) async {
    await _boxes
        .attachmentsBox()
        .put(LocalBoxes.sessionKey(epk, roomId), record.toJson());
  }

  /// Deletes the record (no-op when none was stored).
  Future<void> clear(String epk, String roomId) async {
    final box = _boxes.attachmentsBox();
    final key = LocalBoxes.sessionKey(epk, roomId);
    if (box.containsKey(key)) await box.delete(key);
  }
}
