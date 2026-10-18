import 'dart:typed_data';

import 'package:app/ui/chat/widgets/zoomable_image.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full-screen look at a picture the user sent, opened by tapping its bubble.
///
/// The bubble itself shows the picture at its own ratio, which for a phone
/// screenshot means a slim strip — legible enough to recognize, not enough to
/// read. This page is where the picture gets the screen: black backdrop (an
/// image is read against black), pinch/double-tap zoom, and back/dismiss.
///
/// The bytes are the ones the bubble already decoded, passed in rather than
/// re-read: a sent image lives inline in the transcript, so there is no file to
/// open and nothing to fetch.
class ImagePreview extends StatelessWidget {
  const ImagePreview({super.key, required this.bytes});

  final Uint8List bytes;

  /// Open the preview, leaving the keyboard down on return.
  ///
  /// Focus is dropped on BOTH sides of the route on purpose — the same reason
  /// the attachment viewer does it: the composer can hold focus from an earlier
  /// tap with the IME hidden, and popping hands that focus back, which raises
  /// the soft keyboard every time a preview is closed.
  static Future<void> open(BuildContext context, Uint8List bytes) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ImagePreview(bytes: bytes)),
    );
    FocusManager.instance.primaryFocus?.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('image-preview'),
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: ZoomableImage(
                child: Center(
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 4,
              right: 4,
              child: IconButton(
                key: const Key('image-preview-close'),
                tooltip: 'Close',
                icon: const Icon(LucideIcons.x),
                color: Colors.white70,
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
