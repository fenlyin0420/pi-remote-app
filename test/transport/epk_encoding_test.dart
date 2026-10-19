// Single-purpose unit tests for the epk wire-format helpers.

import 'package:app/data/transport/epk_encoding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toStandardB64', () {
    test('converts a url-safe epk to standard base64', () {
      const urlSafe = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO_oMQ6yyQE';
      final out = toStandardB64(urlSafe);
      expect(out.contains('_'), isFalse);
      expect(out.contains('-'), isFalse);
      // The same bytes encoded as standard contain `/`.
      expect(out.contains('/'), isTrue);
    });

    test('passes through an already-standard epk unchanged', () {
      const standard = 'Bz02uLiwrmQZ0S8qiwtFJAt0KzUvrgepYO/oMQ6yyQE=';
      // Idempotent — base64Url decode accepts both alphabets, so the
      // round-trip lands back on standard.
      expect(toStandardB64(standard), standard);
    });

    test('empty string is a no-op', () {
      expect(toStandardB64(''), '');
    });

    test('garbage input returned as-is (defensive)', () {
      expect(toStandardB64('not base64 at all !!'), 'not base64 at all !!');
    });
  });

  // Callers ask this to decide "is the relay already subscribed for this
  // peer set?", and the lists come from `FlutterSecureStorage.readAll()`,
  // whose order belongs to the platform. Getting it wrong is not cosmetic: a
  // false "different" re-subscribes, and a subscription is a round trip the
  // relay answers with a full rooms snapshot.
  group('sameEpkSet', () {
    test('ignores order', () {
      expect(sameEpkSet(['a', 'b'], ['b', 'a']), isTrue);
    });

    test('is not fooled by a repeated member', () {
      expect(sameEpkSet(['a', 'b'], ['a', 'a']), isFalse);
    });

    test('different lengths are different sets', () {
      expect(sameEpkSet(['a'], ['a', 'b']), isFalse);
    });

    test('a real change is a change', () {
      expect(sameEpkSet(['a', 'b'], ['a', 'c']), isFalse);
    });

    test('two empty lists are the same set', () {
      expect(sameEpkSet(const [], const []), isTrue);
    });
  });
}
