// The phone's archive of the pictures the user sent.
//
// The contract worth pinning: the blob name IS the content hash, so a picture
// sent twice — or replayed by every `session_history` re-sync — is one file, and
// two different pictures never share one.

import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/local/sent_image_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late SentImageStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rp_sent_images_');
    // `forBox` takes the msgs box path and puts the archive beside it.
    store = SentImageStore.forBox('${dir.path}/msgs_x__room.hive');
  });

  tearDown(() => dir.delete(recursive: true));

  Uint8List bytes(List<int> values) => Uint8List.fromList(values);

  Directory blobs() => Directory('${dir.path}/${SentImageStore.dirName}');

  test('what goes in comes back out, by content name', () async {
    final name = await store.put(bytes([1, 2, 3, 4]));
    expect(name, isNotNull);
    expect(name, endsWith('.bin'));
    expect(await store.get(name!), bytes([1, 2, 3, 4]));
  });

  test('the same picture again is the same file, not a second copy', () async {
    final first = await store.put(bytes([9, 8, 7]));
    final second = await store.put(bytes([9, 8, 7]));
    expect(second, first);
    expect(blobs().listSync(), hasLength(1));
  });

  test('different pictures get different names', () async {
    final a = await store.put(bytes([1]));
    final b = await store.put(bytes([2]));
    expect(a, isNot(b));
    expect(blobs().listSync(), hasLength(2));
  });

  test('a blob this phone does not have reads as null', () async {
    expect(await store.get('img_nope.bin'), isNull);
  });

  test('the name is derived from the content, never from a message', () {
    // Two calls with equal bytes agree; a one-byte change does not. This is
    // what makes a replay (which re-sends the same bytes) cost no writes.
    expect(
      SentImageStore.blobName(bytes([1, 2, 3])),
      SentImageStore.blobName(bytes([1, 2, 3])),
    );
    expect(
      SentImageStore.blobName(bytes([1, 2, 3])),
      isNot(SentImageStore.blobName(bytes([1, 2, 4]))),
    );
  });
}
