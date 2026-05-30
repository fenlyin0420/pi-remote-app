// Plan 29 — InputBar hold-to-talk wiring: long-press shows the strip, release
// transcribes into the field, slide-to-cancel discards, tap nudges, and the
// unavailable states hide/keep the mic.

import 'dart:async';

import 'package:app/data/voice/speech_service.dart';
import 'package:app/ui/chat/voice/viewmodels/voice_input_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class _FakeSpeechService implements SpeechService {
  SpeechAvailability availability = const SpeechReady('en_US');
  String transcript = 'hello from voice';
  final StreamController<double> _level = StreamController<double>.broadcast();

  @override
  Future<SpeechAvailability> init({String? preferredLocaleId}) async =>
      availability;
  @override
  Stream<double> get soundLevel => _level.stream;
  @override
  Future<void> start({
    required String localeId,
    required Duration maxDuration,
  }) async {}
  @override
  Future<String> stop() async => transcript;
  @override
  Future<void> cancel() async {}
  @override
  void dispose() => _level.close();
}

void main() {
  late _FakeSpeechService svc;
  late VoiceInputViewModel vm;
  late List<VoiceHint> hints;

  setUp(() {
    svc = _FakeSpeechService();
    vm = VoiceInputViewModel(svc, maxDuration: const Duration(seconds: 60));
    hints = [];
  });

  tearDown(() => vm.dispose());

  Future<void> pumpBar(WidgetTester tester) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: InputBar(onSend: (_) {}, voice: vm, onVoiceHint: hints.add),
          ),
        ),
      ),
    );
  }

  Future<TestGesture> startHold(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byIcon(LucideIcons.mic)),
    );
    // Exceed kLongPressTimeout (500ms) so onLongPressStart fires.
    await tester.pump(const Duration(milliseconds: 700));
    // Let the VM's async init/start settle and the strip appear.
    await tester.pump();
    await tester.pump();
    return gesture;
  }

  testWidgets('mic is shown when voice is ready and field is empty', (
    tester,
  ) async {
    await pumpBar(tester);
    expect(find.byIcon(LucideIcons.mic), findsOneWidget);
  });

  testWidgets('hold shows the recording strip; release fills the field', (
    tester,
  ) async {
    await pumpBar(tester);
    final gesture = await startHold(tester);
    expect(find.byKey(const Key('recording-strip')), findsOneWidget);

    await gesture.up();
    await tester.pump(); // onLongPressEnd → stopAndTranscribe
    await tester.pump(); // transcript stream → controller.text
    await tester.pump();

    expect(find.byKey(const Key('recording-strip')), findsNothing);
    expect(find.text('hello from voice'), findsOneWidget);
    // Field now has text → action button is the send affordance.
    expect(find.byIcon(LucideIcons.send), findsOneWidget);
  });

  testWidgets('slide-to-cancel discards — field stays empty, mic returns', (
    tester,
  ) async {
    await pumpBar(tester);
    final gesture = await startHold(tester);
    expect(find.byKey(const Key('recording-strip')), findsOneWidget);

    await gesture.moveBy(const Offset(-150, 0)); // past the 90px threshold
    await tester.pump();
    expect(find.text('release to cancel'), findsOneWidget);

    await gesture.up();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const Key('recording-strip')), findsNothing);
    expect(find.text('hello from voice'), findsNothing);
    expect(find.byIcon(LucideIcons.mic), findsOneWidget);
  });

  testWidgets('a plain tap nudges with the hold-to-talk hint', (tester) async {
    await pumpBar(tester);
    await tester.tap(find.byIcon(LucideIcons.mic));
    await tester.pump();
    expect(hints, [VoiceHint.holdToTalk]);
  });

  testWidgets('unsupported hides the mic', (tester) async {
    svc.availability = const SpeechUnsupported();
    await pumpBar(tester);
    // Resolve availability (mirrors the first interaction's init).
    await vm.ensureInit();
    await tester.pump();
    expect(find.byIcon(LucideIcons.mic), findsNothing);
  });

  testWidgets('permission denied keeps the mic and surfaces the hint', (
    tester,
  ) async {
    svc.availability = const SpeechPermissionDenied();
    await pumpBar(tester);
    final gesture = await startHold(tester);

    expect(hints, contains(VoiceHint.permissionDenied));
    // Mic stays visible (#10) and no strip is shown.
    expect(find.byIcon(LucideIcons.mic), findsOneWidget);
    expect(find.byKey(const Key('recording-strip')), findsNothing);

    await gesture.up();
    await tester.pump();
  });
}
