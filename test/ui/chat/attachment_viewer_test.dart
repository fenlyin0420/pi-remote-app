// Closing the full-screen viewer must not raise the soft keyboard.
//
// The failure this pins down: the composer keeps its focus node from an
// earlier tap (the IME was hidden, the node was not), and popping a route
// hands focus back to whatever the underlying scope had — so every preview the
// user closed ended with a keyboard covering the chat. Dropping focus on both
// sides of the route is what makes "come back, keyboard stays down" the
// default.
//
// The page itself is themed: text follows the app's palette (a light-theme
// user must not drop into a black page) while an image keeps the black
// backdrop it is read against.

import 'dart:convert';

import 'package:app/domain/session_state.dart';
import 'package:app/ui/chat/widgets/agent_markdown.dart';
import 'package:app/ui/chat/widgets/attachment_viewer.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 PNG — real enough for `Image.memory` to decode.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

const _card = AttachmentMsg(
  id: 'att_tc-1',
  name: 'shot.png',
  path: '/home/p/shot.png',
  mime: 'image/png',
  size: 10,
  blobName: 'att_tc-1.bin',
);

/// A text file the Pi sent — the case the theme applies to.
const _notes = AttachmentMsg(
  id: 'att_tc-2',
  name: 'notes.md',
  path: '/home/p/notes.md',
  mime: 'text/markdown',
  size: 120,
  blobName: 'att_tc-2.bin',
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

/// Pump the viewer directly, so the page under test is the only [Scaffold].
Future<void> _pumpViewer(
  WidgetTester tester,
  AttachmentMsg msg, {
  required ThemeData theme,
  Map<String, Uint8List> blobs = const {},
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: AttachmentViewer(
        message: msg,
        loadBytes: (blob) async => blobs[blob],
        onSave: (msg) async => 'Download/Remote Pi/${msg.name}',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Color _pageBackground(WidgetTester tester) =>
    tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor!;

void main() {
  testWidgets('a text file follows the app theme, not a black page', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      _notes,
      theme: buildLightTheme(),
      blobs: {'att_tc-2.bin': _bytes('# notes\n\nhello from the desk')},
    );

    expect(_pageBackground(tester), AppColors.light.bg);
    expect(
      tester.widget<AgentMarkdown>(find.byType(AgentMarkdown)).data,
      contains('hello from the desk'),
    );
  });

  testWidgets('in dark mode the text page keeps the dark background', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      _notes,
      theme: buildDarkTheme(),
      blobs: {'att_tc-2.bin': _bytes('plain text')},
    );

    expect(_pageBackground(tester), AppColors.dark.bg);
  });

  testWidgets('an image keeps its black backdrop even in the light theme', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      _card,
      theme: buildLightTheme(),
      blobs: {'att_tc-1.bin': _png},
    );

    expect(_pageBackground(tester), Colors.black);
  });

  testWidgets('a fenced block is the app code card, not the package light one', (
    tester,
  ) async {
    await _pumpViewer(
      tester,
      _notes,
      theme: buildDarkTheme(),
      blobs: {'att_tc-2.bin': _bytes('```\nmd5 ee76fb\n```\n')},
    );

    // gpt_markdown's own code field is a Material-light slab whose only
    // affordance is a "Copy code" label; the app's card is the one with the
    // icon button.
    expect(find.byKey(const Key('code-copy')), findsOneWidget);
    expect(find.text('Copy code'), findsNothing);
  });

  testWidgets('double-tap zooms in smoothly around the image center', (tester) async {
    await _pumpViewer(tester, _card, theme: buildLightTheme(), blobs: {
      'att_tc-1.bin': _png,
    });

    final target = find.byType(InteractiveViewer);

    Future<double> scale() async {
      final transform = tester.widget<Transform>(
        find.descendant(of: target, matching: find.byType(Transform)),
      ).transform;
      return transform[0];
    }

    // Double tap: two quick taps in the image area.
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(target);

    // The zoom eases in (~280 ms) rather than snapping: right after the
    // second tap it cannot be at the target scale yet, whatever the
    // recognizer's frame delay (an instant zoom would already be 2.5).
    await tester.pump(const Duration(milliseconds: 50));
    expect(await scale(), lessThan(2.5), reason: 'zoom eases in, no snap');

    await tester.pumpAndSettle();
    expect(await scale(), closeTo(2.5, 0.01), reason: 'zoomed in 2.5x');

    // And it magnified IN PLACE: the image's center (the viewport center)
    // maps onto itself — the old origin-anchored scale slid the image down
    // and left the top of the screen black. The transform lives in the
    // viewer's LOCAL space, so measure the center relative to its top-left.
    final center = tester.getCenter(target) - tester.getTopLeft(target);
    final m = tester.widget<Transform>(
      find.descendant(of: target, matching: find.byType(Transform)),
    ).transform;
    expect(m[0] * center.dx + m[12], closeTo(center.dx, 0.5));
    expect(m[5] * center.dy + m[13], closeTo(center.dy, 0.5));

    // A second double tap eases back to fit — no snap, by the same token.
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(target);
    await tester.pump(const Duration(milliseconds: 50));
    expect(await scale(), greaterThan(1.0), reason: 'zooms out eased');
    await tester.pumpAndSettle();

    final fit = tester.widget<Transform>(
      find.descendant(of: target, matching: find.byType(Transform)),
    ).transform;
    expect(fit[0], closeTo(1.0, 0.01), reason: 'back to fit');
  });

  testWidgets('leaving the viewer leaves the composer unfocused', (tester) async {
    final composer = FocusNode(debugLabel: 'composer');
    addTearDown(composer.dispose);
    final openButton = GlobalKey();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              // Stands in for the chat composer: a focused text field is what
              // raises the soft keyboard.
              TextField(focusNode: composer, decoration: const InputDecoration()),
              Builder(
                builder: (context) => TextButton(
                  key: openButton,
                  onPressed: () => AttachmentViewer.open(
                    context,
                    message: _card,
                    loadBytes: (_) async => null,
                    onSave: (_) async => 'Pictures/Remote Pi/shot.png',
                  ),
                  child: const Text('open'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    // The real situation: the user tapped the composer at some point, so the
    // field holds focus (the IME may be down; focus is not).
    composer.requestFocus();
    await tester.pump();
    expect(composer.hasFocus, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('viewer-save')), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    // Back in the chat: the viewer is gone AND the keyboard stays down.
    expect(find.byKey(const Key('viewer-save')), findsNothing);
    expect(composer.hasFocus, isFalse);
  });
}
