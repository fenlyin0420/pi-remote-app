// Plan/31 — record roundtrips + volatile runtime wipe on boot.

import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/local/records/session_index_record.dart';
import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

void main() {
  group('record roundtrips', () {
    test('MessageRecord (user + images + file) survives toJson/fromJson', () {
      final r = MessageRecord(
        id: 'u1',
        seq: 3,
        role: MsgRole.user,
        text: 'hello',
        images: const [
          MessageImage(data: 'QUJD', mime: 'image/jpeg'),
          MessageImage(data: 'REVG', mime: 'image/png'),
        ],
        files: const [MessageFile(name: 'deck.pdf', path: '/u/deck.pdf')],
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
        pending: true,
        steering: true,
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.id, 'u1');
      expect(back.seq, 3);
      expect(back.role, MsgRole.user);
      expect(back.text, 'hello');
      expect(back.images, hasLength(2));
      expect(back.images[0].data, 'QUJD');
      expect(back.images[1].data, 'REVG');
      expect(back.files, hasLength(1));
      expect(back.files.single.name, 'deck.pdf');
      expect(back.files.single.path, '/u/deck.pdf');
      expect(back.pending, isTrue);
      expect(back.steering, isTrue);
      // Projects to the domain UserMsg the UI renders.
      final msg = back.toChatMessage() as UserMsg;
      expect(msg.status, UserMsgStatus.pending);
      expect(msg.steering, isTrue);
      expect(msg.images, hasLength(2));
      expect(msg.files, hasLength(1));
    });

    test('MessageRecord (user) with no attachments roundtrips empty lists', () {
      final r = MessageRecord(
        id: 'u2',
        seq: 4,
        role: MsgRole.user,
        text: 'hi',
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.images, isEmpty);
      expect(back.files, isEmpty);
    });

    test('a Plan/62-era row (singular image/file keys) reads as a list', () {
      final json = MessageRecord(
        id: 'u3',
        seq: 5,
        role: MsgRole.user,
        text: 'legacy',
        images: const [MessageImage(data: 'QUJD', mime: 'image/jpeg')],
        files: const [MessageFile(name: 'deck.pdf', path: '/u/deck.pdf')],
        ts: DateTime.fromMillisecondsSinceEpoch(1700),
      ).toJson();
      // Rewrite the row in the legacy singular-key shape.
      json['image'] = {'data': 'QUJD', 'mime': 'image/jpeg'};
      json.remove('images');
      json['file'] = {'name': 'deck.pdf', 'path': '/u/deck.pdf'};
      json.remove('files');
      final back = MessageRecord.fromJson(json);
      expect(back.images, hasLength(1));
      expect(back.images.single.data, 'QUJD');
      expect(back.files, hasLength(1));
      expect(back.files.single.name, 'deck.pdf');
      expect(back.files.single.path, '/u/deck.pdf');
    });

    test('an archived picture roundtrips as {blob, mime, w, h}', () {
      // The row a build with the sent-picture archive writes: no bytes, just
      // the archive name and the header size the bubble reserves its box from.
      final r = MessageRecord(
        id: 'u4',
        seq: 6,
        role: MsgRole.user,
        text: 'look',
        images: const [
          MessageImage(
            mime: 'image/png',
            blob: 'img_abc.bin',
            width: 200,
            height: 150,
          ),
        ],
      );
      final json = r.toJson();
      final entry = (json['images'] as List).single as Map;
      expect(entry.containsKey('data'), isFalse, reason: 'bytes are not in the row');

      final back = MessageRecord.fromJson(json);
      final image = back.images.single;
      expect(image.blob, 'img_abc.bin');
      expect(image.archived, isTrue);
      expect(image.data, isEmpty);
      expect(image.mime, 'image/png');
      expect(image.width, 200);
      expect(image.height, 150);
    });

    test('an image entry with no byte source is dropped, not rendered blank', () {
      final json = MessageRecord(
        id: 'u5',
        seq: 7,
        role: MsgRole.user,
        text: 'look',
        images: const [MessageImage(data: 'QUJD', mime: 'image/jpeg')],
      ).toJson();
      json['images'] = [
        {'mime': 'image/jpeg'},
        {'data': 'QUJD', 'mime': 'image/jpeg'},
      ];
      final back = MessageRecord.fromJson(json);
      expect(back.images, hasLength(1));
      expect(back.images.single.data, 'QUJD');
    });

    test('MessageRecord (tool) survives roundtrip', () {
      final r = MessageRecord(
        id: 'tc1',
        seq: 0,
        role: MsgRole.tool,
        ts: DateTime.fromMillisecondsSinceEpoch(1),
        tool: const ToolEventData(
          toolCallId: 'tc1',
          tool: 'Bash',
          args: {'cmd': 'ls'},
          status: ToolEventStatus.completed,
          result: {'exit': 0},
          diff: '- 1 old\n+ 1 new',
        ),
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.tool?.tool, 'Bash');
      expect(back.tool?.status, ToolEventStatus.completed);
      final evt = back.toChatMessage() as ToolEvent;
      expect(evt.toolCallId, 'tc1');
      expect(evt.status, ToolEventStatus.completed);
      expect(
        evt.diff,
        '- 1 old\n+ 1 new',
        reason: 'a reopened chat shows the same diff the live card did',
      );
    });

    // LOCAL (fenlyin): the per-row caption — model + timestamp survive the
    // box roundtrip and project onto the domain message.
    test('MessageRecord (assistant + model) survives roundtrip', () {
      final r = MessageRecord(
        id: 'a1',
        seq: 1,
        role: MsgRole.assistant,
        text: 'the answer',
        ts: DateTime.utc(2026, 10, 13, 14, 5, 12),
        model: 'Qwen3.8-27B',
      );
      final back = MessageRecord.fromJson(r.toJson());
      expect(back.model, 'Qwen3.8-27B');
      // The box stores epoch millis (a UTC instant comes back as a local
      // DateTime for the same instant — compare the instant, not the flag).
      expect(back.ts?.millisecondsSinceEpoch, r.ts?.millisecondsSinceEpoch);
      final msg = back.toChatMessage() as AssistantMsg;
      expect(msg.model, 'Qwen3.8-27B');
      expect(msg.ts?.millisecondsSinceEpoch, r.ts?.millisecondsSinceEpoch);
    });

    test('SessionIndexRecord survives roundtrip', () {
      final r = SessionIndexRecord(
        epk: 'epk1',
        roomId: 'main',
        displayName: 'proj',
        status: SessionActivity.working,
        lastMessageAt: DateTime.fromMillisecondsSinceEpoch(99),
        lastMessagePreview: 'hi',
        sessionStartedAt: DateTime.fromMillisecondsSinceEpoch(10),
        syncCursor: '100:aaaa',
        syncedRows: 7,
      );
      final back = SessionIndexRecord.fromJson(r.toJson());
      expect(back, r);
      expect(back.status, SessionActivity.working);
      expect(back.syncCursor, '100:aaaa');
      expect(back.syncedRows, 7);
    });

    test('RuntimeRecord survives roundtrip', () {
      const r = RuntimeRecord(
        connection: RuntimeConnection.online,
        presence: RuntimePresence.alive,
      );
      final back = RuntimeRecord.fromJson(r.toJson());
      expect(back, r);
    });
  });

  group('volatile runtime wipe (#3)', () {
    late Directory dir;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('rp_v2_wipe_');
    });
    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    test('runtime box opens EMPTY after a simulated restart', () async {
      await LocalBoxes.initForTest(dir.path);
      final boxes = LocalBoxes();
      // Seed runtime as if a prior run left an "online" record.
      await boxes.runtimeBox().put(
        'epk1:main',
        const RuntimeRecord(connection: RuntimeConnection.online).toJson(),
      );
      expect(boxes.runtimeBox().isEmpty, isFalse);

      // "Restart": re-init wipes the volatile box.
      await LocalBoxes.initForTest(dir.path);
      expect(
        boxes.runtimeBox().isEmpty,
        isTrue,
        reason: 'runtime must never survive a boot (#3)',
      );
    });
  });
}
