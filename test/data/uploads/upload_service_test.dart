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
