// Plan/30 — InputBar image wiring: attach button gating by vision, preview +
// remove, send-with-image. Drives a real AttachmentViewModel + fakes.

import 'dart:async';
import 'dart:convert';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:app/ui/chat/widgets/input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

// 1×1 transparent PNG so Image.memory decodes cleanly in the test env.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
);

class _FakePicker implements IImagePickerService {
  PickedImage next = PickedImage(bytes: _pngBytes, mime: 'image/jpeg');
  @override
  Future<PickedImage?> pickFromCamera() async => next;
  @override
  Future<PickedImage?> pickFromGallery() async => next;
  @override
  Future<List<PickedImage>?> pickMultipleFromGallery() async => [next];
}

class _FakeAnyPicker implements IAnyFilePickerService {
  PickedFile? next = const TextFilePick(
    name: 'server.log',
    file: PickedTextFile(name: 'server.log', text: 'line1\n', byteLength: 6),
  );
  @override
  Future<PickedFile?> pickFile() async => next;
  @override
  Future<List<PickedFile>?> pickFiles() async =>
      next == null ? null : [next!];
}

class _FakeUploads implements IUploadService {
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

/// Reports the whole file as written and never answers: every byte is queued in
/// the socket while the Pi has not confirmed, which is the state that used to
/// look like a finished (and mysteriously disabled) upload.
class _PendingUploads implements IUploadService {
  @override
  Future<UploadedFile> upload({
    required String path,
    required String name,
    String? room,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
    Duration reconnectTimeout = uploadReconnectTimeout,
    Duration ackTimeout = uploadAckTimeout,
    Duration sendTimeout = uploadSendTimeout,
  }) async {
    // Mirrors the real service, which writes its start frame (an await) before
    // the first progress tick — that hop is also what lets the tray exist.
    await Future<void>.microtask(() {});
    onProgress?.call(10, 10);
    return Completer<UploadedFile>().future; // the Pi never answers
  }
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  final _ctrl = StreamController<ActiveRoomMeta>.broadcast();
  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async =>
      catalogue;
  @override
  ActiveRoomMeta get activeRoomMeta => const ActiveRoomMeta();
  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _ctrl.stream;
  @override
  void dispose() => _ctrl.close();
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _m(bool vision) => WireModel(
  id: 'id',
  name: 'M',
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  late _FakePicker picker;
  late _FakeActions actions;
  late AttachmentViewModel vm;

  setUp(() {
    picker = _FakePicker();
    actions = _FakeActions();
    vm = AttachmentViewModel(picker, _FakeAnyPicker(), _FakeUploads(), actions);
  });

  tearDown(() => vm.dispose());

  Future<void> pumpBar(
    WidgetTester tester, {
    bool channelOpen = true,
    AttachmentViewModel? viewModel,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: InputBar(
              onSend: (text) {},
              attachment: viewModel ?? vm,
              onOpenAttach: channelOpen ? () {} : null,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('attach button is present and enabled by default', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.pump();
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    expect(btn.onPressed, isNotNull);
  });

  testWidgets('vision=false keeps the attach button live — only the image sources grey out (#9)', (
    tester,
  ) async {
    actions.catalogue = ModelsCatalogue(
      models: [_m(false)],
      current: _m(false),
    );
    // Recreate after the catalogue is set so the VM resolves vision=false.
    vm = AttachmentViewModel(picker, _FakeAnyPicker(), _FakeUploads(), actions);
    await pumpBar(tester);
    await tester.pump(); // resolve vision
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    // A text file is fine on any model, so the entry point stays reachable;
    // the sheet greys out Camera / Photo Library.
    expect(btn.onPressed, isNotNull);
    expect(vm.imageBlockedByVision, isTrue);
  });

  testWidgets('offline (null onOpenAttach) disables the attach button', (
    tester,
  ) async {
    await pumpBar(tester, channelOpen: false);
    await tester.pump();
    final btn = tester.widget<IconButton>(
      find.byKey(const Key('input-bar-attach')),
    );
    expect(btn.onPressed, isNull);
  });

  testWidgets('a working turn keeps the attach button live', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: InputBar(
              onSend: (text) {},
              streaming: true,
              attachment: vm,
              onOpenAttach: () {},
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('input-bar-attach')))
          .onPressed,
      isNotNull,
      reason: 'the pick must be reachable mid-turn so it can steer',
    );
  });

  testWidgets(
    'steering an attachment mid-turn sends it instead of cancelling',
    (tester) async {
      MessageImage? sentImage;
      OutgoingFile? sentFile;
      String? sentText;
      var cancelled = 0;
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: InputBar(
                streaming: true,
                attachment: vm,
                onOpenAttach: () => opened++,
                onCancel: () => cancelled++,
                onSend: (text) {
                  sentText = text;
                  final sent = vm.takeForSend(); // mirrors chat_page wiring
                  sentImage = sent.images.isEmpty ? null : sent.images.first;
                  sentFile = sent.files.isEmpty ? null : sent.files.first;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Through the paperclip, not straight to the VM: opening the sheet is
      // exactly what the removed streaming gate used to refuse.
      await tester.tap(find.byKey(const Key('input-bar-attach')));
      await tester.pump();
      expect(opened, 1, reason: 'the paperclip itself must be live mid-turn');

      await vm.pickFromGallery();
      await tester.pumpAndSettle(); // let the send icon's switcher settle
      expect(find.byKey(const Key('attach-preview')), findsOneWidget);
      expect(find.byIcon(LucideIcons.send600), findsOneWidget);
      expect(
        find.byKey(const Key('input-bar-inline-stop')),
        findsOneWidget,
        reason: 'Stop stays reachable while the pick steers',
      );

      await tester.tap(find.byIcon(LucideIcons.send600));
      await tester.pump();

      expect(cancelled, 0);
      expect(sentText, '');
      expect(sentImage, isNotNull);
      expect(sentImage!.mime, 'image/jpeg');
      expect(sentFile, isNull);
    },
  );

  testWidgets(
    'a binary whose bytes are all sent but unconfirmed says it is waiting, '
    'instead of showing a full bar that looks finished',
    (tester) async {
      final pending = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker()
          ..next = const BinaryFilePick(
            name: 'deck.pdf',
            path: '/sdcard/deck.pdf',
            size: 4096,
          ),
        _PendingUploads(),
        actions,
      );
      addTearDown(pending.dispose);
      await pumpBar(tester, viewModel: pending);
      await tester.pump();

      await pending.pickFile();
      await tester.pump();

      expect(find.byKey(const Key('attach-binary-preview')), findsOneWidget);
      expect(
        find.text('sent — waiting for the PC to confirm'),
        findsOneWidget,
        reason: 'the transfer is queued, not done',
      );
      expect(find.text('ready — sends with your message'), findsNothing);
    },
  );

  testWidgets('picking shows the preview + send icon; X removes it', (
    tester,
  ) async {
    await pumpBar(tester);
    await tester.pump();

    await vm.pickFromGallery();
    await tester.pump();

    expect(find.byKey(const Key('attach-preview')), findsOneWidget);
    expect(find.byIcon(LucideIcons.send600), findsOneWidget); // send-mode (#6)
    // Plan/63 — the tray holds several items, so the paperclip stays live
    // even while an image is attached.
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('input-bar-attach')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('attach-remove')));
    await tester.pump();
    expect(find.byKey(const Key('attach-preview')), findsNothing);
  });

  for (final streaming in [false, true]) {
    testWidgets(
      'a picked text file previews as a chip and is dispatchable'
      '${streaming ? ' mid-turn' : ''}',
      (tester) async {
        MessageImage? sentImage;
        OutgoingFile? sentFile;
        String? sentText;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: InputBar(
                  streaming: streaming,
                  attachment: vm,
                  onOpenAttach: () {},
                  onCancel: streaming ? () {} : null,
                  onSend: (text) {
                    sentText = text;
                    final sent = vm.takeForSend(); // mirrors chat_page wiring
                    sentImage = sent.images.isEmpty ? null : sent.images.first;
                    sentFile = sent.files.isEmpty ? null : sent.files.first;
                  },
                ),
              ),
            ),
          ),
        );
        await tester.pump();

        await vm.pickFile();
        await tester.pump();

        expect(find.byKey(const Key('attach-file-preview')), findsOneWidget);
        expect(find.text('server.log'), findsOneWidget);
        expect(find.byKey(const Key('attach-preview')), findsNothing);

        await tester.tap(find.byIcon(LucideIcons.send600));
        await tester.pump();

        expect(sentText, '');
        expect(sentImage, isNull);
        expect(sentFile?.name, 'server.log');
        expect(sentFile?.text, 'line1\n');
        expect(find.byKey(const Key('attach-file-preview')), findsNothing);
      },
    );
  }

  testWidgets(
    'send with an attached image + empty caption dispatches the image',
    (tester) async {
      MessageImage? sent;
      String? sentText;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: InputBar(
                attachment: vm,
                onOpenAttach: () {},
                onSend: (text) {
                  sentText = text;
                  final images = vm.takeForSend().images;
                  sent = images.isEmpty ? null : images.first;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await vm.pickFromGallery();
      await tester.pumpAndSettle(); // let the send icon's switcher settle

      await tester.tap(find.byIcon(LucideIcons.send600));
      await tester.pump();

      expect(sentText, '');
      expect(sent, isNotNull);
      expect(sent!.mime, 'image/jpeg');
    },
  );
}
