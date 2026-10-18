import 'package:flutter/material.dart';

/// A picture the user can look INTO: pinch + pan over [child], plus a
/// double-tap that toggles between "fit the viewport" and "read the pixels".
///
/// The double-tap is what makes a screenshot legible without a pinch gesture.
/// It eases (a fast-start ease reads as a jump followed by a slow settle; the
/// symmetric curve spreads the motion evenly instead) and it magnifies about
/// the viewport's center, so the picture stays put instead of sliding out of
/// frame.
///
/// Shared by the two full-screen viewers (a file the Pi sent, a picture the
/// user sent) so both feel identical under the finger.
class ZoomableImage extends StatefulWidget {
  const ZoomableImage({
    super.key,
    required this.child,
    this.maxScale = 6,
    this.doubleTapScale = 2.5,
  });

  /// What gets zoomed — typically an `Image` wrapped so it fits the viewport.
  final Widget child;

  /// Ceiling for the pinch gesture.
  final double maxScale;

  /// The scale the double-tap zooms in to.
  final double doubleTapScale;

  @override
  State<ZoomableImage> createState() => _ZoomableImageState();
}

class _ZoomableImageState extends State<ZoomableImage>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();

  /// Drives the eased double-tap zoom; the pinch gesture still moves
  /// [_transform] directly, so the two share one source of truth.
  late final AnimationController _zoom = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  bool _zoomed = false;

  /// Where the current double-tap animation starts; [_tick] lerps from here to
  /// the toggle's target.
  Matrix4 _start = Matrix4.identity();
  Matrix4 _target = Matrix4.identity();

  @override
  void initState() {
    super.initState();
    // Registered once: re-adding on every toggle would pile up listeners.
    _zoom.addListener(_tick);
  }

  @override
  void dispose() {
    _zoom.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _toggleZoom(Size viewport) {
    final target = _zoomed
        ? Matrix4.identity()
        : _zoomMatrix(viewport.center(Offset.zero), widget.doubleTapScale);
    setState(() => _zoomed = !_zoomed);
    // Every transform this widget can hold is a scale plus a translation
    // (pinch, pan, and the double-tap zoom all leave rotation at zero), so
    // lerping scale and translation is the whole lerp.
    _start = _transform.value;
    _target = target;
    _zoom.reset();
    _zoom.forward();
  }

  void _tick() {
    final t = Curves.easeInOut.transform(_zoom.value);
    final s = _lerp(_start[0], _target[0], t);
    _transform.value = Matrix4.identity()
      ..translateByDouble(
        _lerp(_start[12], _target[12], t),
        _lerp(_start[13], _target[13], t),
        0,
        1,
      )
      ..scaleByDouble(s, s, 1, 1);
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// A [scale] about [center]: the point maps onto itself, so zooming in
  /// magnifies in place. (Scaling about the origin is the viewport's top-left
  /// corner — the image slides down and out of frame.)
  static Matrix4 _zoomMatrix(Offset center, double scale) {
    return Matrix4.identity()
      ..translateByDouble(center.dx, center.dy, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1)
      ..translateByDouble(-center.dx, -center.dy, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    // The viewport's own size is where the double-tap zoom centers itself,
    // hence the LayoutBuilder feeding it into the toggle.
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onDoubleTap: () => _toggleZoom(constraints.biggest),
        child: InteractiveViewer(
          transformationController: _transform,
          minScale: 1,
          maxScale: widget.maxScale,
          child: widget.child,
        ),
      ),
    );
  }
}
