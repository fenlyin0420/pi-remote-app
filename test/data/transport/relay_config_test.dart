import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeStore implements FlutterSecureStorage {
  final Map<String, String> _m = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _m[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _m.remove(key);
    } else {
      _m[key] = value;
    }
  }
  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _m.remove(key);
  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

void main() {
  group('relay_config — isValidRelayUrl', () {
    test('accepts ws://, wss://, http://, https:// with non-empty host', () {
      expect(isValidRelayUrl('ws://localhost'), isTrue);
      expect(isValidRelayUrl('wss://relay.remote-pi.dev'), isTrue);
      expect(isValidRelayUrl('ws://127.0.0.1:8080'), isTrue);
      expect(isValidRelayUrl('wss://example.com/path?q=1'), isTrue);
      expect(isValidRelayUrl('http://localhost'), isTrue);
      expect(isValidRelayUrl('https://relay.example.com'), isTrue);
    });

    test('rejects empty, unsupported schemes, missing host', () {
      expect(isValidRelayUrl(''), isFalse);
      expect(isValidRelayUrl('ftp://example.com'), isFalse);
      expect(isValidRelayUrl('foo'), isFalse);
      expect(isValidRelayUrl('wss://'), isFalse,
          reason: 'no host segment');
      expect(isValidRelayUrl('https://'), isFalse,
          reason: 'no host segment');
    });
  });

  group('relay_config — toWsRelayUrl', () {
    test('translates http(s) to ws(s) and leaves ws(s) untouched', () {
      expect(toWsRelayUrl('https://relay.example.com'),
          'wss://relay.example.com');
      expect(toWsRelayUrl('http://localhost:8080'),
          'ws://localhost:8080');
      expect(toWsRelayUrl('wss://relay.example.com'),
          'wss://relay.example.com');
      expect(toWsRelayUrl('ws://localhost'), 'ws://localhost');
    });
  });

  group('relay_config — resolveRelayUrl', () {
    test('returns prefs.relayUrl when set', () async {
      final p = Preferences(_FakeStore());
      await p.setRelayUrl('wss://custom.example.com');
      expect(resolveRelayUrl(p), 'wss://custom.example.com');
    });

    test('falls back to kDefaultRelayUrl when override is null', () async {
      final p = Preferences(_FakeStore());
      expect(p.relayUrl, isNull);
      expect(resolveRelayUrl(p), kDefaultRelayUrl);
    });
  });
}
