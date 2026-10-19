// LOCAL (fenlyin): the Home tile's subtitle names the running model plus its
// provider once a fetched catalogue has taught the app the mapping.

import 'package:app/data/preferences/preferences.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/home/widgets/session_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_secure_storage.dart';

const _peer = PeerRecord(
  remoteEpk: 'epk_home',
  sessionName: 'pi',
  relayUrl: 'ws://relay',
  pairedAt: '2026-01-01T00:00:00Z',
);

const _room = RoomInfo(
  roomId: 'main',
  startedAt: 1,
  model: 'Claude Opus 4.7',
);

Future<void> _pumpTile(WidgetTester tester, Preferences prefs) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<Preferences>.value(
      value: prefs,
      child: const MaterialApp(
        home: Scaffold(
          body: SessionTile(
            peer: _peer,
            isLive: true,
            onOpen: _noop,
            room: _room,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void _noop() {}

void main() {
  testWidgets('subtitle shows "model · provider" when the provider is known', (
    tester,
  ) async {
    final prefs = Preferences(FakeSecureStorage());
    await prefs.rememberModelProviders({'Claude Opus 4.7': 'anthropic'});

    await _pumpTile(tester, prefs);

    expect(find.text('Claude Opus 4.7 · anthropic'), findsOneWidget);
  });

  testWidgets('subtitle falls back to the bare model name while unknown', (
    tester,
  ) async {
    await _pumpTile(tester, Preferences(FakeSecureStorage()));

    expect(find.text('Claude Opus 4.7'), findsOneWidget);
  });
}
