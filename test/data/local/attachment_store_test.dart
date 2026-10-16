// Plan/62+63 — per-room durable attachment TRAY (AttachmentStore over the
// durable `attachments` box): a list of binary references per room, with
// back-compat for the Plan/62 single-record shape.

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
    test('read of a fresh room returns an empty tray', () async {
      await LocalBoxes.initForTest(dir.path);
      expect(makeStore().read('epk1', 'main'), isEmpty);
    });

    test('save then read round-trips a multi-record tray', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 1234,
            phonePath: '/tmp/a.pdf',
            landedPath: '/uploads/main/deck.pdf',
          ),
          AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
        ],
      );
      final records = store.read('epk1', 'main');
      expect(records, hasLength(2));
      expect(records[0].name, 'deck.pdf');
      expect(records[0].size, 1234);
      expect(records[0].phonePath, '/tmp/a.pdf');
      expect(records[0].landedPath, '/uploads/main/deck.pdf');
      expect(records[0].landed, isTrue);
      expect(records[1].name, 'x.zip');
      expect(records[1].landed, isFalse);
      expect(records[1].landedPath, isNull);
    });

    test('an unfinished record round-trips with a null landed path', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const [
          AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
        ],
      );
      final record = store.read('epk1', 'main').single;
      expect(record.landed, isFalse);
      expect(record.landedPath, isNull);
    });

    test('clear deletes the tray; a second clear is a no-op', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const [
          AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
        ],
      );
      await store.clear('epk1', 'main');
      expect(store.read('epk1', 'main'), isEmpty);
      await store.clear('epk1', 'main');
      expect(store.read('epk1', 'main'), isEmpty);
    });

    test('saving an empty list clears the tray', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const [
          AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
        ],
      );
      await store.save('epk1', 'main', const []);
      expect(store.read('epk1', 'main'), isEmpty);
    });

    test('a corrupt tray reads as empty (no phantom attachments)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'main',
        const [
          AttachmentRecord(name: 'x.zip', size: 5, phonePath: '/tmp/x.zip'),
        ],
      );
      await LocalBoxes().attachmentsBox().put('epk1:main', 'garbage-not-json');
      expect(store.read('epk1', 'main'), isEmpty);
    });

    test('a corrupt member of a list is dropped, its siblings survive',
        () async {
      await LocalBoxes.initForTest(dir.path);
      await LocalBoxes().attachmentsBox().put(
        'epk1:main',
        '[{"name":"ok.pdf","size":1,"phone":"/a"},{"name":"broken"},'
        '{"name":"ok2.pdf","size":2,"phone":"/b"}]',
      );
      final records = makeStore().read('epk1', 'main');
      expect(records.map((r) => r.name).toList(), ['ok.pdf', 'ok2.pdf']);
    });

    test('a Plan/62 single-record row reads as a one-record tray', () async {
      await LocalBoxes.initForTest(dir.path);
      await LocalBoxes().attachmentsBox().put(
        'epk1:main',
        '{"name":"legacy.pdf","size":9,"phone":"/legacy.pdf",'
        '"landed":"/uploads/main/legacy.pdf"}',
      );
      final records = makeStore().read('epk1', 'main');
      expect(records, hasLength(1));
      expect(records.single.name, 'legacy.pdf');
      expect(records.single.landed, isTrue);
    });

    test('records are keyed per room (no bleed across rooms)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epk1',
        'roomA',
        const [
          AttachmentRecord(name: 'a.pdf', size: 1, phonePath: '/a'),
        ],
      );
      expect(store.read('epk1', 'roomB'), isEmpty);
      expect(store.read('epk2', 'roomA'), isEmpty);
      expect(store.read('epk1', 'roomA').single.name, 'a.pdf');
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
