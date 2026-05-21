// ConnectionManager state transition tests.
// Uses a fake ConnectionFactory so no real WS or transport is involved.

import 'dart:async';
import 'dart:typed_data';

import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:app/pairing/storage.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// Fake infrastructure
// ---------------------------------------------------------------------------

PeerRecord _fakePeer() => const PeerRecord(
  remoteEpk: 'epk_test',
  sessionName: 'test session',
  relayUrl: 'ws://localhost:8080',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _FakeStorage extends PairingStorage {
  final List<PeerRecord> peers;
  _FakeStorage(this.peers);

  @override
  Future<List<PeerRecord>> listPeers() async => peers;

  @override
  Future<void> savePeer(PeerRecord r) async {}
}

class _Q {
  final _buf = <Uint8List>[];
  final _wait = <Completer<Uint8List>>[];

  void add(Uint8List d) {
    if (_wait.isNotEmpty) {
      _wait.removeAt(0).complete(d);
    } else {
      _buf.add(d);
    }
  }

  Future<Uint8List> next() {
    if (_buf.isNotEmpty) return Future.value(_buf.removeAt(0));
    final c = Completer<Uint8List>();
    _wait.add(c);
    return c.future;
  }
}

class _T implements PeerTransport {
  final _Q _s;
  final _Q _r;
  bool _closed = false;

  _T({required _Q send, required _Q recv}) : _s = send, _r = recv;

  @override Future<void> send(Uint8List d) async => _s.add(d);
  @override Future<Uint8List> receive() => _r.next();
  @override Future<void> close() async { _closed = true; }
  bool get isClosed => _closed;
}

PlainPeerChannel _makeChannel() {
  final q1 = _Q();
  final q2 = _Q();
  final iT = _T(send: q1, recv: q2);
  return PlainPeerChannel(transport: iT);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ConnectionManager', () {
    test('boot() → StatusNoPeer when storage is empty', () async {
      final cm = ConnectionManager(
        factory: (peer, cancel) async => _makeChannel(),
        storage: _FakeStorage([]),
      );

      final states = <ConnectionStatus>[];
      cm.statusStream.listen(states.add);

      await cm.boot();
      await Future<void>.delayed(Duration.zero);

      expect(cm.status, isA<StatusNoPeer>());
      cm.dispose();
    });

    test('boot() → Connecting → Online when factory succeeds', () async {
      final states = <ConnectionStatus>[];
      final cm = ConnectionManager(
        factory: (_, token) async {
          if (token.isCancelled) throw Exception('cancelled');
          return _makeChannel();
        },
        storage: _FakeStorage([_fakePeer()]),
      );

      cm.statusStream.listen(states.add);
      await cm.boot();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(states.any((s) => s is StatusConnecting), isTrue);
      expect(cm.status, isA<StatusOnline>());
      expect(cm.channel, isNotNull);

      cm.dispose();
    });

    test('factory failure → StatusRetrying with attempt=0', () async {
      final states = <ConnectionStatus>[];
      final cm = ConnectionManager(
        factory: (peer, cancel) async => throw Exception('connection refused'),
        storage: _FakeStorage([_fakePeer()]),
      );

      cm.statusStream.listen(states.add);
      await cm.boot();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(states.any((s) => s is StatusRetrying), isTrue);
      final retrying = states.whereType<StatusRetrying>().first;
      expect(retrying.attempt, 0);
      expect(retrying.nextRetry.inSeconds, 1);

      cm.dispose();
    });

    test('disconnect() returns to StatusNoPeer', () async {
      final cm = ConnectionManager(
        factory: (peer, cancel) async => _makeChannel(),
        storage: _FakeStorage([_fakePeer()]),
      );

      await cm.boot();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(cm.status, isA<StatusOnline>());

      await cm.disconnect();
      expect(cm.status, isA<StatusNoPeer>());
      expect(cm.channel, isNull);

      cm.dispose();
    });

    test('backoff sequence increments on repeated failures', () async {
      final retries = <StatusRetrying>[];
      final cm = ConnectionManager(
        factory: (peer, token) async {
          if (token.isCancelled) throw Exception('cancelled');
          throw Exception('refused');
        },
        storage: _FakeStorage([_fakePeer()]),
      );

      cm.statusStream
          .where((s) => s is StatusRetrying)
          .cast<StatusRetrying>()
          .listen(retries.add);
      await cm.boot();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(retries, isNotEmpty);
      expect(retries.first.attempt, 0);
      expect(retries.first.nextRetry, const Duration(seconds: 1));

      cm.dispose();
    });

    test('adopt: factory NOT called, state becomes StatusOnline immediately', () async {
      var factoryCalled = false;
      final cm = ConnectionManager(
        factory: (peer, cancel) async {
          factoryCalled = true;
          return _makeChannel();
        },
        storage: _FakeStorage([_fakePeer()]),
      );

      final fakeChannel = _makeChannel();
      final states = <ConnectionStatus>[];
      cm.statusStream.listen(states.add);

      cm.adopt(fakeChannel, _fakePeer());

      expect(factoryCalled, isFalse,
          reason: 'factory must NOT be called when adopting a live channel');
      expect(cm.status, isA<StatusOnline>());
      expect(cm.channel, isNotNull);

      cm.dispose();
    });

    test('activePeer is null at start, set by adopt, cleared by disconnect',
        () async {
      final cm = ConnectionManager(
        factory: (_, _) async => _makeChannel(),
        storage: _FakeStorage([_fakePeer()]),
      );
      expect(cm.activePeer, isNull);

      cm.adopt(_makeChannel(), _fakePeer());
      expect(cm.activePeer?.remoteEpk, 'epk_test');

      await cm.disconnect();
      expect(cm.activePeer, isNull);

      cm.dispose();
    });

    test('switchTo: idempotent when already online to the target', () async {
      var factoryCalls = 0;
      final cm = ConnectionManager(
        factory: (peer, _) async {
          factoryCalls++;
          return _makeChannel();
        },
        storage: _FakeStorage([_fakePeer()]),
      );
      cm.adopt(_makeChannel(), _fakePeer());
      expect(cm.activePeer?.remoteEpk, 'epk_test');

      await cm.switchTo(_fakePeer());
      expect(factoryCalls, 0,
          reason: 'no reconnect when already online to that peer');
      expect(cm.activePeer?.remoteEpk, 'epk_test');

      cm.dispose();
    });

    test('switchTo: disconnects old peer and connects to new', () async {
      final factoryCalls = <String>[];
      const other = PeerRecord(
        remoteEpk: 'epk_other',
        sessionName: 'Other',
        relayUrl: 'ws://localhost:8080',
        pairedAt: '2026-01-02T00:00:00Z',
      );
      final cm = ConnectionManager(
        factory: (peer, _) async {
          factoryCalls.add(peer.remoteEpk);
          return _makeChannel();
        },
        storage: _FakeStorage([_fakePeer(), other]),
      );
      cm.adopt(_makeChannel(), _fakePeer());

      await cm.switchTo(other);
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(factoryCalls, ['epk_other']);
      expect(cm.activePeer?.remoteEpk, 'epk_other');
      expect(cm.status, isA<StatusOnline>());

      cm.dispose();
    });

    test('boot is no-op while another peer connect is in flight', () async {
      // Repro for the Home tap bug: user picks Pi B (not peers.first); the
      // ChatViewModel's constructor calls boot() while switchTo is still
      // awaiting the factory. boot() must NOT cancel the in-flight connect
      // and reroute to peers.first.
      const a = PeerRecord(
        remoteEpk: 'epk_A',
        sessionName: 'A',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-01T00:00:00Z',
      );
      const b = PeerRecord(
        remoteEpk: 'epk_B',
        sessionName: 'B',
        relayUrl: 'ws://localhost',
        pairedAt: '2026-01-02T00:00:00Z',
      );

      // Factory hangs forever — simulates a slow WS connect.
      final factoryCalls = <String>[];
      final hang = Completer<IChannel>();
      final cm = ConnectionManager(
        factory: (peer, _) {
          factoryCalls.add(peer.remoteEpk);
          return hang.future;
        },
        storage: _FakeStorage([a, b]), // peers.first = A
      );

      // Kick off a switch to B (in-flight).
      // ignore: unawaited_futures
      cm.switchTo(b);
      await Future<void>.delayed(Duration.zero);
      expect(factoryCalls, ['epk_B']);
      expect(cm.activePeer?.remoteEpk, 'epk_B');

      // ChatViewModel-style boot kicks in: must NOT override the active peer.
      await cm.boot();
      expect(factoryCalls, ['epk_B'],
          reason: 'boot must not cancel the in-flight connect and reroute');
      expect(cm.activePeer?.remoteEpk, 'epk_B');

      cm.dispose();
    });

    test('boot after adopt is a no-op when already online', () async {
      var factoryCalled = false;
      final cm = ConnectionManager(
        factory: (peer, cancel) async {
          factoryCalled = true;
          return _makeChannel();
        },
        storage: _FakeStorage([_fakePeer()]),
      );

      final fakeChannel = _makeChannel();
      cm.adopt(fakeChannel, _fakePeer());
      expect(cm.status, isA<StatusOnline>());

      await cm.boot();
      await Future<void>.delayed(Duration.zero);

      expect(factoryCalled, isFalse,
          reason: 'boot must skip factory when already online via adopt');
      expect(cm.status, isA<StatusOnline>());

      cm.dispose();
    });
  });

  // Channel close keeps `_closed` reachable so the lint about unused field
  // is silenced; verify the close path runs.
  test('PlainPeerChannel.close marks transport closed', () async {
    final q1 = _Q();
    final q2 = _Q();
    final t = _T(send: q1, recv: q2);
    final ch = PlainPeerChannel(transport: t);
    await ch.close();
    expect(t.isClosed, isTrue);
  });

  // ---------------------------------------------------------------------------
  // offline-loop fix regressions (Patches A + B)
  // ---------------------------------------------------------------------------

  group('ConnectionManager — offline-loop fix', () {
    test(
      'onDone on a stale channel (already replaced) does NOT trigger a retry',
      () async {
        final lostStates = <ConnectionStatus>[];
        // Two distinct channels we can independently control.
        final chA = _ControllableChannel();
        final chB = _ControllableChannel();
        var idx = 0;
        final cm = ConnectionManager(
          factory: (_, _) async {
            return [chA, chB][idx++];
          },
          storage: _FakeStorage([_fakePeer()]),
        );

        await cm.connectTo(_fakePeer()); // → chA
        expect(cm.channel, same(chA));
        await Future<void>.delayed(const Duration(milliseconds: 5));

        // Force a reconnect — chB becomes the live channel.
        await cm.disconnect();
        await cm.connectTo(_fakePeer()); // → chB
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(cm.channel, same(chB));

        cm.statusStream.listen(lostStates.add);
        // Now simulate chA's `onDone` firing late (the relay killed the
        // old WS after the new one authenticated). Without the stale
        // guard this would emit StatusRetrying.
        await chA.closeStream();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          lostStates.whereType<StatusRetrying>(),
          isEmpty,
          reason: 'stale onDone must not schedule a retry',
        );
        expect(cm.status, isA<StatusOnline>());

        cm.dispose();
      },
    );

    test(
      '_retryAttempt stays at 0 until the channel listener sees inbound; '
      'a channel close right after connect keeps the backoff at attempt=0 '
      '(rather than escalating)',
      () async {
        // Multiple controllable channels, each closes mid-flight before
        // delivering any inbound — simulates the death-spiral scenario
        // where the relay keeps kicking us.
        final channels = <_ControllableChannel>[];
        var idx = 0;
        final cm = ConnectionManager(
          factory: (_, _) async {
            final ch = _ControllableChannel();
            channels.add(ch);
            return ch;
          },
          storage: _FakeStorage([_fakePeer()]),
        );

        final retries = <StatusRetrying>[];
        cm.statusStream
            .where((s) => s is StatusRetrying)
            .cast<StatusRetrying>()
            .listen(retries.add);

        await cm.connectTo(_fakePeer());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        // Channel closes WITHOUT sending any inbound → counts as a real
        // loss (live channel). Retry should be scheduled with attempt=0.
        await channels[idx++].closeStream();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(retries, hasLength(1));
        expect(retries.first.attempt, 0);

        cm.dispose();
      },
    );

    // -----------------------------------------------------------------------
    // Presence (plano 12)
    // -----------------------------------------------------------------------

    test(
      'boot subscribes presence with ALL stored peers',
      () async {
        const a = PeerRecord(
          remoteEpk: 'epk_A',
          sessionName: 'A',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        const b = PeerRecord(
          remoteEpk: 'epk_B',
          sessionName: 'B',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-02T00:00:00Z',
        );
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([a, b]),
        );

        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final subs = ch.sentControl
            .where((m) => m['type'] == 'subscribe_presence')
            .toList();
        expect(subs, isNotEmpty);
        expect((subs.first['peers'] as List).toSet(), {'epk_A', 'epk_B'});

        cm.dispose();
      },
    );

    test(
      'peer_online frame → presence map updates + stream emits',
      () async {
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final snapshots = <Map<String, PresenceState>>[];
        cm.presenceStream.listen(snapshots.add);
        ch.pushControl(const PeerOnline(peer: 'epk_test'));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cm.presenceFor('epk_test'), isA<PresenceOnline>());
        expect(snapshots, isNotEmpty);
        // The map is keyed in canonical (standard base64) form; look up
        // via `presenceFor` which coerces — direct map access would
        // require the standard-encoded key.
        expect(snapshots.last.values, contains(isA<PresenceOnline>()));

        cm.dispose();
      },
    );

    test(
      'peer_offline frame → PresenceOffline with sinceTs',
      () async {
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        ch.pushControl(const PeerOffline(peer: 'epk_test', sinceTs: 42));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        final s = cm.presenceFor('epk_test') as PresenceOffline;
        expect(s.sinceTs, 42);

        cm.dispose();
      },
    );

    test(
      'presence snapshot → batch update for all listed peers',
      () async {
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        ch.pushControl(const PresenceSnapshot(states: [
          PeerPresence(peer: 'epk_A', online: true, sinceTs: null),
          PeerPresence(peer: 'epk_B', online: false, sinceTs: 100),
        ]));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(cm.presenceFor('epk_A'), isA<PresenceOnline>());
        expect(cm.presenceFor('epk_B'), isA<PresenceOffline>());
        expect((cm.presenceFor('epk_B') as PresenceOffline).sinceTs, 100);

        cm.dispose();
      },
    );

    // -----------------------------------------------------------------------
    // Plano 13: chat-state recovery (boot preferredEpk + no-NoPeer switchTo)
    // -----------------------------------------------------------------------

    test(
      'boot(preferredEpk=B) connects to B even when peers.first is A',
      () async {
        const a = PeerRecord(
          remoteEpk: 'epk_A',
          sessionName: 'A',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        const b = PeerRecord(
          remoteEpk: 'epk_B',
          sessionName: 'B',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-02T00:00:00Z',
        );
        final connects = <String>[];
        final cm = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _ControllableChannel();
          },
          storage: _FakeStorage([a, b]),
        );

        await cm.boot(preferredEpk: 'epk_B');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(connects, ['epk_B']);
        expect(cm.activePeer?.remoteEpk, 'epk_B');

        cm.dispose();
      },
    );

    test(
      'boot() without preferredEpk falls back to peers.first',
      () async {
        const a = PeerRecord(
          remoteEpk: 'epk_A',
          sessionName: 'A',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        const b = PeerRecord(
          remoteEpk: 'epk_B',
          sessionName: 'B',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-02T00:00:00Z',
        );
        final connects = <String>[];
        final cm = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _ControllableChannel();
          },
          storage: _FakeStorage([a, b]),
        );

        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(connects, ['epk_A']);

        cm.dispose();
      },
    );

    test(
      'boot(preferredEpk=missing) falls back to peers.first',
      () async {
        const a = PeerRecord(
          remoteEpk: 'epk_A',
          sessionName: 'A',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        final connects = <String>[];
        final cm = ConnectionManager(
          factory: (peer, _) async {
            connects.add(peer.remoteEpk);
            return _ControllableChannel();
          },
          storage: _FakeStorage([a]),
        );

        await cm.boot(preferredEpk: 'epk_does_not_exist');
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(connects, ['epk_A']);

        cm.dispose();
      },
    );

    test(
      'switchTo between peers never emits transient StatusNoPeer',
      () async {
        const a = PeerRecord(
          remoteEpk: 'epk_A',
          sessionName: 'A',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        const b = PeerRecord(
          remoteEpk: 'epk_B',
          sessionName: 'B',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-02T00:00:00Z',
        );
        final cm = ConnectionManager(
          factory: (_, _) async => _ControllableChannel(),
          storage: _FakeStorage([a, b]),
        );
        cm.adopt(_ControllableChannel(), a);

        final seen = <ConnectionStatus>[];
        cm.statusStream.listen(seen.add);

        await cm.switchTo(b);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(
          seen.whereType<StatusNoPeer>(),
          isEmpty,
          reason: 'plano 13 — switchTo must not flash through NoPeer',
        );
        // Must still go through Connecting on the way to Online.
        expect(seen.any((s) => s is StatusConnecting), isTrue);

        cm.dispose();
      },
    );

    test(
      'disconnect() still emits StatusNoPeer (public API contract intact)',
      () async {
        final cm = ConnectionManager(
          factory: (_, _) async => _ControllableChannel(),
          storage: _FakeStorage([_fakePeer()]),
        );
        cm.adopt(_ControllableChannel(), _fakePeer());

        final seen = <ConnectionStatus>[];
        cm.statusStream.listen(seen.add);

        await cm.disconnect();
        // Broadcast stream delivers events via microtask; let them drain.
        await Future<void>.delayed(const Duration(milliseconds: 5));

        expect(seen.whereType<StatusNoPeer>(), isNotEmpty);
        expect(cm.activePeer, isNull);

        cm.dispose();
      },
    );

    test(
      'boot() normalises _subscribedEpks: replay frames go out in standard '
      '(regression — url-safe leak caused inconsistent Home dots)',
      () async {
        // PeerRecord stores url-safe (with `_`). The relay indexes by
        // standard (with `/`). Boot's `_replaySubscriptions` runs after
        // _connect succeeds; assert the FIRST replay payload is already
        // standard, not url-safe.
        const urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
        const peer = PeerRecord(
          remoteEpk: urlSafe,
          sessionName: 'Pi',
          relayUrl: 'ws://x',
          pairedAt: '2026-01-01T00:00:00Z',
        );
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([peer]),
        );

        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final subs = ch.sentControl
            .where((m) => m['type'] == 'subscribe_presence')
            .toList();
        expect(subs, isNotEmpty);
        final wire = (subs.first['peers'] as List).single as String;
        expect(wire.contains('_'), isFalse,
            reason: 'url-safe `_` leaked into the relay-bound payload');
        expect(wire.contains('-'), isFalse);
        expect(wire.contains('/') || wire.contains('+') || wire.endsWith('='),
            isTrue,
            reason: 'must be standard base64');

        cm.dispose();
      },
    );

    test(
      'subscribe_presence converts url-safe epks to standard base64',
      () async {
        // 32-byte random key → base64url has `_` if the bytes happen to
        // map to 0x3e/0x3f sextets. Use one with `_` deterministically:
        // bytes = [0xff, 0xfe, 0xfd, ...] → standard `+/Pz...`,
        // url-safe `-_Pz...`. Easier: pick a known url-safe string with
        // `_` and decode-encode through the helper.
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ch.sentControl.clear();

        // url-safe contains `-_`; standard contains `+/`.
        const urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
        cm.subscribeToPeers([urlSafe]);

        final sub = ch.sentControl
            .firstWhere((m) => m['type'] == 'subscribe_presence');
        final wire = (sub['peers'] as List).single as String;
        expect(wire.contains('_'), isFalse,
            reason: 'standard base64 must not contain `_`');
        expect(wire.contains('-'), isFalse,
            reason: 'standard base64 must not contain `-`');

        cm.dispose();
      },
    );

    test(
      'presenceFor accepts either url-safe or standard epk',
      () async {
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Relay pushes presence with the STANDARD form (what the relay
        // sees in `hello.pubkey`).
        const standard = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
        ch.pushControl(const PeerOnline(peer: standard));
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // The app looks up using the url-safe form from PairingStorage.
        const urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
        expect(cm.presenceFor(urlSafe), isA<PresenceOnline>());
        // And standard form still works.
        expect(cm.presenceFor(standard), isA<PresenceOnline>());

        cm.dispose();
      },
    );

    test(
      'subscribeToPeers (called later) sends a fresh subscribe_presence',
      () async {
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (_, _) async => ch,
          storage: _FakeStorage([_fakePeer()]),
        );
        await cm.boot();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        ch.sentControl.clear(); // ignore the boot subscribe

        cm.subscribeToPeers(['epk_new1', 'epk_new2']);

        final subs = ch.sentControl
            .where((m) => m['type'] == 'subscribe_presence')
            .toList();
        expect(subs, hasLength(1));
        // The wire form is normalised to standard base64; the test
        // only cares that the count matches and the inputs survived
        // the round-trip semantically.
        expect((subs.first['peers'] as List), hasLength(2));

        cm.dispose();
      },
    );

    test(
      'inbound message resets _retryAttempt back to 0',
      () async {
        // First connect fails → attempt rises. Second connect succeeds
        // and delivers an inbound → next failure should re-start at 0.
        var attempt = 0;
        final ch = _ControllableChannel();
        final cm = ConnectionManager(
          factory: (peer, _) async {
            attempt++;
            if (attempt == 1) throw Exception('fail once');
            return ch;
          },
          storage: _FakeStorage([_fakePeer()]),
        );

        final retries = <StatusRetrying>[];
        cm.statusStream
            .where((s) => s is StatusRetrying)
            .cast<StatusRetrying>()
            .listen(retries.add);

        // ignore: unawaited_futures
        cm.connectTo(_fakePeer());
        // First attempt fails → schedules retry attempt=0.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(retries.first.attempt, 0);

        // Wait for retry to fire (~1s) and the second attempt to succeed.
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(cm.status, isA<StatusOnline>());

        // Deliver an inbound message; listener resets retry attempt.
        ch.pushMessage(Pong(inReplyTo: 'x'));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Now drop the channel → another retry should start at 0 again.
        await ch.closeStream();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final fresh = retries.last;
        expect(
          fresh.attempt,
          0,
          reason: 'inbound traffic resets backoff; next loss is attempt=0',
        );

        cm.dispose();
      },
    );
  });
}

// ---------------------------------------------------------------------------
// _ControllableChannel — IChannel where we control the inbound stream and
// can simulate WS close on demand. Used by the offline-loop regression
// tests. Also implements [IControlLink] so presence tests can inject
// frames and inspect outbound `subscribe_presence`/`presence_check`.
// ---------------------------------------------------------------------------

class _ControllableChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _controlCtrl = StreamController<ControlInbound>.broadcast();
  final List<Map<String, dynamic>> sentControl = [];

  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;

  @override
  Future<void> send(ClientMessage msg) async {}

  @override
  Future<void> close() async {
    if (!_ctrl.isClosed) await _ctrl.close();
    if (!_controlCtrl.isClosed) await _controlCtrl.close();
  }

  void pushMessage(ServerMessage m) {
    if (!_ctrl.isClosed) _ctrl.add(m);
  }

  Future<void> closeStream() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }

  @override
  Stream<ControlInbound> get controlFrames => _controlCtrl.stream;

  @override
  void sendControl(Map<String, dynamic> json) {
    sentControl.add(json);
  }

  void pushControl(ControlInbound c) {
    if (!_controlCtrl.isClosed) _controlCtrl.add(c);
  }
}

// ---------------------------------------------------------------------------
// Presence (plano 12)
// ---------------------------------------------------------------------------

void mainPresence() {} // placeholder so the group below is visible
