// Plan/62 — UploadService: chunk framing, hashing, acks and failure modes,
// against a fake IChannel.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';



import 'package:app/data/transport/channel.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeChannel implements IChannel {
  final sent = <ClientMessage>[];
  final _inbound = StreamController<ServerMessage>.broadcast();

  @override
  Stream<ServerMessage> get serverMessages => _inbound.stream;

  void push(ServerMessage m) => _inbound.add(m);

  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);

  @override
  Future<void> close() async {}
}

/// A fake that reports the room-pinning capability, recording the room each
/// frame was addressed to. `rooms` holds one entry per frame, in send order
/// ('' = a frame that went out on the unpinned/plain path).
class _RoomScopedChannel extends _FakeChannel implements IRoomScopedLink {
  final rooms = <String>[];

  @override
  Future<void> send(ClientMessage msg) async {
    rooms.add('');
    return super.send(msg);
  }

  @override
  Future<void> sendInRoom(String room, ClientMessage msg) async {
    rooms.add(room);
    return super.send(msg);
  }
}

Future<String> _expectedSha(List<int> bytes) async {
  final sink = const DartSha256().newHashSink();
  sink.add(bytes);
  sink.close();
  final h = await sink.hash();
  return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rp62_upload_');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  Future<File> mkFile(List<int> bytes) async {
    final f = File('${tmp.path}/blob.bin')..writeAsBytesSync(bytes);
    return f;
  }

  test('a 3 MiB file streams as two chunks + done with the right sha256', () async {
    final ch = _FakeChannel();
    final bytes = List<int>.generate(3 * 1024 * 1024, (i) => i & 0xff);
    final f = await mkFile(bytes);

    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'blob.bin');

    // Ack after the final frame.
    Future<void> ack() async {
      await Future<void>.delayed(Duration.zero);
      final done = ch.sent.whereType<UploadDone>().single;
      ch.push(UploadComplete(
        inReplyTo: done.id,
        id: done.id,
        name: 'blob.bin',
        path: '/uploads/room/blob.bin',
      ));
    }
    // Ack once the done frame has been sent.
    while (ch.sent.whereType<UploadDone>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    await ack();

    final uploaded = await fut;
    expect(uploaded.path, '/uploads/room/blob.bin');

    final start = ch.sent.whereType<UploadStart>().single;
    expect(start.name, 'blob.bin');
    expect(start.size, 3 * 1024 * 1024);

    final chunks = ch.sent.whereType<UploadChunk>().toList();
    expect(chunks, hasLength(2)); // 2 MiB + 1 MiB
    final joined = chunks
        .map((c) => base64Decode(c.data).length)
        .reduce((a, b) => a + b);
    expect(joined, 3 * 1024 * 1024);
    // Indices sequential and the reassembled bytes match the source.
    expect(chunks.map((c) => c.index).toList(), [0, 1]);
    final reassembled =
        Uint8List.fromList([for (final c in chunks) ...base64Decode(c.data)]);
    expect(reassembled, bytes);
    // The base64 payload of each chunk stays under the 4 MiB `ct` ceiling.
    for (final c in chunks) {
      expect(c.data.length, lessThan(4 * 1024 * 1024));
    }

    final done = ch.sent.whereType<UploadDone>().single;
    expect(done.id, start.id);
    expect(done.sha256, await _expectedSha(bytes));
  });

  test('progress callbacks report cumulative bytes per chunk', () async {
    final ch = _FakeChannel();
    final bytes = List<int>.filled(3 * 1024 * 1024, 7);
    final f = await mkFile(bytes);

    final progress = <int>[];
    final fut = UploadService.streamUpload(
      ch: ch,
      path: f.path,
      name: 'blob.bin',
      onProgress: (sent, total) => progress.add(sent),
    );
    fut.ignore();
    while (ch.sent.whereType<UploadDone>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final done = ch.sent.whereType<UploadDone>().single;
    ch.push(
      UploadComplete(
        inReplyTo: done.id,
        id: done.id,
        name: 'blob.bin',
        path: '/uploads/room/blob.bin',
      ),
    );
    await fut;

    expect(progress, [2 * 1024 * 1024, 3 * 1024 * 1024]);
  });

  test('an empty file is refused before any frame', () async {
    final ch = _FakeChannel();
    final f = await mkFile(const []);
    await expectLater(
      UploadService.streamUpload(ch: ch, path: f.path, name: 'empty.bin'),
      throwsA(
        isA<UploadError>()
            .having((e) => e.code, 'code', 'empty')
            .having((e) => e.message, 'message', contains('empty')),
      ),
    );
    expect(ch.sent, isEmpty);
  });

  test('an error frame addressed to the session rejects the upload', () async {
    final ch = _FakeChannel();
    final f = await mkFile(List<int>.filled(4096, 1));

    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'x.bin');
    // Attach the expectation before the error frame lands, so the future is
    // always guarded.
    final expectation = expectLater(
      fut,
      throwsA(
        isA<UploadError>().having((e) => e.code, 'code', 'upload_hash_mismatch'),
      ),
    );
    while (ch.sent.whereType<UploadStart>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final start = ch.sent.whereType<UploadStart>().single;
    ch.push(
      ErrorMessage(
        inReplyTo: start.id,
        code: 'upload_hash_mismatch',
        message: 'the sha256 did not match',
      ),
    );
    await expectation;
  });

  test('an error for a different session id is ignored', () async {
    final ch = _FakeChannel();
    final f = await mkFile(List<int>.filled(4096, 1));

    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'x.bin');
    fut.ignore();
    while (ch.sent.whereType<UploadStart>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    // A foreign error frame must not kill our session.
    ch.push(
      ErrorMessage(inReplyTo: 'ffff-foreign', code: 'invalid_message', message: 'x'),
    );
    final start = ch.sent.whereType<UploadStart>().single;
    ch.push(
      UploadComplete(
        inReplyTo: start.id,
        id: start.id,
        name: 'x.bin',
        path: '/uploads/room/x.bin',
      ),
    );
    final uploaded = await fut;
    expect(uploaded.path, '/uploads/room/x.bin');
  });

  test('shouldCancel=true abandons between chunks', () async {
    final ch = _FakeChannel();
    final bytes = List<int>.filled(3 * 1024 * 1024, 9);
    final f = await mkFile(bytes);

    var polls = 0;
    final fut = UploadService.streamUpload(
      ch: ch,
      path: f.path,
      name: 'big.bin',
      shouldCancel: () => ++polls > 1, // abort before the second chunk
    );
    await expectLater(
      fut,
      throwsA(isA<UploadError>().having((e) => e.code, 'code', 'cancelled')),
    );
    expect(ch.sent.whereType<UploadChunk>(), hasLength(1));
    expect(ch.sent.whereType<UploadDone>(), isEmpty);
  });

  test('the done frame carries the known-answer sha256 of the bytes sent',
      () async {
    final ch = _FakeChannel();
    final f = await mkFile(utf8.encode('abc').toList());

    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'abc.bin');
    while (ch.sent.whereType<UploadDone>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final done = ch.sent.whereType<UploadDone>().single;
    ch.push(
      UploadComplete(
        inReplyTo: done.id,
        id: done.id,
        name: 'abc.bin',
        path: '/u/abc.bin',
      ),
    );
    await fut;
    // SHA-256("abc") — a fixed vector (cross-checked against GNU
    // sha256sum, openssl, CPython and Node), independent of the test sink.
    expect(
      done.sha256,
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );
  });

  test('a frame-send failure surfaces as an io_error UploadError', () async {
    final ch = _BrokenChannel();
    final f = await mkFile(List<int>.filled(64, 1));
    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'x.bin');
    await expectLater(
      fut,
      throwsA(isA<UploadError>().having((e) => e.code, 'code', 'io_error')),
    );
  });

  test('an error frame mid-stream stops the chunk loop before done', () async {
    final ch = _GatedChannel();
    // 6 MiB → 3 chunks: after the gated second chunk lands, the loop is
    // still mid-stream when the rejection is released.
    final f = await mkFile(List<int>.filled(6 * 1024 * 1024, 7));
    final fut = UploadService.streamUpload(ch: ch, path: f.path, name: 'm.bin');
    final expectation = expectLater(
      fut,
      throwsA(
        isA<UploadError>().having((e) => e.code, 'code', 'upload_rejected'),
      ),
    );

    while (ch.sent.whereType<UploadChunk>().isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    // Block the second chunk's send, reject the session, then release.
    final gate = Completer<void>();
    ch.gate = gate;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final start = ch.sent.whereType<UploadStart>().single;
    ch.push(
      ErrorMessage(inReplyTo: start.id, code: 'upload_rejected', message: 'busy'),
    );
    ch.gate = null;
    gate.complete();
    await expectation;
    expect(ch.sent.whereType<UploadDone>(), isEmpty);
    expect(ch.sent.whereType<UploadChunk>().length, lessThanOrEqualTo(2));
  });

  group('transport drop mid-stream — the retry loop', () {
    test('restarts the upload on the new channel and completes', () async {
      final bytes = List<int>.filled(5 * 1024 * 1024, 7); // 3 chunks
      final f = await mkFile(bytes);
      // Start + two chunks flow; the third chunk's send holds on the gate
      // until the test has swapped the provider to the fresh channel, then
      // the dead channel throws.
      final chA = _GatedDyingChannel(gateAtIndex: 2, failAfterSends: 3);
      final chB = _FakeChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(path: f.path, name: 'big.bin');
      await _until(() => chA.sent.whereType<UploadChunk>().length >= 2);
      current = chB; // the transport reconnected
      chA.gate.complete(); // now the dead channel's send fails

      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().last;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'big.bin',
          path: '/uploads/room/big.bin',
        ),
      );

      final uploaded = await fut;
      expect(uploaded.path, '/uploads/room/big.bin');
      // The restart re-streams the whole file as a fresh session on B.
      expect(chB.sent.whereType<UploadStart>().length, 1);
      expect(chB.sent.whereType<UploadChunk>().length, 3);
      expect(chB.sent.whereType<UploadDone>().length, 1);
    });

    test('waits out a dead window before the restart lands', () async {
      final f = await mkFile(List<int>.filled(300000, 3)); // 1 chunk
      final chA = _GatedDyingChannel(gateAtIndex: -1, failAfterSends: 0);
      final chB = _FakeChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(path: f.path, name: 'small.bin');
      // The start frame holds on the gate while the provider moves through
      // the reconnect window; then the dead channel's send fails.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      current = null; // transport enters its reconnect window
      await Future<void>.delayed(const Duration(milliseconds: 100));
      chA.gate.complete(); // the dead channel's start send now fails; the
      // restart finds no channel and waits in _waitChannel
      await Future<void>.delayed(const Duration(milliseconds: 100));
      current = chB; // the transport reconnects

      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().single;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'small.bin',
          path: '/uploads/room/small.bin',
        ),
      );
      expect((await fut).path, '/uploads/room/small.bin');
    });

    test('gives up with a timeout error when the channel never comes back',
        () async {
      final f = await mkFile(List<int>.filled(300000, 3));
      // The start frame holds on the gate; while it is held, the provider
      // moves into the reconnect window (null) and never recovers.
      final chA = _GatedDyingChannel(gateAtIndex: -1, failAfterSends: 0);
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);
      final fut = svc.upload(
        path: f.path,
        name: 's.bin',
        reconnectTimeout: const Duration(milliseconds: 400),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      current = null;
      chA.gate.complete(); // the first attempt now fails
      await expectLater(
        fut,
        throwsA(
          isA<UploadError>().having((e) => e.code, 'code', 'timeout'),
        ),
      );
    });

    test('waits past ackTimeout for the queued bytes to reach the Pi', () async {
      // The frames are queued in the socket when the last one is written, and
      // the Pi answers only after every byte arrived: on a slow uplink a
      // multi-MiB upload needs far longer than the base ack window. The wait is
      // extended by the flush estimate, so an answer inside that allowance is
      // still accepted instead of failing a transfer that is merely slow.
      final bytes = List<int>.filled(uploadChunkBytes * 2 + 100, 9); // 3 chunks
      final f = await mkFile(bytes);
      final ch = _FakeChannel();
      final fut = UploadService.streamUpload(
        ch: ch,
        path: f.path,
        name: 'flush.bin',
        ackTimeout: const Duration(milliseconds: 50),
      );
      await _until(() => ch.sent.whereType<UploadDone>().isNotEmpty);
      // Well past the bare ackTimeout, far inside the flush allowance
      // (~40 s for this total at the documented throughput floor).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final done = ch.sent.whereType<UploadDone>().single;
      ch.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'flush.bin',
          path: '/uploads/room/flush.bin',
        ),
      );

      expect((await fut).path, '/uploads/room/flush.bin');
      expect(ch.sent.whereType<UploadChunk>().length, 3);
    });

    test('a Pi rejection is never retried', () async {
      final f = await mkFile(List<int>.filled(300000, 3));
      final ch = _GatedChannel();
      final svc = UploadService.withChannelProvider(() => ch);
      final fut = svc.upload(path: f.path, name: 'rej.bin');
      await _until(() => ch.sent.whereType<UploadStart>().isNotEmpty);
      ch.push(
        ErrorMessage(
          inReplyTo: ch.sent.whereType<UploadStart>().single.id,
          code: 'upload_rejected',
          message: 'busy',
        ),
      );
      await expectLater(
        fut,
        throwsA(
          isA<UploadError>().having((e) => e.code, 'code', 'upload_rejected'),
        ),
      );
      expect(ch.sent.whereType<UploadStart>().length, 1, reason: 'one attempt only');
    });

    test('a half-dead socket (a send that never returns) trips the send '
        'timeout and the retry lands on the fresh channel', () async {
      final bytes = List<int>.filled(5 * 1024 * 1024, 7); // 3 chunks
      final f = await mkFile(bytes);
      // Start + chunk 0 flush; chunk 1 is swallowed by the dead socket and
      // the send future never completes — the only way out is the send
      // timeout feeding the retry loop.
      final chA = _HungChannel(hungAtIndex: 1);
      final chB = _FakeChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(
        path: f.path,
        name: 'big.bin',
        sendTimeout: const Duration(milliseconds: 200),
      );
      await _until(() => chA.sent.whereType<UploadChunk>().isNotEmpty);
      current = chB; // the transport reconnected while the send hung

      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().last;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'big.bin',
          path: '/uploads/room/big.bin',
        ),
      );

      final uploaded = await fut;
      expect(uploaded.path, '/uploads/room/big.bin');
      expect(chB.sent.whereType<UploadStart>().length, 1);
      expect(chB.sent.whereType<UploadChunk>().length, 3);
    });

    test('a lost ack (the done frame landed, the answer went out over a '
        'dead link) retries the whole upload and completes', () async {
      final f = await mkFile(List<int>.filled(300000, 3)); // 1 chunk
      final chA = _FakeChannel(); // receives everything but never answers
      final chB = _FakeChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(
        path: f.path,
        name: 's.bin',
        ackTimeout: const Duration(milliseconds: 200),
      );
      await _until(() => chA.sent.whereType<UploadDone>().isNotEmpty);
      current = chB; // the Pi's answer crossed the drop; the restart re-uploads
      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().single;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 's.bin',
          path: '/uploads/room/s.bin',
        ),
      );

      final uploaded = await fut;
      expect(uploaded.path, '/uploads/room/s.bin');
      expect(chA.sent.whereType<UploadDone>().length, 1, reason: 'first attempt sent its done frame');
      expect(chB.sent.whereType<UploadChunk>().length, 1);
    });

    test('a lost session (start frame swallowed by a dead socket) retries '
        'and completes', () async {
      // The relay-side socket to the Pi half-died: the start frame was
      // swallowed, the chunk arrived at a Pi that never saw the start, so
      // the Pi answers `upload_session_lost`. The app must treat that as
      // transient and restart on the fresh channel.
      final f = await mkFile(List<int>.filled(300000, 3)); // 1 chunk
      final chA = _FakeChannel(); // start + chunk land, session was lost
      final chB = _FakeChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(path: f.path, name: 'lost.bin');
      await _until(() => chA.sent.whereType<UploadChunk>().isNotEmpty);
      final start = chA.sent.whereType<UploadStart>().single;
      chA.push(
        ErrorMessage(
          inReplyTo: start.id,
          code: 'upload_session_lost',
          message: 'upload_chunk: unknown session',
        ),
      );
      current = chB; // the Pi is back on a fresh connection

      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().single;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'lost.bin',
          path: '/uploads/room/lost.bin',
        ),
      );

      final uploaded = await fut;
      expect(uploaded.path, '/uploads/room/lost.bin');
      expect(chB.sent.whereType<UploadStart>().length, 1, reason: 'restart re-streams the whole file as a fresh session');
      expect(chB.sent.whereType<UploadChunk>().length, 1);
    });
  });

  group('room pinning — a mid-transfer room switch cannot reroute frames', () {
    test('every frame carries the pinned room, not the live one', () async {
      final f = await mkFile(List<int>.filled(300000, 3)); // 1 chunk
      final ch = _RoomScopedChannel();
      final fut = UploadService.streamUpload(
        ch: ch,
        path: f.path,
        name: 'pinned.bin',
        room: 'V1pGb2Tqp6U1',
      );
      await _until(() => ch.sent.whereType<UploadDone>().isNotEmpty);
      final done = ch.sent.whereType<UploadDone>().single;
      ch.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'pinned.bin',
          path: '/uploads/V1pGb2Tqp6U1/pinned.bin',
        ),
      );
      final uploaded = await fut;
      expect(uploaded.path, '/uploads/V1pGb2Tqp6U1/pinned.bin');
      expect(
        ch.sent.map((m) => m.runtimeType.toString()).toList(),
        ['UploadStart', 'UploadChunk', 'UploadDone'],
      );
      expect(ch.rooms, ['V1pGb2Tqp6U1', 'V1pGb2Tqp6U1', 'V1pGb2Tqp6U1']);
    });

    test('no room keeps the plain send path', () async {
      final f = await mkFile(List<int>.filled(300000, 3));
      final ch = _RoomScopedChannel();
      final fut = UploadService.streamUpload(
        ch: ch,
        path: f.path,
        name: 'plain.bin',
      );
      await _until(() => ch.sent.whereType<UploadDone>().isNotEmpty);
      final done = ch.sent.whereType<UploadDone>().single;
      ch.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'plain.bin',
          path: '/x/plain.bin',
        ),
      );
      await fut;
      expect(ch.rooms, ['', '', '']);
    });

    test('a retry re-pins the room on the fresh channel too', () async {
      final f = await mkFile(List<int>.filled(300000, 3)); // 1 chunk
      final chA = _RoomScopedChannel();
      final chB = _RoomScopedChannel();
      IChannel? current = chA;
      final svc = UploadService.withChannelProvider(() => current);

      final fut = svc.upload(
        path: f.path,
        name: 'retry.bin',
        room: 'DJvMhbgzRlv6',
      );
      await _until(() => chA.sent.whereType<UploadChunk>().isNotEmpty);
      final start = chA.sent.whereType<UploadStart>().single;
      chA.push(
        ErrorMessage(
          inReplyTo: start.id,
          code: 'upload_session_lost',
          message: 'upload_chunk: unknown session',
        ),
      );
      current = chB;
      await _until(() => chB.sent.whereType<UploadDone>().isNotEmpty);
      final done = chB.sent.whereType<UploadDone>().single;
      chB.push(
        UploadComplete(
          inReplyTo: done.id,
          id: done.id,
          name: 'retry.bin',
          path: '/uploads/DJvMhbgzRlv6/retry.bin',
        ),
      );

      final uploaded = await fut;
      expect(uploaded.path, '/uploads/DJvMhbgzRlv6/retry.bin');
      expect(chA.rooms.toSet(), {'DJvMhbgzRlv6'});
      expect(chB.rooms.toSet(), {'DJvMhbgzRlv6'});
    });
  });
}

/// Polls [cond] on a short timer until true or [timeout] elapses.
Future<void> _until(bool Function() cond, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) fail('condition not met in time');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Records sends until [failAfterSends], then throws — simulates the
/// transport dying mid-stream.
class _DyingChannel implements IChannel {
  _DyingChannel({required this.failAfterSends});

  final int failAfterSends;
  final sent = <ClientMessage>[];
  int _sends = 0;

  int get attempts => _sends;

  @override
  Stream<ServerMessage> get serverMessages => const Stream<ServerMessage>.empty();

  @override
  Future<void> send(ClientMessage msg) async {
    _sends++;
    if (_sends > failAfterSends) {
      throw const SocketException('transport dropped');
    }
    sent.add(msg);
  }

  @override
  Future<void> close() async {}
}

/// A [_DyingChannel] whose send at chunk index [gateAtIndex] first holds on
/// [gate] — so tests can swap the provider to a fresh channel while the dead
/// one is still mid-send, keeping the retry deterministic.
class _GatedDyingChannel extends _DyingChannel {
  _GatedDyingChannel({required super.failAfterSends, required this.gateAtIndex});

  /// [gateAtIndex] < 0 gates the start frame as well (every send holds on
  /// [gate]); >= 0 gates only chunks from that index on.
  final int gateAtIndex;
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> send(ClientMessage msg) async {
    if ((msg is UploadStart && gateAtIndex < 0) ||
        (msg is UploadChunk && msg.index >= gateAtIndex)) {
      await gate.future;
    }
    return super.send(msg);
  }
}

/// Records sends until [hungAtIndex], where it returns a future that never
/// completes — a half-dead socket whose send queue swallows frames without
/// ever flushing.
class _HungChannel implements IChannel {
  _HungChannel({required this.hungAtIndex});

  final int hungAtIndex;
  final sent = <ClientMessage>[];

  @override
  Stream<ServerMessage> get serverMessages => const Stream<ServerMessage>.empty();

  @override
  Future<void> send(ClientMessage msg) {
    if (msg is UploadChunk && msg.index >= hungAtIndex) {
      return Completer<void>().future; // never completes
    }
    sent.add(msg);
    return Future<void>.value();
  }

  @override
  Future<void> close() async {}
}

class _BrokenChannel implements IChannel {
  @override
  Stream<ServerMessage> get serverMessages => const Stream<ServerMessage>.empty();

  @override
  Future<void> send(ClientMessage msg) async => throw Exception('transport down');

  @override
  Future<void> close() async {}
}

class _GatedChannel extends _FakeChannel {
  Completer<void>? gate;

  @override
  Future<void> send(ClientMessage msg) async {
    if (msg is UploadChunk && gate != null) {
      await gate!.future;
    }
    return super.send(msg);
  }
}
