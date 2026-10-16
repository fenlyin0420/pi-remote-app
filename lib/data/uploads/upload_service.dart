import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/dart.dart';

/// Plan/62 — chunked binary upload (app → Pi).
///
/// Files that are neither text nor images (PDF, Office docs, archives, …)
/// cannot ride a single 4 MiB envelope, so the file is streamed in base64
/// chunks: `upload_start` → `upload_chunk` ×N → `upload_done` (with the
/// whole-file sha256). Each chunk's envelope stays under the relay's `ct`
/// ceiling. The Pi reassembles, verifies and answers with an
/// [UploadComplete] carrying the landed path; the message that references
/// the file then carries `{ name, path }` only — no bytes.
///
/// Deliberately simple: no chunk-level resume. A drop restarts the upload
/// (the Pi TTL-reaps the partial `.part` file).

/// Largest single file accepted (mirrors the Pi's ceiling).
const int uploadMaxBytes = 250 * 1024 * 1024;

/// Bytes per chunk: base64 → ~2.7 MiB of inner JSON → `ct` ≈ 3.7 MiB <
/// 4 MiB, leaving 11% headroom for the frame overhead.
const int uploadChunkBytes = 2 * 1024 * 1024;

/// How long to wait for the Pi's `upload_complete` after the final frame.
const Duration uploadAckTimeout = Duration(seconds: 30);

/// How long one frame send may take before it is treated as a dead
/// transport. A half-dead socket (peer gone, TCP not closed) swallows
/// bytes and never completes the send future; without this bound a
/// mid-stream drop would freeze the progress bar forever instead of
/// tripping the reconnect-retry.
const Duration uploadSendTimeout = Duration(seconds: 30);

/// How many times [UploadService.upload] restarts a transfer after a
/// transient transport failure (channel died mid-stream → `io_error`).
const int uploadMaxReconnects = 3;

/// How long one restart waits for the channel to come back.
const Duration uploadReconnectTimeout = Duration(minutes: 3);

/// The Pi's answer to a finished upload: where the file landed.
class UploadedFile {
  final String name;
  final String path;

  const UploadedFile({required this.name, required this.path});
}

class UploadError implements Exception {
  final String code;
  final String message;

  const UploadError(this.code, this.message);

  @override
  String toString() => 'UploadError($code: $message)';
}

abstract class IUploadService {
  /// Streams the phone-side file at [path] to the paired Pi in chunks.
  ///
  /// [name] is the leaf name as the user picked it (the Pi sanitises it to
  /// one safe path segment). [onProgress] fires per chunk with the bytes
  /// already sent and the total. Completes with the [UploadedFile] the Pi
  /// reports; throws [UploadError] on rejection (size cap, hash mismatch,
  /// …) or when no online connection exists.
  ///
  /// [shouldCancel] is polled between chunks — return true to abandon
  /// (the Pi reaps the partial file on its TTL; no cancel frame).
  ///
  /// [room] pins every frame of this transfer to that Pi room instead of the
  /// connection's live active room. The active room is a single mutable field
  /// several chat pages re-assert, so it can move mid-transfer; a frame sent
  /// to a room the Pi is not registered under is dropped by the relay with no
  /// error on either end. Pass the room the attachment belongs to.
  ///
  /// A transient transport failure (channel dead mid-stream) restarts the
  /// whole upload once the channel is back — [reconnectTimeout] bounds how
  /// long one restart waits for that (default [uploadReconnectTimeout]).
  Future<UploadedFile> upload({
    required String path,
    required String name,
    String? room,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
    Duration reconnectTimeout = uploadReconnectTimeout,
    Duration sendTimeout = uploadSendTimeout,
    Duration ackTimeout = uploadAckTimeout,
  });
}

class UploadService implements IUploadService {
  /// [channel] is re-read on every poll, so a mid-upload reconnect (new
  /// channel object) is picked up by the retry loop without a restart of
  /// this service.
  UploadService(ConnectionManager conn) : _channel = _ofConn(conn);

  /// Test seam: inject the channel provider directly.
  const UploadService.withChannelProvider(IChannel? Function() channel)
      : _channel = channel;

  static IChannel? Function() _ofConn(ConnectionManager conn) {
    return () => conn.channel;
  }

  final IChannel? Function() _channel;

  @override
  Future<UploadedFile> upload({
    required String path,
    required String name,
    String? room,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
    Duration reconnectTimeout = uploadReconnectTimeout,
    Duration sendTimeout = uploadSendTimeout,
    Duration ackTimeout = uploadAckTimeout,
  }) async {
    // The in-flight transfer is bound to the channel it started on: a
    // transport drop (ping keepalive → reconnect) kills it with `io_error`.
    // Rather than surfacing that as a failure, restart the whole upload on
    // the fresh channel (fresh session id; the Pi reaps the old `.part` on
    // its idle sweep). Only `io_error` qualifies — rejections, size caps,
    // cancellation and "never connected" are final.
    for (var attempt = 0; ; attempt++) {
      if (attempt > 0 && shouldCancel?.call() == true) {
        throw const UploadError('cancelled', 'Upload cancelled');
      }
      final ch = _channel();
      if (ch == null) {
        if (attempt == 0) {
          throw const UploadError('offline', 'Not connected to the Pi');
        }
        if (!await _waitChannel(reconnectTimeout)) {
          throw const UploadError(
            'timeout',
            'Lost the connection before it came back',
          );
        }
        continue; // the channel is back — retry on it below
      }
      try {
        return await streamUpload(
          ch: ch,
          path: path,
          name: name,
          room: room,
          onProgress: onProgress,
          shouldCancel: shouldCancel,
          sendTimeout: sendTimeout,
          ackTimeout: ackTimeout,
        );
      } on UploadError catch (e) {
        // `io_error` = the transport died mid-stream; `timeout` = the done
        // frame was sent but the Pi's answer got lost (or the transport
        // went down in that last stretch); `upload_session_lost` = the Pi
        // lost the session to ITS OWN relay transport drop — the start
        // frame was swallowed by a dead socket, so only the chunks arrive
        // and the Pi rejects them. All three are safe to restart: a fresh
        // attempt (new id + start) on the reconnected channel lands
        // cleanly, and the Pi de-duplicates by sha256, so a re-upload of
        // an already-landed file resolves to the same path.
        final canRetry = (e.code == 'io_error' ||
                e.code == 'timeout' ||
                e.code == 'upload_session_lost') &&
            attempt < uploadMaxReconnects;
        if (!canRetry) rethrow;
        onProgress?.call(0, 0); // the restart re-streams from the beginning
      }
    }
  }

  /// Polls until the transport has a live channel again or [timeout] elapses.
  Future<bool> _waitChannel(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_channel() != null) return true;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return _channel() != null;
  }

  /// The channel-facing core (testable without a live ConnectionManager):
  /// streams [path] over [ch] and resolves when the Pi confirms. Pre-checks:
  /// empty file → [UploadError]('empty'), > [uploadMaxBytes] → 'too_large'.
  ///
  /// [room] (when set and supported by the channel) pins every frame —
  /// including each retry's start — at that room.
  static Future<UploadedFile> streamUpload({
    required IChannel ch,
    required String path,
    required String name,
    String? room,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
    Duration sendTimeout = uploadSendTimeout,
    Duration ackTimeout = uploadAckTimeout,
  }) async {
    final file = File(path);
    final int total;
    try {
      total = await file.length();
    } catch (e) {
      throw UploadError('io_error', 'Could not read the file: $e');
    }
    if (total == 0) {
      throw const UploadError('empty', 'The file is empty — nothing to send');
    }
    if (total > uploadMaxBytes) {
      throw UploadError(
        'too_large',
        'File is too large (max ${uploadMaxBytes ~/ (1024 * 1024)} MiB)',
      );
    }

    final id = _sessionToken();
    final completer = Completer<UploadedFile>();
    // The Pi may reject (error frame) before the streaming loop reaches the
    // await below — keep that early error from floating as an unhandled
    // async error; the awaited future below still sees it.
    completer.future.ignore();
    StreamSubscription<ServerMessage>? sub;
    sub = ch.serverMessages.listen((m) {
      if (completer.isCompleted) return;
      if (m is UploadComplete && (m.id == id || m.inReplyTo == id)) {
        completer.complete(
          UploadedFile(name: m.name, path: m.path),
        );
        sub?.cancel();
      } else if (m is ErrorMessage && m.inReplyTo == id) {
        completer.completeError(UploadError(m.code, m.message));
        sub?.cancel();
      }
    });

    try {
      await _sendTimed(
        ch,
        UploadStart(id: id, name: name, size: total),
        sendTimeout,
        room: room,
      );
      // The whole-file sha256 is folded in from the very chunks we send —
      // the file is read once, and a 250 MiB pick never lands in memory
      // whole.
      final shaSink = const DartSha256().newHashSink();
      final raf = await file.open();
      try {
        var offset = 0;
        var index = 0;
        while (offset < total) {
          if (completer.isCompleted) {
            // The Pi already answered this session (reject or confirm) —
            // stop streaming; the returned future carries the outcome and no
            // failing await follows this line.
            // ignore: unawaited_return_in_try_block
            return completer.future;
          }
          if (shouldCancel != null && shouldCancel()) {
            throw const UploadError('cancelled', 'Upload cancelled');
          }
          final len = total - offset > uploadChunkBytes
              ? uploadChunkBytes
              : total - offset;
          final bytes = await raf.read(len);
          shaSink.add(bytes);
          await _sendTimed(
            ch,
            UploadChunk(id: id, index: index, data: base64Encode(bytes)),
            sendTimeout,
            room: room,
          );
          index++;
          offset += len;
          onProgress?.call(offset, total);
        }
      } finally {
        raf.closeSync();
      }
      shaSink.close();
      final digest = await shaSink.hash();
      final sha256 = digest.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      await _sendTimed(
        ch,
        UploadDone(id: id, sha256: sha256),
        sendTimeout,
        room: room,
      );
      final timer = Timer(ackTimeout, () {
        if (!completer.isCompleted) {
          completer.completeError(
            const UploadError(
              'timeout',
              'The Pi did not confirm the upload — check the connection',
            ),
          );
        }
      });
      try {
        return await completer.future;
      } finally {
        timer.cancel();
      }
    } on UploadError {
      rethrow;
    } catch (e) {
      // File I/O or a frame send can fail in ways the Pi never answers —
      // normalize so callers always see an [UploadError].
      throw UploadError('io_error', 'Could not stream the file: $e');
    } finally {
      await sub.cancel();
    }
  }

  /// [ch.send] with a transport-deadline: a half-dead socket swallows the
  /// frame and never completes the send future, which would otherwise
  /// freeze the upload (and the retry loop) forever. When the deadline
  /// passes the frame is treated as a failed transport (`io_error`). The
  /// original future is drained either way so a late error cannot float
  /// as an unhandled async error.
  ///
  /// [room] addresses this frame at an explicit room (long transfers pin it);
  /// channels without the capability fall back to the plain send.
  static Future<void> _sendTimed(
    IChannel ch,
    ClientMessage m,
    Duration t, {
    String? room,
  }) {
    final c = Completer<void>();
    var settled = false;
    final orig = (room != null && ch is IRoomScopedLink)
        ? (ch as IRoomScopedLink).sendInRoom(room, m)
        : ch.send(m);
    orig.then(
      (_) {
        if (!settled) {
          settled = true;
          c.complete();
        }
      },
      onError: (Object _) {
        if (!settled) {
          settled = true;
          c.completeError(const UploadError('io_error', 'Frame send failed'));
        }
      },
    );
    Timer(t, () {
      if (!settled) {
        settled = true;
        c.completeError(
          const UploadError('io_error', 'Frame send timed out — transport dead'),
        );
      }
    });
    c.future.ignore(); // in case the timer fires before the await attaches
    return c.future;
  }

  /// 12-hex session token — the Pi validates `[A-Za-z0-9_-]{8,64}` and
  /// uses it as the part-file name.
  static String _sessionToken() {
    final rng = Random.secure();
    return List.generate(6, (_) => rng.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
