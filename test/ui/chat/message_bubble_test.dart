// Agent output (AssistantBubble) must use the FULL content width, not the old
// 340px cap (user-reported: markdown reply not filling the horizontal space).
//
// A user message also pins the attachment layout: one bubble per picture, in
// the order they were sent — never collapsed into one figure or a counter.

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:app/ui/chat/widgets/message_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// A real 200×200 PNG (1-bit, so it inlines small).
const _square =
    'iVBORw0KGgoAAAANSUhEUgAAAMgAAADIAQAAAACFI5MzAAAAKElEQVR42u3JoQEAAAgDoOn/'
    'P2u1+AFUavLoGGOMMcYYY4wxxhhjzLUvnQKPTWDWfAAAAABJRU5ErkJggg==';

void main() {
  testWidgets('AssistantBubble wraps at the full available width (>340)', (
    tester,
  ) async {
    const longText =
        'This is a sufficiently long agent reply that would have wrapped at '
        'the old 340px cap but should now span the full content width of the '
        'message list so it reads naturally on wide screens.';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            child: AssistantBubble(AssistantMsg(id: 'a1', text: longText)),
          ),
        ),
      ),
    );
    await tester.pump();

    // Markdown rendered + spanning beyond the old 340px cap.
    expect(find.byType(AgentMarkdown), findsOneWidget);
    final width = tester.getSize(find.byType(AgentMarkdown)).width;
    expect(
      width,
      greaterThan(340),
      reason: 'agent markdown should fill beyond the old 340px cap',
    );
  });

  testWidgets('AssistantBubble is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AssistantBubble(AssistantMsg(id: 'a1', text: 'reply')),
        ),
      ),
    );
    await tester.pump();
    // AgentMarkdown wraps the reply in a SelectionArea when selectable.
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('UserBubble text is selectable (copyable)', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(UserMsg(id: 'u1', text: 'my message')),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('my message'), findsOneWidget);
  });

  testWidgets('pending steer bubble shows steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'busy follow-up',
              status: UserMsgStatus.pending,
              steering: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
    expect(find.text('sending…'), findsNothing);
  });

  testWidgets('confirmed steer bubble keeps steering label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(id: 'u1', text: 'accepted follow-up', steering: true),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('steering…'), findsOneWidget);
  });

  testWidgets('pending normal bubble keeps sending label', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UserBubble(
            UserMsg(
              id: 'u1',
              text: 'normal send',
              status: UserMsgStatus.pending,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('sending…'), findsOneWidget);
  });

  testWidgets('every picture of a multi-image message gets its own bubble', (
    tester,
  ) async {
    // A phone-sized surface: three 200 pt pictures plus their gaps have to fit
    // for the stack to be measurable.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: UserBubble(
              UserMsg(
                id: 'u1',
                text: '',
                images: List.filled(
                  3,
                  const MessageImage(data: _square, mime: 'image/png'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final bubbles = find.byType(ImageBubble);
    expect(bubbles, findsNWidgets(3));
    // Stacked in send order, each below the previous one.
    final tops = [
      for (var i = 0; i < 3; i++) tester.getTopLeft(bubbles.at(i)).dy,
    ];
    expect(tops[1], greaterThan(tops[0]));
    expect(tops[2], greaterThan(tops[1]));
    // And each keeps the picture's own ratio (200×200, not cropped to a band).
    final box = tester.getSize(bubbles.at(0));
    expect(box.width, closeTo(200, 0.01));
    expect(box.height, closeTo(200, 0.01));
  });
}
