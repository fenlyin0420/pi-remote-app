import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/attachments/attachment_store.dart';
import 'package:cryptography/dart.dart';

/// Receives a chunked Pi → App file push (`file_send_start` → `file_send_chunk`
/// ×N → `file_send_end`).
///
/// The mirror of [UploadService], opposite direction: the bytes are appended to
/// a `.part` file and only become the card's blob once the whole-file sha256 the
/// Pi declared matches what actually landed on disk. Nothing is ever shown from
/// a half-written file, and an interrupted transfer leaves the card without
/// bytes (tap to load again) instead of a broken thumbnail.
///
/// Chunks land in `<attachment dir>/.incoming`, a SUBDIRECTORY on purpose:
/// [AttachmentStore.prune] only ever deletes files directly inside the cache
/// dir, so an in-flight transfer can never be mistaken for a stale cache entry
/// and swept away mid-stream.
class IncomingFiles {
  IncomingFiles(this._store);

  /// Largest single file accepted (mirrors the Pi's ceiling).
  static const int maxBytes = 250 * 1024 * 1024;

  /// Nothing legitimately arrives bigger than one chunk; a frame claiming more
  /// is a protocol violation, not a big file.
  static const int maxChunkBytes = 2 * 1024 * 1024;

  /// A `.part` older than this belongs to a transfer whose Pi-side caller is
  /// long gone (the tool times out minutes earlier).
  static const Duration stalePartAge = Duration(hours: 1);

  final AttachmentStore _store;
  final Map<String, _Incoming> _open = {};

  Directory get _dir => Directory('${_store.root.path}/.incoming');

  bool isReceiving(String id) => _open.containsKey(id);

  /// Open a transfer. Throws [IncomingFileError] when the offer cannot be
  /// accepted (bad id, empty/oversized file, no storage) so the caller can tell
  /// the Pi instead of silently dropping the stream.
  Future<void> begin({required String id, required int size}) async {
    if (!_idPattern.hasMatch(id)) {
      throw const IncomingFileError('invalid_id', 'Unsupported file id');
    }
    if (size <= 0) {
      throw const IncomingFileError('invalid_message', 'The file is empty');
    }
    if (size > maxBytes) {
      throw IncomingFileError(
        'too_large',
        'File is too large (max ${maxBytes ~/ (1024 * 1024)} MiB)',
      );
    }
    if (_open.containsKey(id)) {
      throw const IncomingFileError('busy', 'That file is already arriving');
    }
    try {
      await _dir.create(recursive: true);
      await _sweepStaleParts();
      final part = File('${_dir.path}/${_stem(id)}.part');
      if (await part.exists()) await part.delete();
      final sink = await part.open(mode: FileMode.write);
      _open[id] = _Incoming(id: id, size: size, part: part, sink: sink);
    } on FileSystemException catch (e) {
      throw IncomingFileError('io_error', 'Could not open the file: ${e.message}');
    }
  }

  /// Append one chunk and return the bytes received so far. Throws
  /// [IncomingFileError] on a gap, an oversize chunk or a write failure; the
  /// caller aborts the transfer then.
  ///
  /// Chunks are applied one at a time per transfer: the Pi already waits for
  /// each ack, so this only guards against a frame that arrived twice, but the
  /// file handle is shared and interleaved writes would corrupt the order.
  Future<int> append({
    required String id,
    required int index,
    required String data,
  }) {
    final session = _open[id];
    if (session == null) {
      return Future<int>.error(
        const IncomingFileError('session_lost', 'No transfer with that id'),
      );
    }
    final result = session.chain.then((_) => _appendLocked(session, index, data));
    session.chain = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<int> _appendLocked(_Incoming session, int index, String data) async {
    if (index != session.nextIndex) {
      throw IncomingFileError(
        'invalid_message',
        'Expected chunk ${session.nextIndex}, got $index',
      );
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      throw const IncomingFileError('invalid_message', 'Chunk is not valid base64');
    }
    if (bytes.isEmpty || bytes.length > maxChunkBytes) {
      throw const IncomingFileError('invalid_message', 'Chunk has an invalid size');
    }
    if (session.received + bytes.length > session.size) {
      throw const IncomingFileError(
        'invalid_message',
        'More bytes than the declared size arrived',
      );
    }
    try {
      await session.sink.writeFrom(bytes);
    } on FileSystemException catch (e) {
      throw IncomingFileError('io_error', 'Could not store the file: ${e.message}');
    }
    session.received += bytes.length;
    session.nextIndex += 1;
    return session.received;
  }

  /// Verify and publish: checks the size and the whole-file sha256, then moves
  /// the part into the cache under the card's blob name. Returns that name.
  /// Throws [IncomingFileError] (and drops the part) on any mismatch.
  Future<String> finish({required String id, required String sha256}) async {
    final session = _open[id];
    if (session == null) {
      throw const IncomingFileError('session_lost', 'No transfer with that id');
    }
    // Let any chunk still being written settle first: the size/hash verdict is
    // about what ended up on disk.
    await session.chain;
    if (session.received != session.size) {
      await abort(id);
      throw IncomingFileError(
        'incomplete',
        'Only ${session.received} of ${session.size} bytes arrived',
      );
    }
    try {
      await session.sink.flush();
      await session.sink.close();
    } on FileSystemException catch (e) {
      await abort(id);
      throw IncomingFileError('io_error', 'Could not finish the file: ${e.message}');
    }
    _open.remove(id);
    // Hash what is ON DISK, not what we think we wrote: the digest is the only
    // proof that the bytes the Pi hashed are the bytes the phone kept.
    final actual = await _sha256OfFile(session.part);
    if (actual != sha256.toLowerCase()) {
      await _deleteQuietly(session.part);
      throw IncomingFileError(
        'hash_mismatch',
        'The file did not arrive intact (hash mismatch)',
      );
    }
    final blob = AttachmentStore.blobName(id);
    try {
      await session.part.rename('${_store.root.path}/$blob');
    } on FileSystemException catch (e) {
      await _deleteQuietly(session.part);
      throw IncomingFileError('io_error', 'Could not keep the file: ${e.message}');
    }
    // The cache has a soft cap; a file just received is not the oldest entry,
    // but an oversized one still has to make the next sweep honest.
    // ignore: discarded_futures
    _store.prune();
    return blob;
  }

  /// Drop a transfer and its bytes. Safe to call for an unknown id.
  Future<void> abort(String id) async {
    final session = _open.remove(id);
    if (session == null) return;
    await session.close();
    await _deleteQuietly(session.part);
  }

  /// Drop every in-flight transfer (a room/peer switch: their Pi-side senders
  /// fail on their own timeout, and their bytes are garbage here).
  Future<void> abortAll() async {
    for (final id in _open.keys.toList()) {
      await abort(id);
    }
  }

  Future<void> _sweepStaleParts() async {
    try {
      final cutoff = DateTime.now().subtract(stalePartAge);
      await for (final entity in _dir.list()) {
        if (entity is! File || !entity.path.endsWith('.part')) continue;
        if (_open.values.any((s) => s.part.path == entity.path)) continue;
        try {
          if (entity.statSync().modified.isBefore(cutoff)) await entity.delete();
        } catch (_) {
          // Vanished under us — nothing to clean.
        }
      }
    } catch (_) {
      // Housekeeping only.
    }
  }

  static Future<String> _sha256OfFile(File file) async {
    final sink = const DartSha256().newHashSink();
    await for (final chunk in file.openRead()) {
      sink.add(chunk);
    }
    sink.close();
    final digest = await sink.hash();
    return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      await file.delete();
    } catch (_) {
      // Already gone.
    }
  }

  /// One safe path segment for the part file: the id comes off the wire.
  static String _stem(String id) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return safe.isEmpty ? 'file' : safe;
  }

  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,80}$');
}

class _Incoming {
  _Incoming({
    required this.id,
    required this.size,
    required this.part,
    required this.sink,
  });

  final String id;
  final int size;
  final File part;
  final RandomAccessFile sink;
  int received = 0;
  int nextIndex = 0;

  /// Serialises the writes of this transfer (see [IncomingFiles.append]).
  Future<void> chain = Future<void>.value();

  Future<void> close() async {
    try {
      await sink.close();
    } catch (_) {
      // Already closed.
    }
  }
}

/// A refusal or a failure of one receive. [code] goes back to the Pi in
/// `file_send_abort`, [message] is what it shows the model.
class IncomingFileError implements Exception {
  final String code;
  final String message;

  const IncomingFileError(this.code, this.message);

  @override
  String toString() => 'IncomingFileError($code: $message)';
}

/// How far along one incoming file is. In-memory only: an interrupted transfer
/// leaves no trace, and the card simply has no bytes to show.
class FileReceiveProgress {
  final String id;
  final String name;
  final int received;
  final int total;

  const FileReceiveProgress({
    required this.id,
    required this.name,
    required this.received,
    required this.total,
  });

  double get fraction => total <= 0 ? 0 : (received / total).clamp(0.0, 1.0);

  FileReceiveProgress advancedTo(int bytes) => FileReceiveProgress(
    id: id,
    name: name,
    received: bytes,
    total: total,
  );

  @override
  bool operator ==(Object other) =>
      other is FileReceiveProgress &&
      other.id == id &&
      other.name == name &&
      other.received == received &&
      other.total == total;

  @override
  int get hashCode => Object.hash(id, name, received, total);
}
