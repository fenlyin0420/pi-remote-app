// Plan/63 — the todo pill (pi-todo's list floated over the transcript).
//
// The pill is the only always-visible affordance: `done/total`, expanding to a
// card of rows on tap and collapsing on a second tap. No list → no widget at
// all, which is what a Pi without pi-todo reports.

import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/widgets/todo_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

void main() {
  TodoState list(List<TodoTask> tasks) => TodoState(tasks: tasks);

  TodoTask task(
    int id,
    String subject,
    TodoTaskStatus status, {
    String? activeForm,
    List<int> blockedBy = const [],
  }) => TodoTask(
    id: id,
    subject: subject,
    status: status,
    activeForm: activeForm,
    blockedBy: blockedBy,
  );

  Future<void> pump(WidgetTester tester, TodoState todos) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: TodoPanel(todos: todos),
          ),
        ),
      ),
    );
  }

  testWidgets('renders nothing without a list', (tester) async {
    await pump(tester, const TodoState());
    expect(find.byKey(const Key('todo-pill')), findsNothing);
    expect(find.byKey(const Key('todo-card')), findsNothing);
  });

  testWidgets('the pill carries done/total and starts collapsed', (tester) async {
    await pump(
      tester,
      list([
        task(1, 'Research', TodoTaskStatus.completed),
        task(2, 'Implement', TodoTaskStatus.inProgress, activeForm: 'writing tests'),
        task(3, 'Ship', TodoTaskStatus.pending),
      ]),
    );

    expect(find.byKey(const Key('todo-pill')), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    // Collapsed: no rows until the pill is tapped.
    expect(find.byKey(const Key('todo-card')), findsNothing);
    expect(find.text('Research'), findsNothing);
  });

  testWidgets('tapping the pill expands the rows, tapping again collapses', (
    tester,
  ) async {
    await pump(
      tester,
      list([
        task(1, 'Research', TodoTaskStatus.completed),
        task(2, 'Implement', TodoTaskStatus.inProgress, activeForm: 'writing tests'),
        task(3, 'Ship', TodoTaskStatus.pending),
      ]),
    );

    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-card')), findsOneWidget);
    expect(find.text('Research'), findsOneWidget);
    expect(find.text('Implement'), findsOneWidget);
    expect(find.text('Ship'), findsOneWidget);
    // The in-progress label rides under its row.
    expect(find.text('writing tests'), findsOneWidget);

    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-card')), findsNothing);
    expect(find.text('Implement'), findsNothing);
  });

  testWidgets('rows are ordered in progress → pending → done', (tester) async {
    await pump(
      tester,
      list([
        task(1, 'Done thing', TodoTaskStatus.completed),
        task(2, 'Queued thing', TodoTaskStatus.pending),
        task(3, 'Running thing', TodoTaskStatus.inProgress),
      ]),
    );
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();

    final running = tester.getTopLeft(find.text('Running thing')).dy;
    final queued = tester.getTopLeft(find.text('Queued thing')).dy;
    final done = tester.getTopLeft(find.text('Done thing')).dy;
    expect(running, lessThan(queued));
    expect(queued, lessThan(done));
  });

  testWidgets('blocked rows show their dependencies', (tester) async {
    await pump(tester, list([task(4, 'Later', TodoTaskStatus.pending, blockedBy: [1, 2])]));
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();
    expect(find.text('blocked by #1, #2'), findsOneWidget);
  });

  testWidgets('a list emptied while open drops the card and then the pill', (
    tester,
  ) async {
    var todos = list([task(1, 'Ship', TodoTaskStatus.pending)]);
    late StateSetter setOuter;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setOuter = setState;
              return Align(
                alignment: Alignment.topRight,
                child: TodoPanel(todos: todos),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-card')), findsOneWidget);

    // Same widget, now an empty list: the card must not linger.
    setOuter(() => todos = const TodoState());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('todo-card')), findsNothing);
    expect(find.byKey(const Key('todo-pill')), findsNothing);
  });

  testWidgets('the counter tracks a growing list', (tester) async {
    await pump(tester, list([task(1, 'One', TodoTaskStatus.completed)]));
    expect(find.text('1/1'), findsOneWidget);
    await pump(
      tester,
      list([
        task(1, 'One', TodoTaskStatus.completed),
        task(2, 'Two', TodoTaskStatus.completed),
        task(3, 'Three', TodoTaskStatus.pending),
      ]),
    );
    expect(find.text('2/3'), findsOneWidget);
  });

  testWidgets('the pill reaches Material\'s minimum touch target', (
    tester,
  ) async {
    await pump(tester, list([task(1, 'One', TodoTaskStatus.pending)]));
    expect(
      tester.getSize(find.byKey(const Key('todo-pill'))).height,
      greaterThanOrEqualTo(44),
    );
  });

  testWidgets('the pill shows a chevron so the tap target is discoverable', (
    tester,
  ) async {
    await pump(tester, list([task(1, 'One', TodoTaskStatus.pending)]));
    expect(find.byIcon(LucideIcons.chevronDown), findsOneWidget);
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();
    expect(find.byIcon(LucideIcons.chevronUp), findsOneWidget);
    expect(find.byIcon(LucideIcons.chevronDown), findsNothing);
  });

  testWidgets('the card unfolds BELOW the pill (the panel is top-anchored)', (
    tester,
  ) async {
    await pump(tester, list([task(1, 'One', TodoTaskStatus.pending)]));
    final pillBottom = tester.getBottomLeft(find.byKey(const Key('todo-pill'))).dy;

    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();

    final cardTop = tester.getTopLeft(find.byKey(const Key('todo-card'))).dy;
    expect(
      cardTop,
      greaterThanOrEqualTo(pillBottom),
      reason: 'a top-anchored pill must not push the card off the top edge',
    );
  });

  testWidgets('rows expose their status to a screen reader', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      list([
        task(1, 'Research', TodoTaskStatus.completed),
        task(2, 'Implement', TodoTaskStatus.inProgress, activeForm: 'writing tests'),
      ]),
    );
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Research, completed'), findsOneWidget);
    expect(find.bySemanticsLabel('Implement, in progress'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a short card budget keeps the header and scrolls the rows', (
    tester,
  ) async {
    // The transcript is ~200dp in landscape (or with the keyboard up): the host
    // passes that budget down, and the card must live inside it instead of
    // being clipped with no warning.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: TodoPanel(
              todos: list([
                for (var i = 1; i <= 12; i += 1)
                  task(i, 'Row $i', TodoTaskStatus.pending),
              ]),
              maxCardHeight: 120,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('todo-pill-tap')));
    await tester.pumpAndSettle();

    final card = tester.getSize(find.byKey(const Key('todo-card')));
    expect(card.height, lessThanOrEqualTo(120));
    // The header (and so the count) stays on screen; the rows scroll under it.
    expect(find.text('TODOS'), findsOneWidget);
    expect(find.text('0/12'), findsNWidgets(2));
  });
}
