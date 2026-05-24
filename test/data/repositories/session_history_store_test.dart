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

  group('SessionHistoryStore — plan 17 partitioned by (peer, room)', () {
    test(
      'different roomIds for the same peer keep independent caches',
      () async {
        final store = SessionHistoryStore();
        final epk = _newEpk();
        await store.replaceFor(
          epk,
          const [UserMsg(id: 'u_a', text: 'in room A')],
          roomId: 'roomA',
          sessionStartedAt: 100,
          lastTs: 110,
        );
        await store.replaceFor(
          epk,
          const [UserMsg(id: 'u_b', text: 'in room B')],
          roomId: 'roomB',
          sessionStartedAt: 200,
          lastTs: 210,
        );

        final a = await store.loadFor(epk, roomId: 'roomA');
        final b = await store.loadFor(epk, roomId: 'roomB');

        expect(a.messages.single.id, 'u_a');
        expect((a.messages.single as UserMsg).text, 'in room A');
        expect(a.sessionStartedAt, 100);
        expect(b.messages.single.id, 'u_b');
        expect((b.messages.single as UserMsg).text, 'in room B');
        expect(b.sessionStartedAt, 200);
      },
    );

    test(
      'loadFor with default roomId="main" migrates from legacy '
      'session_<epk> box on first call',
      () async {
        final epk = _newEpk();
        // Hand-prime the LEGACY box (pre-plan-17 layout).
        final legacyBox = await Hive.openBox<dynamic>('session_$epk');
        await legacyBox.put('data', {
          'schema_version': 1,
          'session_started_at': 1000,
          'last_ts': 1100,
          'messages': [
            {'kind': 'user', 'id': 'u_legacy', 'text': 'pre-rooms data'},
          ],
        });

        final store = SessionHistoryStore();
        final loaded = await store.loadFor(epk);

        // Migrated to the new key without losing data.
        expect(loaded.messages, hasLength(1));
        expect((loaded.messages.single as UserMsg).text, 'pre-rooms data');

        // Subsequent reads come from the new partitioned box.
        final loaded2 = await store.loadFor(epk);
        expect(loaded2.messages, hasLength(1));

        // Asking for a DIFFERENT room is still empty — the migration
        // only seeded 'main'.
        final other = await store.loadFor(epk, roomId: 'other');
        expect(other.messages, isEmpty);
      },
    );

    test(
      'clearFor("main") wipes both the new partition AND the legacy '
      'box so stale data does not resurrect',
      () async {
        final epk = _newEpk();
        final legacyBox = await Hive.openBox<dynamic>('session_$epk');
        await legacyBox.put('data', {
          'schema_version': 1,
          'session_started_at': 1,
          'last_ts': 1,
          'messages': [
            {'kind': 'user', 'id': 'u', 'text': 'legacy'},
          ],
        });

        final store = SessionHistoryStore();
        // Touch loadFor to migrate.
        await store.loadFor(epk);
        await store.clearFor(epk);

        // Re-load → empty.
        final reloaded = await store.loadFor(epk);
        expect(reloaded.messages, isEmpty);
        // Legacy box also empty (so a later loadFor won't resurrect it).
        final reloadedLegacy = await Hive.openBox<dynamic>('session_$epk');
        expect(reloadedLegacy.get('data'), isNull);
      },
    );

    test(
      'appendEvents respects roomId — events only land in the named '
      'partition',
      () async {
        final store = SessionHistoryStore();
        final epk = _newEpk();
        await store.appendEvents(
          epk,
          const [UserMsg(id: 'u1', text: 'hello')],
          roomId: 'work',
          lastTs: 50,
        );
        await store.appendEvents(
          epk,
          const [UserMsg(id: 'u2', text: 'other')],
          roomId: 'play',
          lastTs: 60,
        );

        final work = await store.loadFor(epk, roomId: 'work');
        final play = await store.loadFor(epk, roomId: 'play');
        expect(work.messages, hasLength(1));
        expect(play.messages, hasLength(1));
        expect((work.messages.single as UserMsg).text, 'hello');
        expect((play.messages.single as UserMsg).text, 'other');
      },
    );

    test(
      'standard-base64 epk with "/" + "=" does not blow up the file '
      'path (regression: PathNotFoundException on iOS after mesh '
      'normalisation made remoteEpk standard-base64 instead of url-safe)',
      () async {
        // This epk has both `/` and `=` — the two characters that break
        // path-based Hive box names. Pre-fix this threw inside `loadFor`
        // and aborted `_bootstrap` → `requestSync` never ran → empty
        // history forever.
        const epk =
            'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
        final store = SessionHistoryStore();
        await store.replaceFor(
          epk,
          const [UserMsg(id: 'u1', text: 'hi from standard-b64 epk')],
          roomId: 'main',
          sessionStartedAt: 1,
          lastTs: 10,
        );
        final loaded = await store.loadFor(epk, roomId: 'main');
        expect(loaded.messages, hasLength(1));
        expect((loaded.messages.single as UserMsg).text,
            'hi from standard-b64 epk');
      },
    );
  });
}
