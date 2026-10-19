// Tests for the new room-related control frames (plan 17).

import 'dart:convert';

import 'package:app/protocol/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The app decides "this snapshot is identical to what I hold, skip it" by
  // comparing parsed rooms. That comparison is only as good as `RoomInfo.==`,
  // so a field without value equality silently turns every re-parsed snapshot
  // into a change — and a change is persisted, which notifies listeners that
  // re-request the snapshot. See `ConnectionManager.subscribeToPeers`.
  group('RoomInfo value equality', () {
    Map<String, dynamic> frame() => {
      'type': 'rooms',
      'peer': 'epk_A',
      'rooms': [
        {
          'room_id': 'r1',
          'name': 'work',
          'cwd': '/w',
          'started_at': 1700000000000,
          'model': 'gpt-x',
          'thinking': 'auto',
          'working': true,
          'context': {'used': 1200, 'limit': 1000000},
        },
      ],
    };

    test('the same frame parsed twice compares equal', () {
      final first = ControlInbound.tryFromJson(frame())! as RoomsSnapshot;
      final second =
          ControlInbound.tryFromJson(jsonDecode(jsonEncode(frame())))
              as RoomsSnapshot;

      expect(first.rooms, hasLength(1));
      expect(second.rooms.first, first.rooms.first);
      expect(second.rooms.first == first.rooms.first, isTrue);
      // Both halves of the contract: a Map/Set lookup of a re-parsed room has
      // to find the one already held, which needs matching hashCodes too.
      expect(second.rooms.first.hashCode, first.rooms.first.hashCode);
      expect(
        second.rooms.first.context.hashCode,
        first.rooms.first.context.hashCode,
      );
    });

    test('equality still tells context usage apart', () {
      final first = ControlInbound.tryFromJson(frame())! as RoomsSnapshot;
      final changed = first.rooms.first.copyWith(
        context: const RoomContextUsage(used: 1201, limit: 1000000),
      );

      expect(changed == first.rooms.first, isFalse);
    });

    test('context usage round-trips through toJson', () {
      final parsed = ControlInbound.tryFromJson(frame())! as RoomsSnapshot;
      final again = RoomInfo.fromJson(
        jsonDecode(jsonEncode(parsed.rooms.first.toJson()))
            as Map<String, dynamic>,
      );

      expect(again, parsed.rooms.first);
      expect(again.context, const RoomContextUsage(used: 1200, limit: 1000000));
    });
  });

  group('ControlInbound — rooms (plan 17)', () {
    test('room_announced parses with name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'name': 'work',
        'cwd': '/Users/jacob/projects/app',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.peer, 'epk_A');
      expect(r.roomId, 'room-uuid-1');
      expect(r.name, 'work');
      expect(r.cwd, '/Users/jacob/projects/app');
      expect(r.startedAt, 1700000000000);
    });

    test('room_announced tolerates missing name + cwd', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_announced',
        'peer': 'epk_A',
        'room_id': 'main',
        'started_at': 1700000000000,
      });
      expect(c, isA<RoomAnnounced>());
      final r = c! as RoomAnnounced;
      expect(r.name, isNull);
      expect(r.cwd, isNull);
    });

    test('room_ended parses', () {
      final c = ControlInbound.tryFromJson({
        'type': 'room_ended',
        'peer': 'epk_A',
        'room_id': 'room-uuid-1',
        'since_ts': 1700000010000,
      });
      expect(c, isA<RoomEnded>());
      final r = c! as RoomEnded;
      expect(r.roomId, 'room-uuid-1');
      expect(r.sinceTs, 1700000010000);
    });

    test('rooms snapshot parses with nested RoomInfo list', () {
      final c = ControlInbound.tryFromJson({
        'type': 'rooms',
        'peer': 'epk_A',
        'rooms': [
          {
            'room_id': 'r1',
            'name': 'one',
            'cwd': '/one',
            'started_at': 1000,
          },
          {
            'room_id': 'r2',
            'started_at': 2000,
          },
        ],
      });
      expect(c, isA<RoomsSnapshot>());
      final r = c! as RoomsSnapshot;
      expect(r.peer, 'epk_A');
      expect(r.rooms, hasLength(2));
      expect(r.rooms[0].roomId, 'r1');
      expect(r.rooms[0].cwd, '/one');
      expect(r.rooms[1].name, isNull);
      expect(r.rooms[1].cwd, isNull);
    });

    test(
      'room_announced parses optional `model` (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_announced',
          'peer': 'epk_A',
          'room_id': 'r1',
          'started_at': 1700000000000,
          'model': 'claude-sonnet-4.5',
        });
        expect(c, isA<RoomAnnounced>());
        expect((c! as RoomAnnounced).model, 'claude-sonnet-4.5');
      },
    );

    test(
      'room_meta_updated parses with model (plan 18)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
          'meta': {'model': 'gpt-4o'},
        });
        expect(c, isA<RoomMetaUpdated>());
        final r = c! as RoomMetaUpdated;
        expect(r.peer, 'epk_A');
        expect(r.roomId, 'r1');
        expect(r.model, 'gpt-4o');
      },
    );

    test(
      'room_meta_updated tolerates missing meta / model (clears value)',
      () {
        final c = ControlInbound.tryFromJson({
          'type': 'room_meta_updated',
          'peer': 'epk_A',
          'room_id': 'r1',
        });
        expect(c, isA<RoomMetaUpdated>());
        expect((c! as RoomMetaUpdated).model, isNull);
      },
    );

    test('RoomInfo serializes + parses model round-trip', () {
      const r = RoomInfo(
        roomId: 'r1',
        startedAt: 100,
        name: 'work',
        cwd: '/x',
        model: 'claude-sonnet-4.5',
      );
      final back = RoomInfo.fromJson(r.toJson());
      expect(back, r);
      expect(back.model, 'claude-sonnet-4.5');
    });

    test('outbound subscribe_rooms helper has correct shape', () {
      expect(subscribeRoomsFrame(['a', 'b']), {
        'type': 'subscribe_rooms',
        'peers': ['a', 'b'],
      });
      expect(unsubscribeRoomsFrame(['a']), {
        'type': 'unsubscribe_rooms',
        'peers': ['a'],
      });
      expect(roomsCheckFrame(['a']), {
        'type': 'rooms_check',
        'peers': ['a'],
      });
    });
  });
}
