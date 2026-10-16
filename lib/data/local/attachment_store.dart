import 'dart:convert';

import 'package:app/data/local/boxes.dart';

/// Plan/62 — one durable reference to an attached binary file in the room's
/// tray.
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

/// Per-room durable attachment tray (mirrors [DraftStore]: same key space,
/// same box-open-at-bootstrap rule, sync read / async write).
///
/// Plan/63 — the tray now holds several binary files: the stored value is a
/// JSON array of records. Rows persisted by Plan/62 builds hold a single
/// record object — [read] accepts both shapes.
class AttachmentStore {
  final LocalBoxes _boxes;

  AttachmentStore(this._boxes);

  /// The stored tray for (peer, room); empty when nothing was left behind.
  List<AttachmentRecord> read(String epk, String roomId) {
    final box = _boxes.attachmentsBox();
    final value = box.get(LocalBoxes.sessionKey(epk, roomId));
    if (value is! String) return const [];
    try {
      final decoded = jsonDecode(value);
      if (decoded is List) {
        final records = <AttachmentRecord>[];
        for (final entry in decoded) {
          if (entry is! Map) continue;
          final record = AttachmentRecord.fromJson(jsonEncode(entry));
          if (record != null) records.add(record);
        }
        return records;
      }
      if (decoded is Map) {
        // Plan/62 single-record shape.
        final record = AttachmentRecord.fromJson(jsonEncode(decoded));
        return record == null ? const [] : [record];
      }
    } catch (_) {
      // A corrupt tray never resurrects phantom attachments.
    }
    return const [];
  }

  /// Replaces the whole tray. An empty list clears the entry.
  Future<void> save(
    String epk,
    String roomId,
    List<AttachmentRecord> records,
  ) async {
    final box = _boxes.attachmentsBox();
    final key = LocalBoxes.sessionKey(epk, roomId);
    if (records.isEmpty) {
      if (box.containsKey(key)) await box.delete(key);
      return;
    }
    await box.put(
      key,
      jsonEncode([for (final r in records) jsonDecode(r.toJson())]),
    );
  }

  /// Deletes the tray (no-op when none was stored).
  Future<void> clear(String epk, String roomId) async {
    final box = _boxes.attachmentsBox();
    final key = LocalBoxes.sessionKey(epk, roomId);
    if (box.containsKey(key)) await box.delete(key);
  }
}
