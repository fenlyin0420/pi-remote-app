// retargetSession — the single place that turns "open this (peer, room)"
// into persisted state + a live connection retarget. Shared by the Home tap
// and the notification tap, so a banner must resolve exactly like a tap.

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/session/session_targeting.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => store[key];

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
      store.remove(key);
    } else {
      store[key] = value;
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
  }) async => store.remove(key);

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  final List<PeerRecord> saved = [];
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<void> savePeer(PeerRecord record) async => saved.add(record);
}

// Same 32-byte Ed25519 key, spelled both ways: the pairing QR carries
// base64url, everything the app stores is base64 standard.
const _standard = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
const _urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';

void main() {
  late Preferences prefs;

  setUp(() async {
    prefs = Preferences(_FakeSecureStorage());
    await prefs.load();
  });

  ConnectionManager managerWith(PairingStorage storage) => ConnectionManager(
    factory: (_, _) async => throw UnimplementedError('must not connect'),
    storage: storage,
    emitDebounce: Duration.zero,
  );

  test(
    'a url-safe banner handle resolves to the stored canonical peer',
    () async {
      final storage = _FakeStorage(const [
        PeerRecord(
          remoteEpk: _standard,
          sessionName: 'pi',
          relayUrl: 'ws://x',
          pairedAt: '2026-10-15T00:00:00Z',
          roomId: 'room-from-record',
        ),
      ]);
      final conn = managerWith(storage);
      addTearDown(() => storage.dispose());

      await retargetSession(
        storage: storage,
        prefs: prefs,
        conn: conn,
        epk: _urlSafe,
        roomId: 'room-from-banner',
      );

      expect(
        prefs.selectedPeerEpk,
        _standard,
        reason: 'the retarget must land on the stored handle',
      );
      expect(prefs.selectedRoomId, 'room-from-banner');
      expect(
        conn.activeRoomId,
        'room-from-banner',
        reason: 'the live connection must address the notified room',
      );
      expect(
        storage.saved.single.roomId,
        'room-from-banner',
        reason: 'the room is persisted on the record for the next cold start',
      );
      conn.dispose();
    },
  );

  test('a peer that is no longer stored is a silent no-op', () async {
    final storage = _FakeStorage(const [
      PeerRecord(
        remoteEpk: _standard,
        sessionName: 'pi',
        relayUrl: 'ws://x',
        pairedAt: '2026-10-15T00:00:00Z',
      ),
    ]);
    final conn = managerWith(storage);

    await retargetSession(
      storage: storage,
      prefs: prefs,
      conn: conn,
      epk: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
      roomId: 'r1',
    );

    expect(prefs.selectedPeerEpk, isNull);
    expect(storage.saved, isEmpty);
    conn.dispose();
  });
}
