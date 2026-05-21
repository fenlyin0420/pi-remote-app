// Per-peer local cache of chat history. Each peer's history lives in its
// own Hive box (`session_<epk>`) so revoking a peer simply deletes the box.
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

import 'package:app/domain/session_state.dart';
import 'package:hive_flutter/hive_flutter.dart';

const int _kSchemaVersion = 1;
const String _kBoxPrefix = 'session_';
const String _kDataKey = 'data';

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

  String _boxName(String epk) => '$_kBoxPrefix$epk';

  Future<Box<dynamic>> _open(String epk) =>
      Hive.openBox<dynamic>(_boxName(epk));

  Future<CachedSession> loadFor(String epk) async {
    final box = await _open(epk);
    final raw = box.get(_kDataKey);
    if (raw == null) return CachedSession.empty();
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

  /// Append [events] to the existing cache for [epk]. [lastTs] is the
  /// newest event timestamp the caller observed (epoch ms). The session
  /// pointer stays unchanged.
  Future<void> appendEvents(
    String epk,
    List<ChatMessage> events, {
    required int? lastTs,
  }) async {
    if (events.isEmpty && lastTs == null) return;
    final cur = await loadFor(epk);
    final next = CachedSession(
      messages: [...cur.messages, ...events],
      lastTs: lastTs ?? cur.lastTs,
      sessionStartedAt: cur.sessionStartedAt,
    );
    await _write(epk, next);
  }

  /// Replace the entire cache for [epk] — used when the Pi reports a
  /// different `session_started_at` (session restart on the Pi side) or
  /// when we just want to snapshot the in-memory state.
  Future<void> replaceFor(
    String epk,
    List<ChatMessage> events, {
    required int? sessionStartedAt,
    required int? lastTs,
  }) async {
    await _write(
      epk,
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
    int? lastTs,
    int? sessionStartedAt,
  }) async {
    final cur = await loadFor(epk);
    await _write(
      epk,
      CachedSession(
        messages: cur.messages,
        lastTs: lastTs ?? cur.lastTs,
        sessionStartedAt: sessionStartedAt ?? cur.sessionStartedAt,
      ),
    );
  }

  Future<void> clearFor(String epk) async {
    final box = await _open(epk);
    await box.clear();
  }

  Future<void> close() async {
    await Hive.close();
  }

  // ---------------------------------------------------------------------------

  Future<void> _write(String epk, CachedSession s) async {
    final box = await _open(epk);
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
    UserMsg(:final id, :final text) =>
      {'kind': 'user', 'id': id, 'text': text},
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
    'user' => UserMsg(id: j['id'] as String, text: j['text'] as String),
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
