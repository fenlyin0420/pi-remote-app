// Plan/30 + Plan/62 — AttachmentViewModel: pick / remove / take + vision
// gating + chunked binary upload, against fake picker + upload + actions
// repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? next = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );
  bool denyCamera = false;
  bool fail = false;

  @override
  Future<PickedImage?> pickFromCamera() async {
    if (denyCamera) throw const ImagePermissionDeniedException();
    if (fail) throw Exception('boom');
    return next;
  }

  @override
  Future<PickedImage?> pickFromGallery() async {
    if (fail) throw Exception('boom');
    return next;
  }
}

class _FakeAnyPicker implements IAnyFilePickerService {
  PickedFile? next = const TextFilePick(
    name: 'notes.md',
    file: PickedTextFile(name: 'notes.md', text: '# hi', byteLength: 4),
  );
  bool tooLarge = false;

  @override
  Future<PickedFile?> pickFile() async {
    if (tooLarge) {
      throw const FileTooLargeException('big.zip', 251 * 1024 * 1024);
    }
    return next;
  }
}

class _FakeUploads implements IUploadService {
  UploadedFile? result;
  UploadError? error;
  final List<String> uploads = [];

  @override
  Future<UploadedFile> upload({
    required String path,
    required String name,
    void Function(int sent, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    uploads.add(name);
    if (error != null) throw error!;
    onProgress?.call(5, 10);
    return result ??
        const UploadedFile(name: 'deck.pdf', path: '/uploads/room/deck.pdf');
  }
}

class _FakeActions implements IActionsRepository {
  ModelsCatalogue catalogue = const ModelsCatalogue(models: [], current: null);
  ActiveRoomMeta meta = const ActiveRoomMeta();
  final _metaCtrl = StreamController<ActiveRoomMeta>.broadcast();
  bool offline = false;

  void pushMeta(ActiveRoomMeta m) {
    meta = m;
    _metaCtrl.add(m);
  }

  @override
  Future<ModelsCatalogue> listModels({bool forceRefresh = false}) async {
    if (offline) throw const ActionFailure('offline');
    return catalogue;
  }

  @override
  ActiveRoomMeta get activeRoomMeta => meta;

  @override
  Stream<ActiveRoomMeta> get activeRoomMetaStream => _metaCtrl.stream;

  @override
  void dispose() => _metaCtrl.close();

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

WireModel _model({required bool vision, String name = 'M'}) => WireModel(
  id: 'id-$name',
  name: name,
  provider: 'p',
  reasoning: false,
  contextWindow: 1,
  vision: vision,
);

void main() {
  test('pickFromGallery attaches an image; removeImage clears it', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFromGallery();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasImage, isTrue);

    vm.removeAttachment();
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.hasImage, isFalse);
    vm.dispose();
  });

  test('takeImageForSend returns base64 MessageImage and resets', () async {
    final picker = _FakePicker()
      ..next = PickedImage(
        bytes: Uint8List.fromList([10, 20, 30]),
        mime: 'image/jpeg',
      );
    final vm = AttachmentViewModel(picker, _FakeAnyPicker(), _FakeUploads(), _FakeActions());
    await vm.pickFromGallery();

    final msg = vm.takeImageForSend();
    expect(msg, isNotNull);
    expect(msg!.mime, 'image/jpeg');
    expect(base64Decode(msg.data), [10, 20, 30]);
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeImageForSend(), isNull); // nothing left
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(picker, _FakeAnyPicker(), _FakeUploads(), _FakeActions());
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFromCamera();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.cameraPermissionDenied]);
    await sub.cancel();
    vm.dispose();
  });

  test('vision=false from catalogue blocks the attach affordance', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeAnyPicker(), _FakeUploads(), actions);
    await Future<void>.delayed(Duration.zero); // let init resolve vision

    expect(vm.state.visionSupported, isFalse);
    expect(vm.imageBlockedByVision, isTrue);
    vm.dispose();
  });

  test('vision=true does not block', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeAnyPicker(), _FakeUploads(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isTrue);
    expect(vm.imageBlockedByVision, isFalse);
    vm.dispose();
  });

  test('offline catalogue leaves vision unknown (does not block)', () async {
    final actions = _FakeActions()..offline = true;
    final vm = AttachmentViewModel(_FakePicker(), _FakeAnyPicker(), _FakeUploads(), actions);
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isNull);
    expect(vm.imageBlockedByVision, isFalse);
    vm.dispose();
  });

  test('a model change re-resolves vision', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: true)],
        current: _model(vision: true),
      );
    final vm = AttachmentViewModel(_FakePicker(), _FakeAnyPicker(), _FakeUploads(), actions);
    await Future<void>.delayed(Duration.zero);
    expect(vm.state.visionSupported, isTrue);

    // Pi switched to a text-only model.
    actions.catalogue = ModelsCatalogue(
      models: [_model(vision: false, name: 'TextOnly')],
      current: _model(vision: false, name: 'TextOnly'),
    );
    actions.pushMeta(const ActiveRoomMeta(model: 'TextOnly'));
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isFalse);
    vm.dispose();
  });

  test('pickFile attaches a text file; the file never counts as an image', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFile();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasAttachment, isTrue);
    expect(vm.hasImage, isFalse);
    expect((vm.state as AttachmentAttached).file?.name, 'notes.md');
    vm.dispose();
  });

  test('takeFileForSend returns the outgoing file with its text and resets', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFile();

    final file = vm.takeFileForSend();
    expect(file, isNotNull);
    expect(file!.name, 'notes.md');
    expect(file.text, '# hi');
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeFileForSend(), isNull); // nothing left
    vm.dispose();
  });

  test(
    'a binary pick attaches and lands: upload runs on pick, '
    'takeFileForSend references the landed path',
    () async {
      final uploads = _FakeUploads();
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker()
          ..next = const BinaryFilePick(
            name: 'deck.pdf',
            path: '/sdcard/deck.pdf',
            size: 4096,
          ),
        uploads,
        _FakeActions(),
      );
      await vm.pickFile();

      // The preview is up immediately (progress while the upload streams).
      expect(vm.state, isA<AttachmentAttached>());
      final binary = (vm.state as AttachmentAttached).binaryFile;
      expect(binary, isNotNull);
      expect(binary!.name, 'deck.pdf');
      expect(binary.size, 4096);

      await Future<void>.delayed(Duration.zero); // let the fake upload land

      final landed = (vm.state as AttachmentAttached).binaryFile!;
      expect(landed.landed, isTrue);
      expect(landed.landedPath, '/uploads/room/deck.pdf');
      expect(uploads.uploads, ['deck.pdf']);

      final file = vm.takeFileForSend();
      expect(file, isNotNull);
      expect(file!.name, 'deck.pdf');
      expect(file.text, isNull);
      expect(file.path, '/uploads/room/deck.pdf');
      expect(vm.state, isA<AttachmentEmpty>());
      vm.dispose();
    },
  );

  test(
    'a binary pick while the upload is in flight: takeFileForSend is null '
    'until the Pi confirms',
    () async {
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker()
          ..next = const BinaryFilePick(
            name: 'deck.pdf',
            path: '/sdcard/deck.pdf',
            size: 4096,
          ),
        _FakeUploads()..error = const UploadError('timeout', 'slow'),
        _FakeActions(),
      );
      await vm.pickFile();
      // Not landed yet — the fake upload throws, but the first emit
      // (progress) is already visible.
      expect(vm.takeFileForSend(), isNull);
      await Future<void>.delayed(Duration.zero);
      vm.dispose();
    },
  );

  test('a failed upload drops the attachment with an uploadFailed hint', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker()
        ..next = const BinaryFilePick(
          name: 'deck.pdf',
          path: '/sdcard/deck.pdf',
          size: 4096,
        ),
      _FakeUploads()
        ..error = const UploadError('upload_hash_mismatch', 'hash mismatch'),
      _FakeActions(),
    );
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFile();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.uploadFailed]);
    await sub.cancel();
    vm.dispose();
  });

  test('a too-large pick emits a fileTooLarge hint and stays empty', () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker()..tooLarge = true,
      _FakeUploads(),
      _FakeActions(),
    );
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFile();
    await Future<void>.delayed(Duration.zero);

    expect(vm.state, isA<AttachmentEmpty>());
    expect(hints, [AttachHint.fileTooLarge]);
    await sub.cancel();
    vm.dispose();
  });

  test('a text-only model still allows files (vision gates images only)', () async {
    final actions = _FakeActions()
      ..catalogue = ModelsCatalogue(
        models: [_model(vision: false)],
        current: _model(vision: false),
      );
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      actions,
    );
    await Future<void>.delayed(Duration.zero);

    expect(vm.imageBlockedByVision, isTrue);
    await vm.pickFile();
    expect(vm.state, isA<AttachmentAttached>());
    expect((vm.state as AttachmentAttached).file?.name, 'notes.md');
    vm.dispose();
  });
}
