// Plan/30 — ImageBubble renders a static thumbnail from base64 + optional
// caption, with a broken-image fallback for bad data.
//
// Two layout rules are pinned here. A picture keeps its OWN ratio: a square is
// square, a portrait screenshot is a tall strip — merely scaled down to fit the
// bubble's 300 × 220 envelope, never cropped and never stretched. And the box is
// reserved from the picture's header, so its height on the frame the decode
// lands is the height it had on the frame before (see `image_frame.dart` for
// what a row that grows mid-scroll does to a scrolling finger).
//
// Tapping the picture opens the full-screen preview, which is the only place a
// slim strip is readable.

import 'dart:convert';
import 'dart:typed_data';

import 'package:app/domain/session_state.dart';
import 'package:app/domain/value_objects/image_size.dart';
import 'package:app/ui/chat/widgets/image_bubble.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 1×1 PNG — the engine can actually decode this one, which matters: a fixture
// it rejects surfaces as an `ErrorWidget` whenever the (real, async) decode
// happens to complete inside a test, and takes `find.byType(Image)` with it.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg==';

// Real PNGs, 1-bit, so they inline small: 200×200 (square), 700×1568 (a phone
// screenshot, taller than the cap) and 400×100 (wide and short).
const _square =
    'iVBORw0KGgoAAAANSUhEUgAAAMgAAADIAQAAAACFI5MzAAAAKElEQVR42u3JoQEAAAgDoOn/'
    'P2u1+AFUavLoGGOMMcYYY4wxxhhjzLUvnQKPTWDWfAAAAABJRU5ErkJggg==';
const _portrait =
    'iVBORw0KGgoAAAANSUhEUgAAArwAAAYgAQAAAAC7KqPFAAAB+ElEQVR42u3MQREAAAQAMPQvKwEd'
    '3PltAZYTL7riiVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovF'
    'YrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8Vi'
    'sVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKx'
    'WCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFY'
    'LBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgs'
    'FovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwW'
    'i8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaL'
    'xWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBaLxWKxWCwWi8VisVgsFovF'
    'YrFYLBaLxWKxWCwWi8VisVgsFovFYrFYLBbfLODsDjBmIyHBAAAAAElFTkSuQmCC';
const _wide =
    'iVBORw0KGgoAAAANSUhEUgAAAZAAAABkAQAAAACAsFvaAAAAG0lEQVR42u3BAQ0AAADCoPdP'
    'bQ8HFAAAAADwYBPsAAEwqsp8AAAAAElFTkSuQmCC';

void main() {
  Future<void> pump(
    WidgetTester tester,
    MessageImage image,
    String caption, {
    Future<Uint8List?> Function(String blob)? loadBytes,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            // The bubble lives in a 300 pt column in the chat (see
            // `message_bubble.dart`); the frame's arithmetic depends on it.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: ImageBubble(
                image: image,
                caption: caption,
                loadBytes: loadBytes,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Size imageSize(WidgetTester tester) => tester.getSize(find.byType(Image));

  testWidgets('renders the image and the caption', (tester) async {
    await pump(
      tester,
      const MessageImage(data: _png, mime: 'image/jpeg'),
      'a kitten',
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('a kitten'), findsOneWidget);
  });

  testWidgets('renders without a caption when empty', (tester) async {
    await pump(tester, const MessageImage(data: _png, mime: 'image/jpeg'), '');
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('falls back to a broken-image glyph on bad base64', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(data: 'not valid base64 !!', mime: 'image/jpeg'),
      '',
    );
    await tester.pump();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('a square picture stays square, just smaller', (tester) async {
    // 200×200 in a 300 pt row: no crop, no stretch, and no blow-up either —
    // the bubble is the picture's own size.
    await pump(tester, const MessageImage(data: _square, mime: 'image/png'), '');
    expect(imageSize(tester), const Size(200, 200));
    expect(tester.getSize(find.byType(ImageBubble)).width, 200);
    await tester.pump();
    expect(imageSize(tester), const Size(200, 200));
  });

  testWidgets('a tall screenshot is a tall strip, not a cropped banner', (
    tester,
  ) async {
    // 700×1568 against a 220 px height cap → 98.2 × 220, the picture's own
    // ratio. The old `BoxFit.cover` filled the 300 pt width and threw away the
    // sides, so a screenshot and a landscape photo looked alike.
    await pump(
      tester,
      const MessageImage(data: _portrait, mime: 'image/png'),
      '',
    );
    const expected = Size(700 * 220 / 1568, 220);
    expect(imageSize(tester).height, closeTo(expected.height, 0.01));
    expect(imageSize(tester).width, closeTo(expected.width, 0.01));
    // ... and it is final on the first frame, before the decode lands.
    await tester.pump();
    expect(imageSize(tester).width, closeTo(expected.width, 0.01));
  });

  testWidgets('a wide picture fills the width and keeps its height', (
    tester,
  ) async {
    // 400×100 in a 300 pt row → 300×75.
    await pump(tester, const MessageImage(data: _wide, mime: 'image/png'), '');
    expect(imageSize(tester), const Size(300, 75));
  });

  testWidgets('a caption wider than the picture still fits the envelope', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(data: _portrait, mime: 'image/png'),
      'this caption is much wider than the narrow strip above it',
    );
    expect(tester.getSize(find.byType(ImageBubble)).width, 300);
    // The picture keeps its own box inside that wider card.
    expect(imageSize(tester).height, closeTo(220, 0.01));
  });

  testWidgets('tapping the picture opens the full-screen preview', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(data: _square, mime: 'image/png'),
      '',
    );
    await tester.pump();

    expect(find.byKey(const Key('image-preview')), findsNothing);
    await tester.tap(find.byKey(const Key('image-bubble-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-preview')), findsOneWidget);

    await tester.tap(find.byKey(const Key('image-preview-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-preview')), findsNothing);
  });

  testWidgets('the same payload is decoded once, not once per row', (
    tester,
  ) async {
    // A row is thrown away when it scrolls out of view, so the bytes have to
    // come from somewhere shared — otherwise every pass re-decodes the picture
    // *and* hands Flutter's image cache a key it can never hit.
    await pump(
      tester,
      const MessageImage(data: _portrait, mime: 'image/png'),
      '',
    );
    final first = tester.widget<Image>(find.byType(Image));

    await tester.pumpWidget(const SizedBox());
    await pump(
      tester,
      const MessageImage(data: _portrait, mime: 'image/png'),
      '',
    );
    final second = tester.widget<Image>(find.byType(Image));

    // (`Image.memory` wraps the bytes in a ResizeImage once it is given a
    // decoded-width hint, so unwrap to the payload before comparing.)
    final firstBytes = _payload(first.image);
    final secondBytes = _payload(second.image);
    expect(
      identical(firstBytes, secondBytes),
      isTrue,
      reason: 'the byte list identity is what Flutter\'s image cache keys on',
    );
  });

  testWidgets('the bitmap is decoded at display size, not photo size', (
    tester,
  ) async {
    // 400×100 → a 300 pt box, so the decode hint is 300 logical pixels' worth.
    await pump(tester, const MessageImage(data: _wide, mime: 'image/png'), '');
    final provider = tester.widget<Image>(find.byType(Image)).image;
    expect(provider, isA<ResizeImage>());
    expect(
      (provider as ResizeImage).width,
      (300 * tester.view.devicePixelRatio).round(),
    );
  });

  // A row PERSISTED by the app carries no bytes: the write path archives them and
  // the row keeps a content hash plus the pixel size. These three pin that the
  // bubble still draws it — and that the box is reserved before the disk read
  // lands, so scrolling does not jump.
  testWidgets('an archived picture renders from the phone archive', (
    tester,
  ) async {
    final bytes = base64Decode(_square);
    await pump(
      tester,
      const MessageImage(
        mime: 'image/png',
        blob: 'img_archived_1.bin',
        width: 200,
        height: 200,
      ),
      '',
      loadBytes: (blob) async => blob == 'img_archived_1.bin' ? bytes : null,
    );
    // Frame one: the box is already the picture's (the size rode along in the
    // row), so nothing below it moves when the bytes land.
    expect(tester.getSize(find.byType(ImageBubble)), const Size(200, 200));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(imageSize(tester), const Size(200, 200));
  });

  testWidgets('a missing archive copy degrades to the broken glyph', (
    tester,
  ) async {
    await pump(
      tester,
      const MessageImage(
        mime: 'image/png',
        blob: 'img_archived_missing.bin',
        width: 200,
        height: 200,
      ),
      '',
      loadBytes: (blob) async => null,
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('an archived picture opens the preview once loaded', (
    tester,
  ) async {
    final bytes = base64Decode(_square);
    await pump(
      tester,
      const MessageImage(
        mime: 'image/png',
        blob: 'img_archived_2.bin',
        width: 200,
        height: 200,
      ),
      '',
      loadBytes: (blob) async => bytes,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('image-bubble-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('image-preview')), findsOneWidget);
  });

  test('the fixtures say what the layout tests assume', () {
    expect(probeImageSize(base64Decode(_square)), const ImageSize(200, 200));
    expect(probeImageSize(base64Decode(_portrait)), const ImageSize(700, 1568));
    expect(probeImageSize(base64Decode(_wide)), const ImageSize(400, 100));
  });
}

Uint8List _payload(ImageProvider provider) =>
    ((provider as ResizeImage).imageProvider as MemoryImage).bytes;
