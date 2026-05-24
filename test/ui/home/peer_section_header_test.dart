// Plan/27 Wave A — PiCard subtitle showing the agent harness.

import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart' show PiHarness;
import 'package:app/ui/home/widgets/peer_section_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

PeerRecord _peer({
  String? nickname,
  String sessionName = 'Pi',
  PiHarness? harness,
}) =>
    PeerRecord(
      remoteEpk: 'pk1',
      sessionName: sessionName,
      relayUrl: 'ws://x',
      pairedAt: '2026-01-01T00:00:00Z',
      nickname: nickname,
      harness: harness,
    );

Future<void> _pump(WidgetTester tester, PeerRecord peer) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PeerSectionHeader(peer: peer)),
    ),
  );
}

void main() {
  group('PeerSectionHeader (plan/27 Wave A)', () {
    testWidgets('shows nickname uppercase + harness subtitle', (tester) async {
      await _pump(
        tester,
        _peer(
          nickname: 'Macbook',
          harness: const PiHarness(name: 'Pi coding agent', version: '0.4.2'),
        ),
      );

      expect(find.text('MACBOOK'), findsOneWidget);
      expect(find.text('via Pi coding agent'), findsOneWidget);
    });

    testWidgets(
      'falls back to default harness when peer.harness is null (legacy)',
      (tester) async {
        await _pump(
          tester,
          _peer(nickname: 'Mac', harness: null),
        );

        // Default is PiHarness.piCodingAgentUnknown → "Pi coding agent".
        expect(find.text('via Pi coding agent'), findsOneWidget);
      },
    );

    testWidgets(
      'reflects future Claude Code / OpenCode harnesses verbatim',
      (tester) async {
        await _pump(
          tester,
          _peer(
            nickname: 'Mac',
            harness: const PiHarness(name: 'Claude Code', version: '0.7.1'),
          ),
        );

        expect(find.text('via Claude Code'), findsOneWidget);
        expect(find.text('via Pi coding agent'), findsNothing);
      },
    );

    testWidgets(
      'falls back to sessionName when no nickname is set',
      (tester) async {
        await _pump(
          tester,
          _peer(sessionName: 'remote_pi · main'),
        );

        expect(find.text('REMOTE_PI · MAIN'), findsOneWidget);
      },
    );
  });
}
