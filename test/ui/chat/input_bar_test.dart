// Plan/28 Wave C — settings/quick-actions icon visibility in the
// chat input bar.

import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required bool disabled,
    required bool streaming,
    VoidCallback? onOpenQuickActions,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InputBar(
          disabled: disabled,
          streaming: streaming,
          onSend: (_) {},
          onCancel: () {},
          onOpenQuickActions: onOpenQuickActions,
        ),
      ),
    ));
  }

  // Plan/28 — the quick-actions button is wrapped in a SizeTransition that
  // animates it in/out. When "hidden" the widget STAYS MOUNTED and only
  // collapses to zero width (it never leaves the tree), so `findsNothing` is
  // the wrong assertion. Instead: still present, but collapsed to width 0
  // (and therefore not tappable).
  final quickActionsKey = find.byKey(const Key('input-bar-quick-actions'));

  void expectCollapsed(WidgetTester tester) {
    expect(quickActionsKey, findsOneWidget,
        reason: 'stays mounted — SizeTransition collapses size, not the tree');
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(tester.getSize(sizeTransition).width, 0,
        reason: 'collapsed to zero width when hidden');
  }

  void expectExpanded(WidgetTester tester) {
    expect(quickActionsKey, findsOneWidget);
    final sizeTransition = find.ancestor(
      of: quickActionsKey,
      matching: find.byType(SizeTransition),
    );
    expect(tester.getSize(sizeTransition).width, greaterThan(0),
        reason: 'fully expanded when visible');
  }

  testWidgets('quick actions button is visible when input is empty',
      (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectExpanded(tester);
  });

  testWidgets('quick actions button hides (collapses) while typing',
      (tester) async {
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

  testWidgets('quick actions button hides (collapses) when disabled',
      (tester) async {
    await pumpBar(
      tester,
      disabled: true,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
  });

  testWidgets('quick actions button hides (collapses) while streaming',
      (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    await tester.pumpAndSettle();
    expectCollapsed(tester);
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

  testWidgets('quick actions button hidden when callback is null',
      (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
    );
    expect(find.byKey(const Key('input-bar-quick-actions')), findsNothing);
  });
}
