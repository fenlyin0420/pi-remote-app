// Plan/62 — per-room durable attachment reference (AttachmentStore over the
// durable `attachments` box).

import 'dart:io';

import 'package:app/data/local/attachment_store.dart';
import 'package:app/data/local/boxes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('rp_v2_attachments_');
  });

  tearDown(() async {
    await Hive.close();
    await dir.delete(recursive: true);
  });

  AttachmentStore makeStore() => AttachmentStore(LocalBoxes());

  group('AttachmentStore', () {
    test('read of a fresh room returns null', () async {
      await LocalBoxes.initForTest(dir.path);
      expect(makeStore().read('epk1', 'main'), isNull);
    });

    test('save then read round-trips name, size and paths', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const AttachmentRecord(
          name: 'deck.pdf',
          size: 1234,
          phonePath: '/tmp/a.pdf',
          landedPath: '/uploads/main/deck.pdf',
        ),
      );
      final record = store.read('epk1', 'main')!;
      expect(record.name, 'deck.pdf');
      expect(record.size, 1234);
      expect(record.phonePath, '/tmp/a.pdf');
      expect(record.landedPath, '/uploads/main/deck.pdf');
      expect(record.landed, isTrue);
    });

    test('an unfinished record round-trips with a null landed path', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
      );
      final record = store.read('epk1', 'main')!;
      expect(record.landed, isFalse);
      expect(record.landedPath, isNull);
    });

    test('clear deletes the record; a second clear is a no-op', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
      );
      await store.clear('epk1', 'main');
      expect(store.read('epk1', 'main'), isNull);
      await store.clear('epk1', 'main');
      expect(store.read('epk1', 'main'), isNull);
    });

    test('a corrupt record reads as null (no phantom attachment)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
      );
      await LocalBoxes().attachmentsBox().put('epk1:main', 'garbage-not-json');
      expect(store.read('epk1', 'main'), isNull);
    });

    test('records are keyed per room (no bleed across rooms)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'roomA',
        const AttachmentRecord(name: 'a.pdf', size: 1, phonePath: '/a'),
      );
      expect(store.read('epk1', 'roomB'), isNull);
      expect(store.read('epk2', 'roomA'), isNull);
      expect(store.read('epk1', 'roomA')!.name, 'a.pdf');
    });
  });

  group('AttachmentRecord.fromJson', () {
    test('missing required fields decode as null', () {
      expect(
        AttachmentRecord.fromJson('{"name":"a.pdf"}'),
        isNull,
        reason: 'size and phonePath are required',
      );
      expect(AttachmentRecord.fromJson('garbage'), isNull);
      expect(AttachmentRecord.fromJson('{"name":3,"size":"x","phone":1}'), isNull);
    });
  });
}
