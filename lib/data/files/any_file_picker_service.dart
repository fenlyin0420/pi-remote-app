import 'dart:io';
import 'dart:typed_data';

import 'package:app/data/files/text_file_picker_service.dart';
import 'package:app/data/uploads/upload_service.dart';

/// One pick from the unrestricted file sheet, classified by **content**
/// (never by name): text (decodable characters — it rides inline, Plan/30)
/// or anything else (it rides the Plan/62 chunked upload channel, path-based).
sealed class PickedFile {
  const PickedFile({required this.name});

  /// File name as picked (leaf only, no directories).
  final String name;
}

/// Content that decoded as text — sent inline in the message.
final class TextFilePick extends PickedFile {
  const TextFilePick({required super.name, required this.file});

  final PickedTextFile file;
}

/// Non-text content — streamed to the Pi in chunks on pick; the message
/// later references it by [path]. The phone keeps the bytes only until the
/// upload is confirmed.
final class BinaryFilePick extends PickedFile {
  const BinaryFilePick({
    required super.name,
    required this.path,
    required this.size,
  });

  /// Where the bytes live on the phone (the upload service streams from it).
  final String path;
  final int size;
}

/// The picked file exceeds [uploadMaxBytes].
class FileTooLargeException implements Exception {
  final String name;
  final int size;
  const FileTooLargeException(this.name, this.size);

  @override
  String toString() => 'FileTooLargeException($name, $size bytes)';
}

abstract class IAnyFilePickerService {
  /// Pick one file (unrestricted) and classify it. Null when the user
  /// cancelled; [FileTooLargeException] / [NotTextFileException]-free —
  /// binary is a first-class result, not an error.
  Future<PickedFile?> pickFile();
}

class AnyFilePickerService implements IAnyFilePickerService {
  AnyFilePickerService([TextFilePickerBackend? backend])
    : _backend = backend ?? PlatformTextFilePickerBackend();

  final TextFilePickerBackend _backend;

  @override
  Future<PickedFile?> pickFile() async {
    final source = await _backend.pick();
    if (source == null) return null; // user cancelled

    // Bounded head for the content sniff — the same rule and cap as the text
    // picker, so a file that would have been attached as text still is.
    final Uint8List head;
    final bool headTruncated;
    final int totalSize;
    final path = source.path;
    if (path != null) {
      final file = File(path);
      totalSize = file.lengthSync();
      final limit =
          totalSize < TextFilePickerService.maxBytes
              ? totalSize
              : TextFilePickerService.maxBytes;
      final handle = file.openSync();
      try {
        head = handle.readSync(limit);
      } finally {
        handle.closeSync();
      }
      headTruncated = totalSize > limit;
    } else {
      final inMemory = source.bytes ?? Uint8List(0);
      totalSize = inMemory.length;
      head = inMemory;
      headTruncated = false;
    }

    final decoded = TextFilePickerService.decodeText(
      head,
      truncated: headTruncated,
    );
    if (decoded != null) {
      return TextFilePick(
        name: source.name,
        file: PickedTextFile(
          name: source.name,
          text: headTruncated
              ? '$decoded${TextFilePickerService.truncationMarker}'
              : decoded,
          byteLength: head.length,
          truncated: headTruncated,
        ),
      );
    }

    // Binary: the chunked upload streams from a path, so a bytes-only pick
    // is the one binary case we can't handle.
    if (path == null) {
      // The chunked upload streams from a path; a bytes-only pick can't be
      // handled. Falls into the generic pickFailed hint.
      throw StateError('No path for the picked file');
    }
    if (totalSize > uploadMaxBytes) {
      throw FileTooLargeException(source.name, totalSize);
    }
    return BinaryFilePick(name: source.name, path: path, size: totalSize);
  }
}
