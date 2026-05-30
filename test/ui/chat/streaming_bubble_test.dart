// Plan/32a — the thinking cursor: an empty StreamingMessage renders just the
// blinking cursor (no text), so the cursor shows during the pre-chunk gap.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/streaming_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(WidgetTester tester, StreamingMessage m) {
    return tester.pumpWidget(
      MaterialApp(home: Scaffold(body: StreamingBubble(m))),
    );
  }

  testWidgets('empty buffer shows ONLY the blinking cursor', (tester) async {
    await pump(tester, const StreamingMessage(inReplyTo: 'x'));
    await tester.pump(); // single frame — the cursor animation repeats forever
    expect(find.byKey(const Key('streaming-cursor')), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('non-empty buffer shows the text + the cursor', (tester) async {
    await pump(tester, const StreamingMessage(inReplyTo: 'x', buffer: 'hi'));
    await tester.pump();
    expect(find.text('hi'), findsOneWidget);
    expect(find.byKey(const Key('streaming-cursor')), findsOneWidget);
  });
}
