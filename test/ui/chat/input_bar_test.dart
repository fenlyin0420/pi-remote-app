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

  testWidgets('quick actions button is visible when input is empty',
      (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    expect(find.byKey(const Key('input-bar-quick-actions')), findsOneWidget);
  });

  testWidgets('quick actions button hides while typing', (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: false,
      onOpenQuickActions: () {},
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.byKey(const Key('input-bar-quick-actions')), findsNothing);
  });

  testWidgets('quick actions button hides when disabled', (tester) async {
    await pumpBar(
      tester,
      disabled: true,
      streaming: false,
      onOpenQuickActions: () {},
    );
    expect(find.byKey(const Key('input-bar-quick-actions')), findsNothing);
  });

  testWidgets('quick actions button hides while streaming', (tester) async {
    await pumpBar(
      tester,
      disabled: false,
      streaming: true,
      onOpenQuickActions: () {},
    );
    expect(find.byKey(const Key('input-bar-quick-actions')), findsNothing);
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
