import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/image_frame.dart';
import 'package:app/ui/chat/widgets/image_preview.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';

/// The user's pictures, one bubble each, right-aligned in the transcript.
///
/// A picture is shown at its OWN ratio — the box comes from its header, so a
/// square is square and a rectangle is a rectangle, merely scaled down to fit
/// the bubble's 300 × [maxHeight] envelope. Nothing is cropped and nothing is
/// stretched, which is the only way the user can tell at a glance which shot
/// is which. Tapping one opens [ImagePreview], where a slim phone screenshot
/// gets the whole screen to be read on.
///
/// The bytes do not live in the message row any more: the write path archives
/// them in the phone's own store and the row keeps a content hash plus the pixel
/// size (`MessageImage.blob`), so a `session_history` replay cannot delete a
/// picture from the transcript. [loadBytes] is how the bytes come back; an older
/// row that still carries them inline renders straight from `data`.
///
/// Either way the box is reserved BEFORE the bytes are on screen: from the size
/// recorded with the archive, or from the inline header. A bubble that grows
/// from nothing to 220 px as the bytes land shoves every row under it down, which
/// is what made a fling through a room with pictures stop dead.
///
/// A picture is its own bubble: the text the user typed alongside it lives in a
/// separate card above (see `message_bubble.dart`), never inside this one.
class ImageBubble extends StatefulWidget {
  const ImageBubble({
    super.key,
    required this.image,
    this.isFailed = false,
    this.loadBytes,
  });

  final MessageImage image;
  final bool isFailed;

  /// Reads the bytes archived under [MessageImage.blob] (null when this phone
  /// has no copy), or null where there is no archive at all — a test, or a row
  /// that renders from inline bytes.
  final Future<Uint8List?> Function(String blob)? loadBytes;

  /// Cap the thumbnail height; the width follows the picture's ratio under it.
  static const double maxHeight = 220;

  @override
  State<ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<ImageBubble> {
  /// The picture's bytes; null until they are known (archived rows are read
  /// from the disk).
  Uint8List? _bytes;
  ImageSize? _size;

  /// True while an archived row's bytes are being read. Holds the media area
  /// open at the picture's box instead of flashing the broken glyph.
  bool _reading = false;

  @override
  void initState() {
    super.initState();
    _read();
  }

  @override
  void didUpdateWidget(ImageBubble old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _read();
  }

  void _read() {
    _bytes = null;
    _size = null;
    _reading = false;
    final image = widget.image;
    if (image.data.isNotEmpty) {
      // A row written before the archive existed: bytes inline.
      final bytes = _PayloadCache.decode(image.data);
      _bytes = bytes.isEmpty ? null : bytes;
      _size = probeImageSize(bytes);
      return;
    }
    final blob = image.blob;
    if (blob == null) return; // nothing to draw: a row with no byte source
    // The size was recorded when the bytes were archived, so the box is exact
    // on the very first frame — no reflow while the disk read runs.
    if (image.width != null && image.height != null) {
      _size = ImageSize(image.width!, image.height!);
    }
    final cached = _PayloadCache.archived(blob);
    if (cached != null) {
      _bytes = cached;
      _size ??= probeImageSize(cached);
      return;
    }
    _reading = true;
    // ignore: discarded_futures
    _load(blob);
  }

  Future<void> _load(String blob) async {
    final loader = widget.loadBytes;
    final bytes = loader == null ? null : await loader(blob);
    if (!mounted) return;
    if (bytes == null || bytes.isEmpty) {
      setState(() => _reading = false);
      return;
    }
    _PayloadCache.remember(blob, bytes);
    setState(() {
      _reading = false;
      _bytes = bytes;
      _size ??= probeImageSize(bytes);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: colors.userBubble,
        borderRadius: BorderRadius.circular(12),
        border: widget.isFailed
            ? Border.all(color: colors.error, width: 1)
            : null,
      ),
      clipBehavior: Clip.antiAlias,
      // Loose width on purpose: the bubble is only as wide as the picture's own
      // box, up to the 300 pt envelope `message_bubble.dart` gives it.
      child: _bytes != null
          ? _picture(context)
          : _reading
          ? _readingBox(context)
          : _broken(context),
    );
  }

  /// Holds the picture's box open while the archived bytes are read.
  Widget _readingBox(BuildContext context) {
    return ImageFrame(
      size: _size,
      maxHeight: ImageBubble.maxHeight,
      keepRatio: true,
      builder: (context, _) => Center(
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 1.4,
            color: context.colors.muted,
          ),
        ),
      ),
    );
  }

  /// The picture itself, in a box sized from its header. `keepRatio` is what
  /// makes the bubble hug it: the frame only gets a LOOSE width here, so the
  /// box it reserves is the picture's, not the row's.
  Widget _picture(BuildContext context) {
    return GestureDetector(
      key: const Key('image-bubble-open'),
      onTap: () => ImagePreview.open(context, _bytes!),
      child: ImageFrame(
        size: _size,
        maxHeight: ImageBubble.maxHeight,
        keepRatio: true,
        builder: (context, cacheWidth) => Image.memory(
          _bytes!,
          // `contain` (not `cover`): the box already has the picture's ratio,
          // and nothing may be cropped even if the header was a pixel off.
          fit: BoxFit.contain,
          gaplessPlayback: true,
          cacheWidth: cacheWidth,
        ),
      ),
    );
  }

  Widget _broken(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 120,
      color: colors.codeBg,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_outlined, color: colors.muted, size: 28),
    );
  }
}

/// Decoded bytes, kept for the process.
///
/// Rows are discarded as soon as they scroll out of the viewport, so the same
/// picture is decoded (or read from the archive) again on the way back — and a
/// fresh [Uint8List] also throws away Flutter's own decode cache, whose key is
/// the byte list's *identity*, not its content. Handing the same list back for
/// the same base64 / the same blob keeps both the bytes and the bitmap cached,
/// so scrolling past a picture the second time costs nothing. Bounded by total
/// size, oldest out.
class _PayloadCache {
  static const int maxBytes = 32 * 1024 * 1024;

  /// Keys are prefixed so an inline payload and an archived blob can never
  /// collide (the names come from different namespaces).
  static const String _inline = 'data:';
  static const String _blob = 'blob:';

  static final Map<String, Uint8List> _byKey = {};
  static int _held = 0;

  /// The archived bytes for [blob], or null when they are not in memory.
  static Uint8List? archived(String blob) => _byKey['$_blob$blob'];

  static void remember(String blob, Uint8List bytes) =>
      _store('$_blob$blob', bytes);

  static Uint8List decode(String data) {
    final hit = _byKey['$_inline$data'];
    if (hit != null) return hit;
    Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } catch (_) {
      return Uint8List(0);
    }
    _store('$_inline$data', bytes);
    return bytes;
  }

  static void _store(String key, Uint8List bytes) {
    final old = _byKey.remove(key);
    if (old != null) _held -= old.length;
    _byKey[key] = bytes;
    _held += bytes.length;
    while (_held > maxBytes && _byKey.length > 1) {
      final oldest = _byKey.keys.first;
      _held -= _byKey.remove(oldest)!.length;
    }
  }
}
