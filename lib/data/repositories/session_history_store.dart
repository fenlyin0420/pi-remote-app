// Per-(peer, room) local cache of chat history. Plan 17 partitioned
// the cache: each Pi-extension session (cwd) lives in its own box
// (`session_<epk>__<roomId>`). Revoking a peer or closing a room
// simply deletes the matching box.
//
// Backward-compat: pre-plan-17 stores keyed by epk only
// (`session_<epk>`) are read transparently the first time the user
// opens the implicit `main` room of that peer, and the data is then
// re-written into the new partitioned key. The legacy box is left in
// place (cheap, future-proof) — `clearFor` deletes both forms.
//
// Schema (versioned for future migration):
//
//   box['data'] = {
//     'schema_version': 1,
//     'session_started_at': <int|null>,    // epoch ms; matches PairOk
//     'last_ts':            <int|null>,    // epoch ms of newest event seen
//     'messages':           [ {kind, ...}, ... ],
//   }
//
// `ChatMessage` is domain; this file owns the JSON shape and conversion
// (data-layer responsibility per the project's architecture rules).

import 'dart:async';

import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/domain/session_state.dart';
import 'package:hive_flutter/hive_flutter.dart';

const int _kSchemaVersion = 1;
const String _kBoxPrefix = 'session_';
const String _kRoomSeparator = '__';
const String _kDataKey = 'data';
const String kDefaultRoomId = 'main';

class CachedSession {
  final List<ChatMessage> messages;
  final int? lastTs;
  final int? sessionStartedAt;

  const CachedSession({
    required this.messages,
    required this.lastTs,
    required this.sessionStartedAt,
  });

  factory CachedSession.empty() => const CachedSession(
        messages: [],
        lastTs: null,
        sessionStartedAt: null,
      );
}

class SessionHistoryStore {
  static bool _initialized = false;

  /// Initialize the Hive runtime. Call once during bootstrap before the
  /// first frame.
  static Future<void> init() async {
    if (_initialized) return;
    await Hive.initFlutter('session_history');
    _initialized = true;
  }

  /// For tests: initialize Hive against a custom directory.
  /// Production code should call [init] (above).
  static Future<void> initForTest(String path) async {
    Hive.init(path);
    _initialized = true;
  }

  // Plan 17 — keys now include the room id. Default room is 'main',
  // which preserves single-cwd Pis from earlier versions.
  //
  // Plan/24-fix-app-source-of-truth (encoding regression): the box
  // name is used by Hive as the filename on disk. Once PeerRecord
  // started carrying base64-STANDARD epks (after the mesh-publish
  // encoding normalization), the `/` and `=` characters in
  // `peer.remoteEpk` produced paths like
  // `session_Bz02uLi.../OMq6yyqe=__main.hive` — the embedded `/`
  // makes Hive try to create a subdirectory that doesn't exist
  // (`PathNotFoundException` on iOS), which threw inside
  // `setActivePeer` and aborted `_bootstrap` before it could call
  // `requestSync` (that was Bug 1 — never seen `session_sync` in
  // the logs because `_bootstrap` died on the cache load). Sanitise
  // the epk to its filename-safe form (url-safe base64, no padding)
  // before composing the box name. `toAppEpk` is idempotent on
  // already-url-safe input, so legacy caches continue to load.
  String _boxName(String epk, String roomId) =>
      '$_kBoxPrefix${toAppEpk(epk)}$_kRoomSeparator$roomId';

  /// Legacy (pre-plan-17) box name — keyed by epk only. Still read on
  /// first `loadFor(epk, 'main')` so users don't lose their offline
  /// view on upgrade.
  String _legacyBoxName(String epk) => '$_kBoxPrefix${toAppEpk(epk)}';

  Future<Box<dynamic>> _open(String epk, String roomId) =>
      Hive.openBox<dynamic>(_boxName(epk, roomId));

  Future<Box<dynamic>> _openLegacy(String epk) =>
      Hive.openBox<dynamic>(_legacyBoxName(epk));

  Future<CachedSession> loadFor(
    String epk, {
    String roomId = kDefaultRoomId,
  }) async {
    final box = await _open(epk, roomId);
    final raw = box.get(_kDataKey);
    if (raw != null) {
      return _decode(raw);
    }
    // Plan 17 backward-compat: if this is the implicit 'main' room and
    // a legacy `session_<epk>` box exists with data, transparently
    // migrate the user's prior cache into the new partitioned key so
    // they keep seeing their chat history.
    if (roomId == kDefaultRoomId) {
      final legacy = await _openLegacy(epk);
      final legacyRaw = legacy.get(_kDataKey);
      if (legacyRaw != null) {
        final cached = _decode(legacyRaw);
        if (cached.messages.isNotEmpty ||
            cached.sessionStartedAt != null) {
          await _write(epk, roomId, cached);
          return cached;
        }
      }
    }
    return CachedSession.empty();
  }

  CachedSession _decode(dynamic raw) {
    final map = _coerceMap(raw);
    // Schema guard — if the version on disk does not match what we
    // understand, treat as empty cache (defensive against migrations).
    final version = map['schema_version'];
    if (version != _kSchemaVersion) return CachedSession.empty();
    final msgs = (map['messages'] as List?)
            ?.map((m) => _messageFromJson(_coerceMap(m)))
            .whereType<ChatMessage>()
            .toList() ??
        const <ChatMessage>[];
    return CachedSession(
      messages: msgs,
      lastTs: map['last_ts'] as int?,
      sessionStartedAt: map['session_started_at'] as int?,
    );
  }

  /// Append [events] to the existing cache for `(epk, roomId)`.
  /// [lastTs] is the newest event timestamp the caller observed
  /// (epoch ms). The session pointer stays unchanged.
  Future<void> appendEvents(
    String epk,
    List<ChatMessage> events, {
    String roomId = kDefaultRoomId,
    required int? lastTs,
  }) async {
    if (events.isEmpty && lastTs == null) return;
    final cur = await loadFor(epk, roomId: roomId);
    final next = CachedSession(
      messages: [...cur.messages, ...events],
      lastTs: lastTs ?? cur.lastTs,
      sessionStartedAt: cur.sessionStartedAt,
    );
    await _write(epk, roomId, next);
  }

  /// Replace the entire cache for `(epk, roomId)` — used when the Pi
  /// reports a different `session_started_at` (session restart on the
  /// Pi side) or when we just want to snapshot the in-memory state.
  Future<void> replaceFor(
    String epk,
    List<ChatMessage> events, {
    String roomId = kDefaultRoomId,
    required int? sessionStartedAt,
    required int? lastTs,
  }) async {
    await _write(
      epk,
      roomId,
      CachedSession(
        messages: events,
        lastTs: lastTs,
        sessionStartedAt: sessionStartedAt,
      ),
    );
  }

  /// Update only the metadata pointers; messages untouched.
  Future<void> updateMeta(
    String epk, {
    String roomId = kDefaultRoomId,
    int? lastTs,
    int? sessionStartedAt,
  }) async {
    final cur = await loadFor(epk, roomId: roomId);
    await _write(
      epk,
      roomId,
      CachedSession(
        messages: cur.messages,
        lastTs: lastTs ?? cur.lastTs,
        sessionStartedAt: sessionStartedAt ?? cur.sessionStartedAt,
      ),
    );
  }

  /// Clear the cache for a single `(epk, roomId)`. For the implicit
  /// 'main' room this also wipes the legacy `session_<epk>` box so
  /// stale data doesn't resurrect on the next load.
  Future<void> clearFor(
    String epk, {
    String roomId = kDefaultRoomId,
  }) async {
    final box = await _open(epk, roomId);
    await box.clear();
    if (roomId == kDefaultRoomId) {
      final legacy = await _openLegacy(epk);
      await legacy.clear();
    }
  }

  Future<void> close() async {
    await Hive.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _write(String epk, String roomId, CachedSession s) async {
    final box = await _open(epk, roomId);
    await box.put(_kDataKey, {
      'schema_version': _kSchemaVersion,
      'session_started_at': s.sessionStartedAt,
      'last_ts': s.lastTs,
      'messages': s.messages.map(_messageToJson).toList(),
    });
  }
}

// ---------------------------------------------------------------------------
// Serialization (kept private to the store — domain stays pure)
// ---------------------------------------------------------------------------

Map<String, dynamic> _messageToJson(ChatMessage m) {
  return switch (m) {
    UserMsg(:final id, :final text, :final status) =>
      {'kind': 'user', 'id': id, 'text': text, 'status': status.name},
    AssistantMsg(:final id, :final text) =>
      {'kind': 'assistant', 'id': id, 'text': text},
    ToolEvent(
      :final id,
      :final toolCallId,
      :final tool,
      :final args,
      :final status,
      :final result,
      :final error,
    ) =>
      {
        'kind': 'tool',
        'id': id,
        'tool_call_id': toolCallId,
        'tool': tool,
        'args': args,
        'status': status.name,
        'result': result,
        'error': error,
      },
  };
}

ChatMessage? _messageFromJson(Map<String, dynamic> j) {
  return switch (j['kind'] as String?) {
    'user' => UserMsg(
        id: j['id'] as String,
        text: j['text'] as String,
        // Back-compat: persisted UserMsgs pre-`status` field are
        // implicitly `confirmed`.
        status: UserMsgStatus.values.firstWhere(
          (s) => s.name == j['status'],
          orElse: () => UserMsgStatus.confirmed,
        ),
      ),
    'assistant' => AssistantMsg(
        id: j['id'] as String,
        text: j['text'] as String,
      ),
    'tool' => ToolEvent(
        id: j['id'] as String,
        toolCallId: j['tool_call_id'] as String,
        tool: j['tool'] as String,
        args: j['args'],
        status: ToolEventStatus.values.firstWhere(
          (e) => e.name == j['status'],
          orElse: () => ToolEventStatus.completed,
        ),
        result: j['result'],
        error: j['error'] as String?,
      ),
    _ => null,
  };
}

Map<String, dynamic> _coerceMap(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return raw.cast<String, dynamic>();
  return <String, dynamic>{};
}
