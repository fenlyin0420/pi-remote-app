import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStorage extends PairingStorage {
  List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => List.of(peers);

  @override
  Future<void> savePeer(PeerRecord r) async {
    peers = [r, ...peers.where((p) => p.remoteEpk != r.remoteEpk)];
  }

  @override
  Future<void> deletePeer(String epk) async {
    peers = peers.where((p) => p.remoteEpk != epk).toList();
  }

  // Rooms persistence is exercised when a RoomAnnounced lands on a real
  // ConnectionManager (_persistRoomsForPeer). Keep it in-memory so the
  // test never touches flutter_secure_storage (no binding in unit tests).
  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {
    _rooms[epk] = rooms;
  }

  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];

  @override
  Future<void> deleteRooms(String epk) async {
    _rooms.remove(epk);
  }
}

/// Real notification semantics (the real `saveRooms`/`_writePeer` on top of the
/// in-memory secure store), but the peer list comes back in a chosen order —
/// which is what the platform is free to do with the map behind
/// `FlutterSecureStorage.readAll()`.
class _ReorderingStorage extends PairingStorage {
  _ReorderingStorage() : super(_FakeSecureStorage());

  List<PeerRecord>? _order;

  void reorder(List<PeerRecord> peers) => _order = peers;

  @override
  Future<List<PeerRecord>> listPeers() async {
    final all = await super.listPeers();
    final want = _order;
    if (want == null) return all;
    final byEpk = {for (final p in all) p.remoteEpk: p};
    return [
      for (final p in want)
        if (byEpk.containsKey(p.remoteEpk)) byEpk[p.remoteEpk]!,
    ];
  }
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _store.remove(key);
  @override
  Future<Map<String, String>> readAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => Map.from(_store);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _peerA = PeerRecord(
  remoteEpk: 'epk_A',
  sessionName: 'Pi A',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);
const _peerB = PeerRecord(
  remoteEpk: 'epk_B',
  sessionName: 'Pi B',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-02T00:00:00Z',
);
const _peerWithRoom = PeerRecord(
  remoteEpk: 'epk_R',
  sessionName: 'Pi R',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-03T00:00:00Z',
  roomId: 'room-known',
);

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

PlainPeerChannel _channel() => PlainPeerChannel(transport: _NoopTransport());

/// Lets a test inject relay control frames (presence / rooms / working)
/// into a real ConnectionManager.
class _ControllableChannel implements IChannel, IControlLink {
  final _serverCtrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();

  /// Every control frame the app put on the wire, in order.
  final sentControl = <Map<String, dynamic>>[];

  @override
  Stream<ServerMessage> get serverMessages => _serverCtrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  void sendControl(Map<String, dynamic> json) => sentControl.add(json);
  @override
  Future<void> close() async {
    await _serverCtrl.close();
    await _controlCtrl.close();
  }

  void pushControl(ControlInbound m) => _controlCtrl.add(m);
}

ConnectionManager _conn({_FakeStorage? storage}) {
  return ConnectionManager(
    factory: (_, _) async => _channel(),
    storage: storage ?? _FakeStorage([]),
  );
}

void main() {
  group('HomeViewModel', () {
    test(
      'isRoomWorking follows the relay meta.working broadcast for ANY room — '
      'including one that is NOT the connected session, and clears when the '
      'relay says the turn ended (plan/32)',
      () async {
        // Reproduces the smoke-test bugs in sequence:
        //  1) the dot only lit for the active chat (working came from the
        //     connected peer's message channel), and
        //  2) a session that FINISHED while the app was on another chat
        //     stayed blue forever (the DB session index never got idled).
        // Home now reads ONLY ConnectionManager.isRoomWorking — the relay's
        // per-room broadcast — which has no such blind spot.
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, conn);
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Room comes online idle.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isFalse);

        // turn_start → relay broadcasts meta.working=true.
        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'r1',
            working: true,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isTrue);

        // turn_end → meta.working=false → dot goes back off (this is the
        // case that previously stayed blue forever).
        ch.pushControl(
          const RoomMetaUpdated(
            peer: 'epk_A',
            roomId: 'r1',
            working: false,
            hasModel: false,
            hasThinking: false,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(vm.isRoomWorking('epk_A', 'r1'), isFalse);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('initial state is HomeLoading', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
      expect(vm.state, isA<HomeLoading>());
      vm.dispose();
    });

    test('empty storage → HomeNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<HomeNoPeer>());
      vm.dispose();
    });

    test('two peers → HomeList containing both', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as HomeList;
      expect(s.peers.map((p) => p.remoteEpk), ['epk_A', 'epk_B']);

      vm.dispose();
    });

    test('openSession writes selectedPeerEpk to Preferences', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.openSession('epk_B');
      expect(prefs.selectedPeerEpk, 'epk_B');

      vm.dispose();
    });

    test(
      'plano app-state-normalization: openSession ONLY sets prefs '
      '(no switchTo from Home — boot races would otherwise happen)',
      () async {
        final storage = _FakeStorage([_peerA, _peerB]);
        final prefs = Preferences(_FakeSecureStorage());
        final connects = <String>[];
        final conn = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _channel();
          },
          storage: storage,
        );
        final vm = HomeViewModel(storage, prefs, conn);
        await Future<void>.delayed(Duration.zero);

        await vm.openSession('epk_B');
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(prefs.selectedPeerEpk, 'epk_B');
        expect(
          connects,
          isEmpty,
          reason:
              'Home must NOT call the connection factory — chat owns '
              'the switchTo decision',
        );
        expect(conn.activePeer, isNull);

        vm.dispose();
        conn.dispose();
      },
    );

    test('openSession with unknown epk is a no-op', () async {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
      await Future<void>.delayed(Duration.zero);

      await vm.openSession('epk_unknown');
      expect(prefs.selectedPeerEpk, isNull);

      vm.dispose();
    });

    test(
      'openSession with roomId persists the composite epk:room AND '
      'awaits before returning — caller can rely on Preferences being '
      'updated before navigating to /chat (race-condition regression)',
      () async {
        final storage = _FakeStorage([_peerA]);
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
        await Future<void>.delayed(Duration.zero);

        // Seed prefs with a DIFFERENT room (simulating the previous
        // chat the user was looking at).
        await prefs.setSelectedRoom(epk: 'epk_A', roomId: 'room-previous');
        expect(prefs.selectedRoomId, 'room-previous');

        // Now tap a new room → openSession completes, prefs reflect it.
        await vm.openSession('epk_A', roomId: 'room-target');

        // After awaiting openSession, prefs ARE updated. If
        // ChatViewModel.bootstrap reads prefs at this point, it sees
        // the correct room.
        expect(prefs.selectedPeerEpk, 'epk_A');
        expect(prefs.selectedRoomId, 'room-target');

        vm.dispose();
      },
    );

    test(
      'openSession without a roomId never downgrades the live room to the '
      'implicit main — the relay drops frames addressed to a room the Pi is '
      'not registered under, with no error on either end',
      () async {
        final storage = _FakeStorage([_peerA, _peerB]);
        final prefs = Preferences(_FakeSecureStorage());
        final conn = _conn(storage: storage);
        final vm = HomeViewModel(storage, prefs, conn);
        await Future<void>.delayed(Duration.zero);

        // The live connection is bound to a real room (learned from
        // room_announced, or a session the user opened earlier).
        conn.switchRoom('V1pGb2Tqp6U1');

        // A payload with no room: an older notification tap, or a peer
        // record that was never room-bound.
        await vm.openSession('epk_A');

        expect(
          conn.activeRoomId,
          'V1pGb2Tqp6U1',
          reason: 'an unknown room must not rebind the live connection',
        );
        expect(prefs.selectedPeerEpk, 'epk_A');
        expect(
          prefs.selectedRoomId,
          isNull,
          reason: 'no room in the payload means no room to persist — binding '
              'one implicitly (main) is what silently kills the session',
        );

        vm.dispose();
        conn.dispose();
      },
    );

    test(
      'openSession without a roomId keeps the room already stored on the peer',
      () async {
        final storage = _FakeStorage([_peerWithRoom]);
        final prefs = Preferences(_FakeSecureStorage());
        final conn = _conn(storage: storage);
        final vm = HomeViewModel(storage, prefs, conn);
        await Future<void>.delayed(Duration.zero);

        await vm.openSession('epk_R');

        expect(conn.activeRoomId, 'room-known');
        expect(prefs.selectedRoomId, 'room-known');

        vm.dispose();
        conn.dispose();
      },
    );
  });

  group('HomeViewModel — presence filter (plan-38 Fase 3)', () {
    test('counts / visibleItems split rooms by liveness; setFilter re-derives '
        'without reloading', () async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // r1 stays live; r2 is announced then ended → cached but offline
      // (grey tile — still in _roomsByPeer, dropped from _liveRoomIds).
      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
      );
      ch.pushControl(
        const RoomAnnounced(peer: 'epk_A', roomId: 'r2', startedAt: 2),
      );
      ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r2', sinceTs: 3));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Sanity — one live, one cached/offline.
      expect(vm.isRoomLive('epk_A', 'r1'), isTrue);
      expect(vm.isRoomLive('epk_A', 'r2'), isFalse);

      // Counts are independent of the selected tab.
      expect(vm.counts, (all: 2, online: 1, offline: 1));

      // Default tab is Online → only the live room is visible.
      expect((vm.state as HomeList).filter, HomeFilter.online);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r1']);

      // Offline → only the cached room.
      vm.setFilter(HomeFilter.offline);
      expect((vm.state as HomeList).filter, HomeFilter.offline);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r2']);

      // All → both (sorted), and the counts are unchanged.
      vm.setFilter(HomeFilter.all);
      expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r1', 'r2']);
      expect(vm.counts, (all: 2, online: 1, offline: 1));

      vm.dispose();
      await conn.disconnect();
      conn.dispose();
    });

    test(
      'setFilter is a no-op when the tab is unchanged, and emits exactly once '
      'when it changes',
      () async {
        final storage = _FakeStorage([_peerA]);
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, _conn(storage: storage));
        await Future<void>.delayed(Duration.zero);

        expect((vm.state as HomeList).filter, HomeFilter.online);
        var notifies = 0;
        vm.addListener(() => notifies++);

        vm.setFilter(HomeFilter.online); // same tab → no emit
        expect(notifies, 0);

        vm.setFilter(HomeFilter.offline); // changed → one emit
        expect(notifies, 1);
        expect((vm.state as HomeList).filter, HomeFilter.offline);

        vm.dispose();
      },
    );

    test(
      'storage notifications (delete/rename/meta refresh → saveRooms) do NOT '
      'reset the selected tab back to Online — regression: after deleting a '
      'room, or during an active conversation, the All/Offline tab snapped '
      'back to Online because _load() emitted a fresh HomeList with the '
      'default filter',
      () async {
        final ch = _ControllableChannel();
        final storage = _FakeStorage([_peerA]);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // One live room + one cached/offline room, like after a RoomEnded.
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r1', startedAt: 1),
        );
        ch.pushControl(
          const RoomAnnounced(peer: 'epk_A', roomId: 'r2', startedAt: 2),
        );
        ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'r2', sinceTs: 3));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        vm.setFilter(HomeFilter.offline);
        expect((vm.state as HomeList).filter, HomeFilter.offline);

        // Any PairingStorage write (saveRooms on delete/rename, savePeer on
        // open) reaches HomeViewModel via notifyListeners → _load(). The
        // user's tab choice must survive the reload.
        storage.notifyListeners();
        await Future<void>.delayed(Duration.zero);
        expect((vm.state as HomeList).filter, HomeFilter.offline);
        expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r2']);

        // A second notification on the All tab must not reset either.
        vm.setFilter(HomeFilter.all);
        storage.notifyListeners();
        await Future<void>.delayed(Duration.zero);
        expect((vm.state as HomeList).filter, HomeFilter.all);
        expect(vm.visibleItems.map((i) => i.room.roomId).toList(), ['r1', 'r2']);

        vm.dispose();
        await conn.disconnect();
        conn.dispose();
      },
    );

    test('counts / visibleItems are empty-safe outside a HomeList', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, _conn(storage: storage));

      // Synchronously still HomeLoading — the getters must not throw.
      expect(vm.state, isA<HomeLoading>());
      expect(vm.counts, (all: 0, online: 0, offline: 0));
      expect(vm.visibleItems, isEmpty);

      vm.dispose();
    });
  });

  group('HomeViewModel — frame routing (rideRoomFor)', () {
    Future<(HomeViewModel, _ControllableChannel)> boot() async {
      final ch = _ControllableChannel();
      final storage = _FakeStorage([_peerA]);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final vm = HomeViewModel(storage, Preferences(_FakeSecureStorage()), conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return (vm, ch);
    }

    test('a fork rides the acted-on tile, not the first live room', () async {
      final (vm, ch) = await boot();
      // The stale session's room is announced FIRST, so the old
      // "first live room" heuristic picked it; the fork must not.
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'stale',
          name: 'Jarvis#2',
          cwd: '/home/u/Jarvis',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'fenlyin',
          name: 'fenlyin',
          cwd: '/home/u',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(vm.firstLiveRoom('epk_A'), 'stale'); // the old, wrong answer
      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          sourceRoomId: 'fenlyin',
          fallback: vm.firstLiveRoom('epk_A')!,
        ),
        'fenlyin',
      );
      vm.dispose();
    });

    test('a typed path prefers the live room that owns that directory',
        () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'stale',
          name: 'Jarvis#2',
          cwd: '/home/u/Jarvis',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'fenlyin',
          name: 'fenlyin',
          cwd: '/home/u',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          fallback: vm.firstLiveRoom('epk_A')!,
        ),
        'fenlyin',
      );
      // No room owns the path and the user's active room is live →
      // priority 3 (the active room), which here equals the first live.
      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u/nowhere',
          fallback: vm.firstLiveRoom('epk_A')!,
        ),
        'stale',
      );
      vm.dispose();
    });

    test('an offline source room is ignored (a live room is used)', () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'gone',
          name: 'gone',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'gone', sinceTs: 2));
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'alive',
          name: 'alive',
          cwd: '/home/u/other',
          startedAt: 3,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(vm.isRoomLive('epk_A', 'gone'), isFalse);
      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          sourceRoomId: 'gone',
          fallback: 'alive',
        ),
        'alive',
      );
      vm.dispose();
    });

    test('a delete never rides the room being deleted', () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'victim',
          name: 'fenlyin#3',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'daemon',
          name: 'fenlyin',
          cwd: '/home/u',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // The sibling that owns the same directory carries the frame, never
      // the room being deleted (its own process is stopped by the delete).
      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          excludeRoomId: 'victim',
          fallback: 'victim',
        ),
        'daemon',
      );
      vm.dispose();

      // A lone room still rides the fallback: no sibling exists, so the
      // self-ride is accepted — the Pi acks a self-delete before the kill.
      final (lone, loneCh) = await boot();
      loneCh.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'victim',
          name: 'fenlyin#3',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(
        lone.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          excludeRoomId: 'victim',
          fallback: 'victim',
        ),
        'victim',
      );
      lone.dispose();
    });

    test('the excluded fallback yields to any other live room', () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'victim',
          name: 'fenlyin#3',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'jarvis',
          name: 'Jarvis',
          cwd: '/home/u/Jarvis',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Victim is first → it is the fallback (firstLiveRoom) and the
      // adopted active room, but a live room in another directory must
      // beat the self-ride.
      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          excludeRoomId: 'victim',
          fallback: vm.firstLiveRoom('epk_A')!,
        ),
        'jarvis',
      );
      vm.dispose();
    });

    test('an offline victim falls through to a live same-cwd sibling',
        () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'victim',
          name: 'fenlyin#3',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'daemon',
          name: 'fenlyin',
          cwd: '/home/u',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      ch.pushControl(const RoomEnded(peer: 'epk_A', roomId: 'victim', sinceTs: 3));
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          excludeRoomId: 'victim',
          fallback: 'daemon',
        ),
        'daemon',
      );
      vm.dispose();
    });

    test('source == exclude is ignored (the exclusion wins)', () async {
      final (vm, ch) = await boot();
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'victim',
          name: 'fenlyin#3',
          cwd: '/home/u',
          startedAt: 1,
        ),
      );
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_A',
          roomId: 'daemon',
          name: 'fenlyin',
          cwd: '/home/u',
          startedAt: 2,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        vm.rideRoomFor(
          epk: 'epk_A',
          path: '/home/u',
          sourceRoomId: 'victim',
          excludeRoomId: 'victim',
          fallback: 'daemon',
        ),
        'daemon',
      );
      vm.dispose();
    });
  });

  // The subscription is a network round trip, and the relay answers it with a
  // full rooms snapshot. Storage notifies on every room change, so subscribing
  // from a storage notification closed a loop that measured 1220 rounds in 6 s
  // on a real phone (~105 KB/s up, ~375 KB/s down). These two cases pin the
  // rule: the peer SET decides, nothing else.
  group('HomeViewModel — subscription is tied to the peer set', () {
    test('a storage notification that only changes rooms does not re-subscribe',
        () async {
      final ch = _ControllableChannel();
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(_peerA);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final before = ch.sentControl.length;
      expect(before, greaterThan(0),
          reason: 'the first load must subscribe');

      // Exactly what `ConnectionManager._persistRoomsForPeer` does while an
      // agent streams: the rooms view is rewritten and announced.
      await storage.saveRooms(_peerA.remoteEpk, const [
        PersistedRoom(roomId: 'r1', startedAt: 1),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(ch.sentControl.length, before,
          reason: 'a rooms-only notification carries no new peer');
      vm.dispose();
    });

    test('a new peer does re-subscribe', () async {
      final ch = _ControllableChannel();
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(_peerA);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final before = ch.sentControl.length;

      await storage.savePeer(_peerB);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(ch.sentControl.length, greaterThan(before));
      expect(
        ch.sentControl
            .where((m) => m['type'] == 'subscribe_presence')
            .last['peers'],
        containsAll(<String>[_peerA.remoteEpk, _peerB.remoteEpk]),
      );
      vm.dispose();
    });

    test('a re-pair after the last peer was revoked subscribes again', () async {
      final ch = _ControllableChannel();
      final storage = PairingStorage(_FakeSecureStorage());
      await storage.savePeer(_peerA);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Settings → revoke the only peer: the relay subscription goes empty.
      await storage.deletePeerSilent(_peerA.remoteEpk);
      conn.subscribeToPeers(const []);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(conn.subscribedEpks, isEmpty);
      ch.sentControl.clear();

      // The same Pi paired again, in the same app run: same epk, newer
      // `pairedAt`. Nothing replays a subscription in this path
      // (`adopt` only replays what is stored, and the stored set is empty),
      // so Home has to notice that the relay is not subscribed any more.
      await storage.savePeer(
        PeerRecord(
          remoteEpk: _peerA.remoteEpk,
          sessionName: _peerA.sessionName,
          relayUrl: _peerA.relayUrl,
          pairedAt: '2026-02-01T00:00:00Z',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        ch.sentControl.where((m) => m['type'] == 'subscribe_rooms'),
        isNotEmpty,
        reason: 'without this the Pi never appears on Home until a cold start',
      );
      vm.dispose();
    });

    test(
      'a rooms snapshot the relay repeats is not persisted or re-requested — '
      'the per-token loop that cost ~500 KB/s on the wire',
      () async {
        final ch = _ControllableChannel();
        final storage = PairingStorage(_FakeSecureStorage());
        await storage.savePeer(_peerA);
        final conn = ConnectionManager(
          factory: (_, _) async => ch,
          storage: storage,
          emitDebounce: Duration.zero,
        );
        final prefs = Preferences(_FakeSecureStorage());
        final vm = HomeViewModel(storage, prefs, conn);
        await conn.connectTo(_peerA);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ch.sentControl.clear();
        var notifications = 0;
        storage.addListener(() => notifications++);

        // A fresh parse each time, because that is what the wire delivers. This
        // case pins the two guards that keep a repeated snapshot from walking
        // the app side (no second write, no second `rooms_check`); the value
        // comparison that decides "is this the same rooms state" is pinned at
        // the ConnectionManager level and in rooms_protocol_test.
        RoomInfo room() => RoomInfo.fromJson({
          'room_id': 'r1',
          'name': 'work',
          'cwd': '/w',
          'started_at': 1,
          'model': 'm',
          'thinking': 'auto',
          'working': true,
          'context': {'used': 1200, 'limit': 1000000},
        });

        ch.pushControl(RoomsSnapshot(peer: _peerA.remoteEpk, rooms: [room()]));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final afterFirst = ch.sentControl.length;
        final notifsAfterFirst = notifications;

        ch.pushControl(RoomsSnapshot(peer: _peerA.remoteEpk, rooms: [room()]));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(notifications, notifsAfterFirst,
            reason: 'identical state must not be written again');
        expect(ch.sentControl.length, afterFirst,
            reason: 'and must not be answered with another rooms_check');
        vm.dispose();
      },
    );

    test('a reordered peer list is not a new set of peers', () async {
      final ch = _ControllableChannel();
      final storage = _ReorderingStorage();
      await storage.savePeer(_peerA);
      await storage.savePeer(_peerB);
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(storage, prefs, conn);
      await conn.connectTo(_peerA);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final before = ch.sentControl.length;
      expect(before, greaterThan(0));

      // Same two peers, other order — plus a real notification to make sure the
      // comparison actually runs.
      storage.reorder([_peerB, _peerA]);
      await storage.saveRooms(_peerA.remoteEpk, const [
        PersistedRoom(roomId: 'r1', startedAt: 1),
      ]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(ch.sentControl.length, before,
          reason: 'a reshuffled list is the same subscription');
      vm.dispose();
    });
  });
}
