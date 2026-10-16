// Plan/30 + 62 + 63 — AttachmentViewModel: pick / remove / take + vision
// gating + chunked binary upload + multi-item tray, against fake picker +
// upload + actions repositories.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/actions/actions_repository.dart';
import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/images/image_picker_service.dart';
import 'package:app/data/local/attachment_store.dart';
import 'package:app/data/local/boxes.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:hive/hive.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/attachment/states/attachment_state.dart';
import 'package:app/ui/chat/attachment/viewmodels/attachment_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakePicker implements IImagePickerService {
  PickedImage? next = PickedImage(
    bytes: Uint8List.fromList([1, 2, 3]),
    mime: 'image/jpeg',
  );

  /// Extra images returned after [next] by the multi pick (plan 63).
  List<PickedImage> extra = const [];
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

  @override
  Future<List<PickedImage>?> pickMultipleFromGallery() async {
    if (fail) throw Exception('boom');
    final first = next;
    if (first == null) return null;
    return [first, ...extra];
  }
}

class _FakeAnyPicker implements IAnyFilePickerService {
  List<PickedFile>? nexts = const [
    TextFilePick(
      name: 'notes.md',
      file: PickedTextFile(name: 'notes.md', text: '# hi', byteLength: 4),
    ),
  ];
  bool tooLarge = false;

  @override
  Future<PickedFile?> pickFile() async {
    if (tooLarge) {
      throw const FileTooLargeException('big.zip', 251 * 1024 * 1024);
    }
    return nexts?.first;
  }

  @override
  Future<List<PickedFile>?> pickFiles() async {
    if (tooLarge) {
      throw const FileTooLargeException('big.zip', 251 * 1024 * 1024);
    }
    return nexts;
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
    Duration reconnectTimeout = uploadReconnectTimeout,
    Duration ackTimeout = uploadAckTimeout,
    Duration sendTimeout = uploadSendTimeout,
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
  test('pickFromGallery attaches images; removeItem clears one chip',
      () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFromGallery();
    expect(vm.state, isA<AttachmentAttached>());
    expect(vm.hasImage, isTrue);
    expect((vm.state as AttachmentAttached).items, hasLength(1));

    vm.removeItem(0);
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.hasImage, isFalse);
    vm.dispose();
  });

  test('takeForSend returns base64 MessageImages and resets the tray',
      () async {
    final picker = _FakePicker()
      ..next = PickedImage(
        bytes: Uint8List.fromList([10, 20, 30]),
        mime: 'image/jpeg',
      );
    final vm = AttachmentViewModel(
      picker,
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFromGallery();

    final sent = vm.takeForSend();
    expect(sent.images, hasLength(1));
    expect(sent.images.single.mime, 'image/jpeg');
    expect(base64Decode(sent.images.single.data), [10, 20, 30]);
    expect(sent.files, isEmpty);
    expect(vm.state, isA<AttachmentEmpty>());
    final again = vm.takeForSend();
    expect(again.images, isEmpty); // nothing left
    expect(again.files, isEmpty);
    vm.dispose();
  });

  test('a multi-image pick lands one chip per image (plan 63)', () async {
    final picker = _FakePicker()
      ..extra = [
        PickedImage(
          bytes: Uint8List.fromList([4, 5]),
          mime: 'image/png',
        ),
      ];
    final vm = AttachmentViewModel(
      picker,
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFromGallery();

    final items = (vm.state as AttachmentAttached).items;
    expect(items, hasLength(2));
    expect(items, everyElement(isA<AttachedImage>()));

    // A second pick appends rather than replaces.
    await vm.pickFromGallery();
    expect((vm.state as AttachmentAttached).items, hasLength(4));

    final sent = vm.takeForSend();
    expect(sent.images, hasLength(4));
    vm.dispose();
  });

  test('denied camera permission emits a hint and stays empty', () async {
    final picker = _FakePicker()..denyCamera = true;
    final vm = AttachmentViewModel(
      picker,
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
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
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      actions,
    );
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
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      actions,
    );
    await Future<void>.delayed(Duration.zero);

    expect(vm.state.visionSupported, isTrue);
    expect(vm.imageBlockedByVision, isFalse);
    vm.dispose();
  });

  test('offline catalogue leaves vision unknown (does not block)', () async {
    final actions = _FakeActions()..offline = true;
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      actions,
    );
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
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      actions,
    );
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

  test('pickFile attaches a text file; the file never counts as an image',
      () async {
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
    final item = (vm.state as AttachmentAttached).items.single;
    expect(item, isA<AttachedTextFile>());
    expect((item as AttachedTextFile).file.name, 'notes.md');
    vm.dispose();
  });

  test('takeForSend returns the outgoing file with its text and resets',
      () async {
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker(),
      _FakeUploads(),
      _FakeActions(),
    );
    await vm.pickFile();

    final sent = vm.takeForSend();
    expect(sent.files, hasLength(1));
    expect(sent.files.single.name, 'notes.md');
    expect(sent.files.single.text, '# hi');
    expect(vm.state, isA<AttachmentEmpty>());
    expect(vm.takeForSend().files, isEmpty); // nothing left
    vm.dispose();
  });

  test(
    'a binary pick attaches and lands: upload runs on pick, '
    'takeForSend references the landed path',
    () async {
      final uploads = _FakeUploads();
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker()
          ..nexts = const [
            BinaryFilePick(name: 'deck.pdf', path: '/sdcard/deck.pdf', size: 4096),
          ],
        uploads,
        _FakeActions(),
      );
      await vm.pickFile();

      // The preview is up immediately (progress while the upload streams).
      final item = (vm.state as AttachmentAttached).items.single;
      final binary = item as AttachedBinaryFile;
      expect(binary.name, 'deck.pdf');
      expect(binary.size, 4096);
      expect(vm.anyUploading, isTrue,
          reason: 'the send stays gated while the upload is in flight');

      await Future<void>.delayed(Duration.zero); // let the fake upload land

      final landed =
          ((vm.state as AttachmentAttached).items.single as AttachedBinaryFile);
      expect(landed.landed, isTrue);
      expect(landed.landedPath, '/uploads/room/deck.pdf');
      expect(uploads.uploads, ['deck.pdf']);
      expect(vm.anyUploading, isFalse);

      final sent = vm.takeForSend();
      expect(sent.files, hasLength(1));
      expect(sent.files.single.name, 'deck.pdf');
      expect(sent.files.single.text, isNull);
      expect(sent.files.single.path, '/uploads/room/deck.pdf');
      expect(vm.state, isA<AttachmentEmpty>());
      vm.dispose();
    },
  );

  test(
    'a binary pick while the upload is in flight: takeForSend has no file '
    'until the Pi confirms',
    () async {
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker()
          ..nexts = const [
            BinaryFilePick(name: 'deck.pdf', path: '/sdcard/deck.pdf', size: 4096),
          ],
        _FakeUploads()..error = const UploadError('timeout', 'slow'),
        _FakeActions(),
      );
      await vm.pickFile();
      // Not landed yet — the fake upload throws, but the first emit
      // (the picked item) is already visible.
      expect(vm.takeForSend().files, isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(vm.state, isA<AttachmentEmpty>(),
          reason: 'the failed item is dropped out of the tray');
      vm.dispose();
    },
  );

  test('a failed upload drops only that item, with an uploadFailed hint',
      () async {
    final uploads = _FakeUploads()
      ..error = const UploadError('upload_hash_mismatch', 'hash mismatch');
    final vm = AttachmentViewModel(
      _FakePicker(),
      _FakeAnyPicker()
          ..nexts = const [
            TextFilePick(
              name: 'notes.md',
              file: PickedTextFile(name: 'notes.md', text: '# hi', byteLength: 4),
            ),
            BinaryFilePick(name: 'deck.pdf', path: '/sdcard/deck.pdf', size: 4096),
          ],
        uploads,
        _FakeActions(),
    );
    final hints = <AttachHint>[];
    final sub = vm.hints.listen(hints.add);

    await vm.pickFile();
    await Future<void>.delayed(Duration.zero);

    final items = (vm.state as AttachmentAttached).items;
    expect(items, hasLength(1),
        reason: 'the sibling text file survives the binary failure');
    expect(items.single, isA<AttachedTextFile>());
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

  test('a text-only model still allows files (vision gates images only)',
      () async {
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
    final item = (vm.state as AttachmentAttached).items.single;
    expect((item as AttachedTextFile).file.name, 'notes.md');
    vm.dispose();
  });

  group('Plan/62+63 — durable per-room attachment tray', () {
    late Directory dir;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('rp_v2_attachments_');
    });

    tearDown(() async {
      await Hive.close();
      await dir.delete(recursive: true);
    });

    AttachmentStore makeStore() => AttachmentStore(LocalBoxes());

    test('a landed reference re-attaches as sendable on re-entry', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epkA',
        'room1',
        const [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 999,
            phonePath: '/phone/deck.pdf',
            landedPath: '/uploads/room/deck.pdf',
          ),
        ],
      );

      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        _FakeUploads(),
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');

      final s = vm.state;
      expect(s, isA<AttachmentAttached>());
      final binary = (s as AttachmentAttached).items.single as AttachedBinaryFile;
      expect(binary.landed, isTrue);
      expect(binary.landedPath, '/uploads/room/deck.pdf');
      expect(binary.progress, 1);
      vm.dispose();
    });

    test('an unfinished upload restarts from the phone copy on re-entry',
        () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      final phoneFile = File('${dir.path}/deck.pdf')
        ..writeAsBytesSync([1, 2, 3]);
      await store.save(
        'epkA',
        'room1',
        [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 3,
            phonePath: phoneFile.path,
          ),
        ],
      );

      final uploads = _FakeUploads()
        ..result = const UploadedFile(
          name: 'deck.pdf',
          path: '/uploads/room/deck.pdf',
        );
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        uploads,
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');
      await Future<void>.delayed(Duration.zero);

      expect(uploads.uploads, ['deck.pdf']);
      final binary =
          ((vm.state as AttachmentAttached).items.single as AttachedBinaryFile);
      expect(binary.landed, isTrue);
      expect(
        store.read('epkA', 'room1').single.landedPath,
        '/uploads/room/deck.pdf',
        reason: 'the store records the landed path',
      );
      vm.dispose();
    });

    test('a missing phone file leaves the room empty (no phantom)', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epkA',
        'room1',
        [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 3,
            phonePath: '/gone/deck.pdf',
          ),
        ],
      );

      final uploads = _FakeUploads();
      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        uploads,
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');
      await Future<void>.delayed(Duration.zero);

      expect(vm.state, isA<AttachmentEmpty>());
      expect(uploads.uploads, isEmpty);
      vm.dispose();
    });

    test('a room switch drops the old tray, re-hydrates the new', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epkA',
        'room1',
        const [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 9,
            phonePath: '/p/d.pdf',
            landedPath: '/u/d.pdf',
          ),
        ],
      );
      await store.save(
        'epkA',
        'room2',
        const [
          AttachmentRecord(
            name: 'plan.pdf',
            size: 7,
            phonePath: '/p/p.pdf',
            landedPath: '/u/p.pdf',
          ),
        ],
      );

      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        _FakeUploads(),
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');
      expect(
        ((vm.state as AttachmentAttached).items.single as AttachedBinaryFile)
            .landedPath,
        '/u/d.pdf',
      );

      vm.updateRoom('epkA', 'room2');
      expect(
        ((vm.state as AttachmentAttached).items.single as AttachedBinaryFile)
            .landedPath,
        '/u/p.pdf',
      );

      vm.updateRoom('epkA', 'room1');
      expect(
        ((vm.state as AttachmentAttached).items.single as AttachedBinaryFile)
            .landedPath,
        '/u/d.pdf',
      );
      vm.dispose();
    });

    test('takeForSend clears the stored references', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epkA',
        'room1',
        const [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 9,
            phonePath: '/p/d.pdf',
            landedPath: '/u/d.pdf',
          ),
        ],
      );

      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        _FakeUploads(),
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');

      final sent = vm.takeForSend();
      expect(sent.files, hasLength(1));
      expect(sent.files.single.path, '/u/d.pdf');
      expect(store.read('epkA', 'room1'), isEmpty);
      vm.dispose();
    });

    test('removeItem clears the stored reference', () async {
      await LocalBoxes.initForTest(dir.path);
      final store = makeStore();
      await store.save(
        'epkA',
        'room1',
        const [
          AttachmentRecord(
            name: 'deck.pdf',
            size: 9,
            phonePath: '/p/d.pdf',
            landedPath: '/u/d.pdf',
          ),
        ],
      );

      final vm = AttachmentViewModel(
        _FakePicker(),
        _FakeAnyPicker(),
        _FakeUploads(),
        _FakeActions(),
        store,
      );
      vm.updateRoom('epkA', 'room1');
      vm.removeItem(0);

      expect(store.read('epkA', 'room1'), isEmpty);
      vm.dispose();
    });
  });
}
