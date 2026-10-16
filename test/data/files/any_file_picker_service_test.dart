// Plan/62 — AnyFilePickerService: content-based classification (text inline
// vs. binary to the chunked upload channel), through the backend seam.

import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/files/any_file_picker_service.dart';
import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/uploads/upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements TextFilePickerBackend {
  PickedSource? next;

  @override
  Future<PickedSource?> pick() async => next;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rp62_picker_');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  File mkFile(String name, List<int> bytes) {
    final f = File('${tmp.path}/$name')..writeAsBytesSync(bytes);
    return f;
  }

  test('a cancelled pick returns null', () async {
    final svc = AnyFilePickerService(_FakeBackend());
    expect(await svc.pickFile(), isNull);
  });

  test('in-memory text bytes come back as a TextFilePick', () async {
    final backend = _FakeBackend()
      ..next = PickedSource(
        name: 'notes.txt',
        bytes: Uint8List.fromList(const [0x68, 0x69, 0x0a]), // "hi\n"
      );
    final pick = await AnyFilePickerService(backend).pickFile();
    expect(pick, isA<TextFilePick>());
    expect((pick! as TextFilePick).file.text, 'hi\n');
  });

  test('a text file on disk comes back as a TextFilePick', () async {
    final f = mkFile('readme.md', [0x23, 0x20, 0x68, 0x69]); // "# hi"
    final backend = _FakeBackend()..next = PickedSource(name: 'readme.md', path: f.path);
    final pick = await AnyFilePickerService(backend).pickFile();
    expect(pick, isA<TextFilePick>());
    expect((pick! as TextFilePick).file.text, '# hi');
  });

  test('a text file bigger than the inline cap is truncated, like the text picker',
      () async {
    final f = mkFile('big.log', List<int>.filled(2 * 1024 * 1024, 0x61)); // "a" × 2 MiB
    final backend = _FakeBackend()
      ..next = PickedSource(name: 'big.log', path: f.path);
    final pick = await AnyFilePickerService(backend).pickFile();
    final tf = pick! as TextFilePick;
    expect(tf.file.truncated, isTrue);
    expect(
      tf.file.text,
      endsWith(TextFilePickerService.truncationMarker),
    );
  });

  test('a binary file on disk comes back as a BinaryFilePick with size', () async {
    final bytes = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
    final f = mkFile('shot.png', bytes);
    final backend = _FakeBackend()..next = PickedSource(name: 'shot.png', path: f.path);
    final pick = await AnyFilePickerService(backend).pickFile();
    expect(pick, isA<BinaryFilePick>());
    final bp = pick! as BinaryFilePick;
    expect(bp.path, f.path);
    expect(bp.size, bytes.length);
  });

  test('NUL bytes under a .txt name still classify as binary', () async {
    final f = mkFile('fake.txt', [0x68, 0x69, 0x00, 0x01]);
    final backend = _FakeBackend()..next = PickedSource(name: 'fake.txt', path: f.path);
    final pick = await AnyFilePickerService(backend).pickFile();
    expect(pick, isA<BinaryFilePick>());
  });

  test('a bytes-only binary pick (no path) throws StateError', () async {
    final backend = _FakeBackend()
      ..next = PickedSource(name: 'x.bin', bytes: Uint8List.fromList([1, 2, 0]));
    await expectLater(
      AnyFilePickerService(backend).pickFile(),
      throwsStateError,
    );
  });

  test('an empty file decodes as vacuous text (same rule as the text picker)',
      () async {
    final f = mkFile('empty.txt', const []);
    final backend = _FakeBackend()..next = PickedSource(name: 'empty.txt', path: f.path);
    final pick = await AnyFilePickerService(backend).pickFile();
    final tf = pick! as TextFilePick;
    expect(tf.file.text, '');
  });

  test('a file over the upload cap throws FileTooLargeException', () async {
    // Sparse file: one byte past the 250 MiB cap, no real storage.
    final f = File('${tmp.path}/huge.bin');
    final raf = f.openSync(mode: FileMode.write);
    // One byte at index uploadMaxBytes → length uploadMaxBytes + 1.
    raf.setPositionSync(uploadMaxBytes);
    raf.writeByteSync(0);
    raf.closeSync();

    final backend = _FakeBackend()..next = PickedSource(name: 'huge.bin', path: f.path);
    await expectLater(
      AnyFilePickerService(backend).pickFile(),
      throwsA(
        isA<FileTooLargeException>()
            .having((e) => e.name, 'name', 'huge.bin')
            .having((e) => e.size, 'size', uploadMaxBytes + 1),
      ),
    );
  });
}
