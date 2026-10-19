// LOCAL (fenlyin): the model sub-picker marks the RUNNING model with a circled
// check on the right, and every row keeps naming its provider.

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:app/ui/chat/quick_actions/widgets/model_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

const _opus = WireModel(
  id: 'claude-opus-4-7',
  name: 'Claude Opus 4.7',
  provider: 'anthropic',
  reasoning: true,
  contextWindow: 200000,
);

const _sonnet = WireModel(
  id: 'claude-sonnet-4-6',
  name: 'Claude Sonnet 4.6',
  provider: 'anthropic',
  reasoning: false,
  contextWindow: 200000,
);

class _FakeRepo implements IActionsRepository {
  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream =>
      const Stream<ActiveRoomMeta>.empty();

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      const ModelsCatalogue(models: [_opus, _sonnet], current: _opus);

  @override
  Future<void> compact() async {}

  @override
  Future<void> newSession() async {}

  @override
  Future<void> setModel(String provider, String modelId) async {}

  @override
  Future<void> setThinking(ThinkingLevel level) async {}

  @override
  Future<void> runCommand(String text) async {}

  @override
  Future<void> runBash(String command, {bool excludeFromContext = false}) async {}

  @override
  Future<List<WireCommand>> listCommands({bool forceRefresh = false}) async =>
      const [];

  @override
  Future<void> createRoom(
    String path, {
    bool createIfMissing = false,
    String? name,
  }) async {}

  @override
  Future<void> deleteRoom(String path, {String? name}) async {}

  @override
  Future<List<WireSession>> listSessions() async => const [];

  @override
  Future<void> switchSession(String session) async {}

  @override
  void dispose() {}
}

Future<void> _openPicker(WidgetTester tester) async {
  final vm = QuickActionsViewModel(_FakeRepo());
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () => showModelPickerSheet(ctx, vm: vm),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the running model gets a circled check — only that one', (
    tester,
  ) async {
    await _openPicker(tester);

    expect(find.text('Claude Opus 4.7'), findsOneWidget);
    expect(find.text('Claude Sonnet 4.6'), findsOneWidget);
    expect(find.byIcon(LucideIcons.circleCheck), findsOneWidget);
    // The bare check is gone — the marker is the circled one.
    expect(find.byIcon(LucideIcons.check), findsNothing);
    // Every row still names its provider in the subtitle.
    expect(find.text('anthropic · ctx 200k'), findsNWidgets(2));
  });
}
