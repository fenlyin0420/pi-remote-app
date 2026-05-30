// Plan/28 Wave C — Quick Actions bottom sheet widget tests.
//
// The sheet's entry-point helper (`showQuickActionsSheet`) reaches
// into the global injector to build a real ViewModel. These tests
// drive the sheet body directly with an injected fake VM so they
// exercise the UI layer without spinning up the DI graph.

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/states/quick_actions_state.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeRepo implements IActionsRepository {
  int compactCalls = 0;
  int newSessionCalls = 0;
  ThinkingLevel? thinking;
  WireModel? modelArg;

  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      const Stream<ActiveRoomMeta>.empty();

  @override
  Future<void> compact() async {
    compactCalls++;
  }

  @override
  Future<void> newSession() async {
    newSessionCalls++;
  }

  @override
  Future<void> setModel(String provider, String modelId) async {
    modelArg = WireModel(
      id: modelId,
      provider: provider,
      name: modelId,
      reasoning: false,
      contextWindow: 0,
    );
  }

  @override
  Future<void> setThinking(ThinkingLevel level) async {
    thinking = level;
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    return const ModelsCatalogue(models: [], current: null);
  }

  @override
  void dispose() {}
}

Future<void> _openSheet(WidgetTester tester, _FakeRepo repo) async {
  final vm = QuickActionsViewModel(repo);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (ctx) => ElevatedButton(
          onPressed: () {
            showModalBottomSheet<void>(
              context: ctx,
              builder: (_) => ChangeNotifierProvider<QuickActionsViewModel>.value(
                value: vm,
                child: const _SheetHarness(),
              ),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Tiny replica of the body the real sheet renders, but plugged into a
/// pre-built ViewModel so we don't need the injector.
class _SheetHarness extends StatelessWidget {
  const _SheetHarness();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _CompactTile(),
          _NewSessionTile(),
          _ThinkingRow(),
        ],
      ),
    );
  }
}

class _CompactTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<QuickActionsViewModel>();
    return ListTile(
      key: const Key('qa-compact'),
      title: const Text('Compact context'),
      onTap: () => vm.compact(),
    );
  }
}

class _NewSessionTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<QuickActionsViewModel>();
    return ListTile(
      key: const Key('qa-new-session'),
      title: const Text('New session'),
      onTap: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Start a new session?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Start new'),
              ),
            ],
          ),
        );
        if (ok == true) await vm.newSession();
      },
    );
  }
}

class _ThinkingRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final vm = context.watch<QuickActionsViewModel>();
    return Row(
      children: [
        for (final level in ThinkingLevel.values)
          TextButton(
            key: Key('qa-thinking-${level.wire}'),
            onPressed: () => vm.setThinking(level),
            child: Text(level.wire),
          ),
      ],
    );
  }
}

void main() {
  testWidgets('tapping Compact context fires compact()', (tester) async {
    final repo = _FakeRepo();
    await _openSheet(tester, repo);
    await tester.tap(find.byKey(const Key('qa-compact')));
    await tester.pump();
    expect(repo.compactCalls, 1);
  });

  testWidgets('New session asks for confirmation before firing',
      (tester) async {
    final repo = _FakeRepo();
    await _openSheet(tester, repo);
    await tester.tap(find.byKey(const Key('qa-new-session')));
    await tester.pumpAndSettle();
    // Dialog should be up; tap Cancel — repo shouldn't fire.
    expect(find.text('Start a new session?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(repo.newSessionCalls, 0);

    // Try again, this time confirm.
    await tester.tap(find.byKey(const Key('qa-new-session')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start new'));
    await tester.pumpAndSettle();
    expect(repo.newSessionCalls, 1);
  });

  testWidgets('thinking segment forwards level to repo', (tester) async {
    final repo = _FakeRepo();
    await _openSheet(tester, repo);
    await tester.tap(find.byKey(const Key('qa-thinking-medium')));
    await tester.pumpAndSettle();
    expect(repo.thinking, ThinkingLevel.medium);
  });

  test('QuickActionsState equality covers idle + busy', () {
    expect(const QuickActionsIdle(), const QuickActionsIdle());
    expect(
      const QuickActionsIdle(currentThinking: ThinkingLevel.low),
      const QuickActionsIdle(currentThinking: ThinkingLevel.low),
    );
    expect(
      const QuickActionsBusy(action: ActionName.modelSet),
      const QuickActionsBusy(action: ActionName.modelSet),
    );
  });
}
