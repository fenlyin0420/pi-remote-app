// SessionHistoryStore — per-peer cache CRUD.

import 'dart:io';

import 'package:app/data/repositories/session_history_store.dart';
import 'package:app/domain/session_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

late Directory _hiveDir;
int _epkCounter = 0;
String _newEpk() => 'epk_store_${++_epkCounter}';

void main() {
  setUpAll(() {
    _hiveDir = Directory.systemTemp.createTempSync('hive_store_test_');
    Hive.init(_hiveDir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    await _hiveDir.delete(recursive: true);
  });

  group('SessionHistoryStore', () {
    test('loadFor with no cache returns empty', () async {
      final store = SessionHistoryStore();
      final s = await store.loadFor(_newEpk());
      expect(s.messages, isEmpty);
      expect(s.lastTs, isNull);
      expect(s.sessionStartedAt, isNull);
    });

    test('appendEvents + loadFor round-trips messages and meta', () async {
      final store = SessionHistoryStore();
      final epk = _newEpk();

      await store.appendEvents(
        epk,
        const [
          UserMsg(id: 'u1', text: 'hello'),
          AssistantMsg(id: 'u1', text: 'world'),
        ],
        lastTs: 1716000000000,
      );

      final loaded = await store.loadFor(epk);
      expect(loaded.messages, hasLength(2));
      expect(loaded.messages[0], isA<UserMsg>());
      expect((loaded.messages[0] as UserMsg).text, 'hello');
      expect(loaded.messages[1], isA<AssistantMsg>());
      expect((loaded.messages[1] as AssistantMsg).text, 'world');
      expect(loaded.lastTs, 1716000000000);
    });

    test('appendEvents preserves a previously-set sessionStartedAt',
        () async {
      final store = SessionHistoryStore();
      final epk = _newEpk();

      await store.replaceFor(
        epk,
        const [UserMsg(id: 'u1', text: 'a')],
        sessionStartedAt: 12345,
        lastTs: 100,
      );
      await store.appendEvents(
        epk,
        const [AssistantMsg(id: 'u1', text: 'b')],
        lastTs: 200,
      );

      final loaded = await store.loadFor(epk);
      expect(loaded.sessionStartedAt, 12345);
      expect(loaded.lastTs, 200);
      expect(loaded.messages.map((m) => (m as dynamic).text), ['a', 'b']);
    });

    test('replaceFor overwrites the entire cache and sessionStartedAt',
        () async {
      final store = SessionHistoryStore();
      final epk = _newEpk();

      await store.appendEvents(
        epk,
        const [UserMsg(id: 'old', text: 'old')],
        lastTs: 100,
      );

      await store.replaceFor(
        epk,
        const [
          UserMsg(id: 'new1', text: 'fresh'),
          ToolEvent(
            id: 'tc1',
            toolCallId: 'tc1',
            tool: 'bash',
            args: {'command': 'ls'},
            status: ToolEventStatus.completed,
          ),
        ],
        sessionStartedAt: 999,
        lastTs: 500,
      );

      final loaded = await store.loadFor(epk);
      expect(loaded.messages, hasLength(2));
      expect((loaded.messages[0] as UserMsg).text, 'fresh');
      expect(loaded.messages[1], isA<ToolEvent>());
      expect((loaded.messages[1] as ToolEvent).status,
          ToolEventStatus.completed);
      expect(loaded.sessionStartedAt, 999);
      expect(loaded.lastTs, 500);
    });

    test('clearFor empties the cache', () async {
      final store = SessionHistoryStore();
      final epk = _newEpk();

      await store.appendEvents(
        epk,
        const [UserMsg(id: 'u1', text: 'x')],
        lastTs: 1,
      );
      await store.clearFor(epk);

      final loaded = await store.loadFor(epk);
      expect(loaded.messages, isEmpty);
      expect(loaded.lastTs, isNull);
    });

    test('ToolEvent fields survive a round-trip', () async {
      final store = SessionHistoryStore();
      final epk = _newEpk();

      const tool = ToolEvent(
        id: 'tc1',
        toolCallId: 'tc1',
        tool: 'bash',
        args: {'command': 'echo hi'},
        status: ToolEventStatus.completed,
        result: {'stdout': 'hi'},
      );
      await store.appendEvents(epk, [tool], lastTs: 1);

      final loaded = await store.loadFor(epk);
      final restored = loaded.messages.single as ToolEvent;
      expect(restored.tool, 'bash');
      expect(restored.toolCallId, 'tc1');
      expect(restored.status, ToolEventStatus.completed);
      expect((restored.result as Map)['stdout'], 'hi');
    });
  });
}
