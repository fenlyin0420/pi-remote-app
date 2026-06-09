// Plan/28 Wave C — settings/quick-actions icon visibility in the
// chat input bar.

import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool disabled,
    required bool streaming,
    VoidCallback? onOpenQuickActions,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: disabled,
            streaming: streaming,
            onSend: (_) {},
            onCancel: () {},
            onOpenQuickActions: onOpenQuickActions,
          ),
        ),
      ),
    );
  }

  // Plan/28 — the quick-actions button is wrapped in a SizeTransition that
  // animates it in/out. When "hidden" the widget STAYS MOUNTED and only
  // collapses to zero width (it never leaves the tree), so `findsNothing` is
  // the wrong assertion. Instead: still present, but collapsed to width 0
  // (and therefore not tappable).
  final quickActionsKey = find.byKey(const Key('input-bar-quick-actions'));

  void expectCollapsed(WidgetTester tester) {
    expect(
      quickActionsKey,
      findsOneWidget,
      reason: 'stays mounted — SizeTransition collapses size, not the tree',
    );
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      0,
      reason: 'collapsed to zero width when hidden',
    );
  }

  void expectExpanded(WidgetTester tester) {
    expect(quickActionsKey, findsOneWidget);
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(
      tester.getSize(sizeTransition).width,
      greaterThan(0),
      reason: 'fully expanded when visible',
    );
  }

  testWidgets('quick actions button is visible when input is empty', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectExpanded(tester);
  });

  testWidgets('quick actions button hides (collapses) while typing', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.enterText(find.byType(TextField), 'hello');
    // Let the SizeTransition finish collapsing (it animates out over 320ms).
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button hides (collapses) when disabled', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: true,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button hides (collapses) while streaming', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  // While the turn is working the composer stays USABLE so the user can queue
  // the next message (typed text is held and sent when the turn ends). The
  // main action button is "stop"; a queue button appears once text is typed.
  testWidgets('streaming keeps the field usable and shows the stop button', (
    tester,
  ) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    // Field stays enabled (queueing requires typing while working).
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
    // The composer action button uses the heavier `600` weight variants
    // (see _ComposerActionButton._icon) — match those, not the plain glyphs.
    expect(find.byIcon(LucideIcons.square600), findsOneWidget); // stop
    expect(find.byIcon(LucideIcons.send600), findsNothing);
    expect(find.byIcon(LucideIcons.mic600), findsNothing);
    // No text yet → no queue button.
    expect(find.byKey(const Key('input-bar-queue')), findsNothing);
    // Typing reveals the queue button alongside the stop button.
    await tester.enterText(find.byType(TextField), 'next step');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('input-bar-queue')), findsOneWidget);
    expect(find.byIcon(LucideIcons.square600), findsOneWidget); // stop stays
  });

  testWidgets('tap fires onOpenQuickActions', (tester) async {
    var tapped = 0;
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () => tapped++,
    );
    await tester.tap(find.byKey(const Key('input-bar-quick-actions')));
    await tester.pump();
    expect(tapped, 1);
  });

  testWidgets('quick actions button stays collapsed when callback is null', (
    tester,
  ) async {
    // The button is always mounted now (so it can animate in/out); with no
    // handler `show` is false, so it collapses to zero width — hidden, but in
    // the tree. Same "hidden" contract as the typing/disabled/streaming cases.
    await pumpBar(tester, disabled: false, streaming: false);
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  // Hardware keyboard (iPad keyboard case): plain Enter SENDS, Shift+Enter
  // inserts a newline. Touch behaviour is unaffected (soft Enter = newline via
  // performAction, send via the button).
  testWidgets('hardware Enter sends; Shift+Enter inserts a newline', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InputBar(
            disabled: false,
            streaming: false,
            onSend: sent.add,
            onCancel: () {},
          ),
        ),
      ),
    );

    final field = find.byType(TextField);
    await tester.enterText(field, 'hello');
    await tester.pump();

    // Plain Enter → send + clear.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, ['hello']);
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'submit clears the field',
    );

    // Shift+Enter → newline, NOT a send.
    await tester.enterText(field, 'line1');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(sent, ['hello'], reason: 'shift+enter must not send');
    expect(
      tester.widget<TextField>(field).controller!.text,
      'line1\n',
      reason: 'shift+enter inserts a newline at the caret',
    );
  });

  // While streaming, Enter QUEUES the message on the Pi side: onSend is not
  // called now, the field clears, and the queued preview appears.
  testWidgets('Enter while streaming sets queued message', (
    tester,
  ) async {
    final sent = <String>[];
    final queued = <String>[];

    Widget build(bool streaming) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: false,
          streaming: streaming,
          onSend: sent.add,
          onSetQueued: queued.add,
          onCancel: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    final field = find.byType(TextField);
    await tester.enterText(field, 'do this next');
    await tester.pump();

    // Enter while streaming → queued, NOT sent; field clears and a preview
    // appears.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty, reason: 'queued, not sent immediately');
    expect(find.byKey(const Key('input-bar-queued-preview')), findsOneWidget);
    expect(find.text('do this next'), findsOneWidget);
    expect(
      tester.widget<TextField>(field).controller!.text,
      isEmpty,
      reason: 'queuing clears the field',
    );

    expect(queued, ['do this next']);
    expect(sent, isEmpty, reason: 'queued path uses onSetQueued, not onSend');
  });

  testWidgets('queue button appends messages with newline into one queued msg', (
    tester,
  ) async {
    final queued = <String>[];

    Widget build(bool streaming) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: false,
          streaming: streaming,
          onSend: (_) {},
          onSetQueued: queued.add,
          onCancel: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    final field = find.byType(TextField);

    await tester.enterText(field, 'one');
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-queue')));
    await tester.pump();

    await tester.enterText(field, 'two');
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-queue')));
    await tester.pump();

    expect(find.byKey(const Key('input-bar-queued-preview')), findsOneWidget);
    expect(find.text('one\ntwo'), findsOneWidget);
    expect(queued, ['one', 'one\ntwo']);
  });

  testWidgets('tap queued preview loads it into composer and clears Pi queue', (
    tester,
  ) async {
    final queued = <String>[];
    var clearCount = 0;

    Widget build(bool streaming) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: false,
          streaming: streaming,
          onSend: (_) {},
          onSetQueued: queued.add,
          onClearQueued: () => clearCount++,
          onCancel: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    final field = find.byType(TextField);
    await tester.enterText(field, 'edit me');
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-queue')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('input-bar-queued-preview')));
    await tester.pump();
    expect(find.byKey(const Key('input-bar-queued-preview')), findsNothing);
    expect(tester.widget<TextField>(field).controller!.text, 'edit me');
    expect(queued, ['edit me']);
    expect(clearCount, 1, reason: 'tap-to-edit clears queued auto-send');
  });

  testWidgets('clear queued preview drops queued message', (tester) async {
    final queued = <String>[];
    var clearCount = 0;

    Widget build(bool streaming) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: false,
          streaming: streaming,
          onSend: (_) {},
          onSetQueued: queued.add,
          onClearQueued: () => clearCount++,
          onCancel: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    final field = find.byType(TextField);
    await tester.enterText(field, 'drop me');
    await tester.pump();
    await tester.tap(find.byKey(const Key('input-bar-queue')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('input-bar-clear-queued')));
    await tester.pump();
    expect(find.byKey(const Key('input-bar-queued-preview')), findsNothing);
    expect(queued, ['drop me']);
    expect(clearCount, 1);
  });

  // Draft text the user did NOT commit (no Enter) must stay in the field when
  // the turn ends — it is never auto-sent.
  testWidgets('uncommitted draft stays in the field when the turn ends', (
    tester,
  ) async {
    final queued = <String>[];

    Widget build(bool streaming) => MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: false,
          streaming: streaming,
          onSend: (_) {},
          onSetQueued: queued.add,
          onCancel: () {},
        ),
      ),
    );

    await tester.pumpWidget(build(true));
    final field = find.byType(TextField);
    await tester.enterText(field, 'still editing');
    await tester.pump();

    // Turn ends without an Enter → nothing queued, text preserved.
    await tester.pumpWidget(build(false));
    await tester.pump();
    expect(queued, isEmpty);
    expect(tester.widget<TextField>(field).controller!.text, 'still editing');
  });
}
