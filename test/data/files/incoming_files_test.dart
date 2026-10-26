// The receive half of the chunked Pi → App transfer: bytes land in a part file,
// and only become the card's blob once the size and the whole-file sha256 match
// what the Pi declared. Everything else (a gap, a mismatch, an abort) must leave
// NO blob behind — a card showing half a file is worse than a card with none.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/attachments/attachment_store.dart';
import 'package:app/data/files/incoming_files.dart';
import 'package:cryptography/dart.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory _dir;
late AttachmentStore _store;
late IncomingFiles _files;

Future<String> _sha256(List<int> bytes) async {
  final digest = await const DartSha256().hash(bytes);
  return digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  setUp(() {
    _dir = Directory.systemTemp.createTempSync('rp_incoming_');
    _store = AttachmentStore(Directory('${_dir.path}/attachments'));
    _files = IncomingFiles(_store);
  });

  tearDown(() async {
    await _files.abortAll();
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  });

  test('assembles the chunks and publishes them under the card blob name', () async {
    final bytes = Uint8List.fromList([for (var i = 0; i < 300; i++) i % 256]);
    final sha = await _sha256(bytes);
    await _files.begin(id: 'att_tc-1', size: bytes.length);

    expect(await _files.append(id: 'att_tc-1', index: 0, data: base64Encode(bytes.sublist(0, 100))), 100);
    expect(await _files.append(id: 'att_tc-1', index: 1, data: base64Encode(bytes.sublist(100))), 300);
    expect(_files.isReceiving('att_tc-1'), isTrue);

    final blob = await _files.finish(id: 'att_tc-1', sha256: sha);
    expect(blob, AttachmentStore.blobName('att_tc-1'));
    expect(await _store.get(blob), equals(bytes));
    expect(_files.isReceiving('att_tc-1'), isFalse);
    // The part file is gone: only the blob remains.
    final leftovers = Directory('${_store.root.path}/.incoming')
        .listSync()
        .whereType<File>()
        .toList();
    expect(leftovers, isEmpty);
  });

  test('a hash mismatch publishes nothing', () async {
    final bytes = utf8.encode('hello world');
    await _files.begin(id: 'att_tc-2', size: bytes.length);
    await _files.append(id: 'att_tc-2', index: 0, data: base64Encode(bytes));

    await expectLater(
      _files.finish(id: 'att_tc-2', sha256: 'deadbeef'),
      throwsA(
        isA<IncomingFileError>().having((e) => e.code, 'code', 'hash_mismatch'),
      ),
    );
    expect(await _store.get(AttachmentStore.blobName('att_tc-2')), isNull);
    expect(_files.isReceiving('att_tc-2'), isFalse);
  });

  test('a chunk out of order is refused and drops the part', () async {
    await _files.begin(id: 'att_tc-3', size: 8);
    await expectLater(
      _files.append(id: 'att_tc-3', index: 1, data: base64Encode([1, 2, 3, 4])),
      throwsA(
        isA<IncomingFileError>().having((e) => e.code, 'code', 'invalid_message'),
      ),
    );
    await _files.abort('att_tc-3');
    expect(await _store.get(AttachmentStore.blobName('att_tc-3')), isNull);
  });

  test('more bytes than declared are refused instead of growing the file', () async {
    await _files.begin(id: 'att_tc-4', size: 4);
    await expectLater(
      _files.append(id: 'att_tc-4', index: 0, data: base64Encode([1, 2, 3, 4, 5])),
      throwsA(isA<IncomingFileError>()),
    );
  });

  test('a chunk above the frame ceiling is refused', () async {
    await _files.begin(id: 'att_tc-5', size: IncomingFiles.maxChunkBytes + 10);
    await expectLater(
      _files.append(
        id: 'att_tc-5',
        index: 0,
        data: base64Encode(Uint8List(IncomingFiles.maxChunkBytes + 1)),
      ),
      throwsA(
        isA<IncomingFileError>().having((e) => e.code, 'code', 'invalid_message'),
      ),
    );
  });

  test('an unfinished transfer cannot be published', () async {
    await _files.begin(id: 'att_tc-6', size: 8);
    await _files.append(id: 'att_tc-6', index: 0, data: base64Encode([1, 2, 3]));
    await expectLater(
      _files.finish(id: 'att_tc-6', sha256: 'x'),
      throwsA(
        isA<IncomingFileError>().having((e) => e.code, 'code', 'incomplete'),
      ),
    );
  });

  test('offers are refused before any byte: bad id, empty, over the ceiling', () async {
    await expectLater(
      _files.begin(id: '../etc/passwd', size: 10),
      throwsA(isA<IncomingFileError>()),
    );
    await expectLater(
      _files.begin(id: 'att_ok', size: 0),
      throwsA(isA<IncomingFileError>()),
    );
    await expectLater(
      _files.begin(id: 'att_big', size: IncomingFiles.maxBytes + 1),
      throwsA(
        isA<IncomingFileError>().having((e) => e.code, 'code', 'too_large'),
      ),
    );
  });

  test('a second offer for the same card is refused while the first runs', () async {
    await _files.begin(id: 'att_tc-7', size: 4);
    await expectLater(
      _files.begin(id: 'att_tc-7', size: 4),
      throwsA(isA<IncomingFileError>().having((e) => e.code, 'code', 'busy')),
    );
  });

  test('abort removes the part and forgets the transfer', () async {
    await _files.begin(id: 'att_tc-8', size: 100);
    await _files.append(id: 'att_tc-8', index: 0, data: base64Encode([1, 2, 3]));
    await _files.abort('att_tc-8');
    expect(_files.isReceiving('att_tc-8'), isFalse);
    expect(
      Directory('${_store.root.path}/.incoming').listSync().whereType<File>(),
      isEmpty,
    );
  });
}
