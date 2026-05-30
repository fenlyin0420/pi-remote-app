import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/home_read_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/ui/home/states/home_state.dart';
import 'package:app/ui/home/viewmodels/home_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

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
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Plan/31 — HomeViewModel now reads the working/idle signal from the DB
/// session index via HomeReadRepository. The boxes are empty in these tests
/// (no session index written), so every room reads `idle` — which is the
/// correct default for the presence/rooms assertions below.
HomeReadRepository _home() => HomeReadRepository(LocalBoxes());

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

class _NoopTransport implements PeerTransport {
  @override
  Future<void> send(Uint8List data) async {}
  @override
  Future<Uint8List> receive() => Completer<Uint8List>().future;
  @override
  Future<void> close() async {}
}

PlainPeerChannel _channel() => PlainPeerChannel(transport: _NoopTransport());

ConnectionManager _conn({_FakeStorage? storage}) {
  return ConnectionManager(
    factory: (_, _) async => _channel(),
    storage: storage ?? _FakeStorage([]),
  );
}

void main() {
  late Directory hiveDir;
  setUpAll(() async {
    hiveDir = Directory.systemTemp.createTempSync('home_vm_hive_');
    await LocalBoxes.initForTest(hiveDir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await hiveDir.delete(recursive: true);
  });

  group('HomeViewModel', () {
    test('initial state is HomeLoading', () {
      final storage = _FakeStorage([_peerA]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _home(),
      );
      expect(vm.state, isA<HomeLoading>());
      vm.dispose();
    });

    test('empty storage → HomeNoPeer', () async {
      final storage = _FakeStorage([]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _home(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<HomeNoPeer>());
      vm.dispose();
    });

    test('two peers → HomeList containing both', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _home(),
      );
      await Future<void>.delayed(Duration.zero);

      final s = vm.state as HomeList;
      expect(s.peers.map((p) => p.remoteEpk), ['epk_A', 'epk_B']);

      vm.dispose();
    });

    test('openSession writes selectedPeerEpk to Preferences', () async {
      final storage = _FakeStorage([_peerA, _peerB]);
      final prefs = Preferences(_FakeSecureStorage());
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _home(),
      );
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
        final vm = HomeViewModel(storage, prefs, conn, _home());
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
      final vm = HomeViewModel(
        storage,
        prefs,
        _conn(storage: storage),
        _home(),
      );
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
        final vm = HomeViewModel(
          storage,
          prefs,
          _conn(storage: storage),
          _home(),
        );
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
  });
}
