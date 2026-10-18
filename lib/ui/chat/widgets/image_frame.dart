import 'dart:math' as math;

import 'package:app/domain/value_objects/image_size.dart';
import 'package:flutter/material.dart';

/// Reserves an image's box *before* its bytes are on screen.
///
/// Flutter's `Image` sizes itself from the decoded bitmap, so a row that only
/// gets its picture mid-flight has no height until then and a different one
/// after. That reflow is what the user feels, and it is not subtle: the Pi's
/// attachment card used to be ~44 px tall while its blob was read from disk and
/// 220 px once the bytes landed, so every image the viewport crossed pushed
/// everything below it down by ~176 px.
///
///  * a fling that runs into one stops dead — the sliver re-estimates its
///    content extent under the gesture, and the drag activity ends there;
///  * a slow drag through a room full of screenshots moves *down* far more than
///    the finger moves, so the list looks like it snaps back to where it was.
///
/// The cure is knowing the height up front: [size] comes from the header
/// (`probeImageSize`), the box is derived from the constraints the row already
/// hands us, and it is then a plain `SizedBox` — nothing about it can change
/// when the decode lands.
///
/// The arithmetic is `RenderImage`'s own, reproduced for a *tight* width: a
/// card spans its row, so the box is
/// `available × min(maxHeight, height the picture would take at that width)`.
/// Keeping it identical is the point — the reserved box is the box the picture
/// was always going to get, so nothing moves and nothing crops differently than
/// before.
///
/// [keepRatio] is the other shape of the same idea, for the places where the
/// picture stands on its own and must not be cropped OR stretched: the width
/// follows the picture too, so a square stays square and a rectangle stays a
/// rectangle — just smaller. The box then sits inside the row rather than
/// spanning it, which is why those call sites must not hand the frame a tight
/// width.
class ImageFrame extends StatelessWidget {
  const ImageFrame({
    super.key,
    required this.size,
    required this.builder,
    this.maxHeight = 220,
    this.keepRatio = false,
  }) : assert(maxHeight > 0);

  /// Pixel size of the encoded image, or null when its header could not be read
  /// (HEIC, a truncated file). Null reserves [maxHeight]: still a fixed box, just
  /// not the exact one.
  final ImageSize? size;

  /// Ceiling for the reserved height.
  final double maxHeight;

  /// Size the box from the picture's own ratio on both axes instead of
  /// stretching it to the available width. The picture is never cropped and
  /// never magnified past its own pixels — a small one is shown at its own
  /// size, a big one is scaled down until it fits.
  final bool keepRatio;

  /// Builds the content of the reserved box. [cacheWidth] is the decoded-width
  /// hint for the image, so the bitmap is never decoded larger than it is
  /// painted.
  final Widget Function(BuildContext context, int cacheWidth) builder;

  /// The box [size] gets inside [available]: [RenderImage]'s arithmetic under a
  /// tight width, or — with [keepRatio] — the largest box of the same ratio
  /// that fits `available × maxHeight` without overflowing the picture's own
  /// pixels.
  Size _box(double available) {
    final known = size;
    final unknown = known == null || known.width <= 0 || known.height <= 0;
    if (unknown) {
      // Nothing to derive the ratio from: a fixed box, square when hugging.
      return keepRatio
          ? Size(math.min(available, maxHeight), maxHeight)
          : Size(available, maxHeight);
    }
    if (!keepRatio) {
      final height = math.min(
        maxHeight,
        known.width <= available
            ? known.height.toDouble()
            : available * known.height / known.width,
      );
      return Size(available, height);
    }
    final scale = math.min(
      1.0,
      math.min(available / known.width, maxHeight / known.height),
    );
    return Size(known.width * scale, known.height * scale);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : maxHeight;
        final box = _box(available);
        final dpr = MediaQuery.devicePixelRatioOf(context);
        return SizedBox.fromSize(
          size: box,
          child: builder(context, math.max(1, (box.width * dpr).round())),
        );
      },
    );
  }
}

/// Process-wide memo of image sizes, keyed by blob name.
///
/// An attachment card's state is thrown away the moment it leaves the viewport
/// (that is exactly why the bytes live in `AttachmentStore` and not in the
/// widget), so without a memo the second scroll past an image would reserve a
/// box for one frame and correct it on the next — the reflow [ImageFrame] exists
/// to prevent, just smaller. Two ints per blob, oldest out.
class ImageSizeCache {
  ImageSizeCache({this.maxEntries = 256}) : assert(maxEntries > 0);

  /// The app-wide memo. Tests clear it instead of replacing it.
  static final ImageSizeCache shared = ImageSizeCache();

  final int maxEntries;
  final Map<String, ImageSize?> _sizes = {};

  /// The remembered size for [key], or null when nothing is known yet.
  ImageSize? sizeOf(String key) => _sizes[key];

  /// Records [size] for [key]. A null (unreadable header) is stored too, so the
  /// parse is not repeated on every build.
  void remember(String key, ImageSize? size) {
    _sizes.remove(key);
    _sizes[key] = size;
    while (_sizes.length > maxEntries) {
      _sizes.remove(_sizes.keys.first);
    }
  }

  void clear() => _sizes.clear();
}
