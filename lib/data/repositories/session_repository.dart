// SessionRepository — orchestrates ConnectionManager + PeerChannel.
//
// Exposes a Stream<SessionState> that combines:
//   • connection status changes
//   • incoming ServerMessages (agent chunks, tool requests, etc.)
//
// Provides action methods (sendMessage, cancel, approveTool) that the
// ChatViewModel calls. Also owns the per-peer chat history cache and the
// `session_sync` lifecycle (see plan/11-session-sync.md).

import 'dart:async';

import 'package:app/data/repositories/i_session_repository.dart';
import 'package:app/data/repositories/session_history_store.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/contracts/repository.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart' show debugPrint;

class SessionRepository extends Repository implements ISessionRepository {
  final ConnectionManager _conn;
  final SessionHistoryStore _store;

  final _stateController = StreamController<SessionState>.broadcast();
  final _eventController = StreamController<SessionEvent>.broadcast();
  SessionState _state = const SessionState();

  StreamSubscription? _connSub;
  StreamSubscription? _msgSub;

  // 16ms streaming buffer — coalesces AgentChunk deltas per video frame (Q2).
  final StringBuffer _chunkBuffer = StringBuffer();
  String _chunkReplyTo = '';
  Timer? _flushTimer;

  // Cache + sync bookkeeping per active peer.
  String? _activeEpk;
  int? _lastSyncedTs;
  int? _lastSessionStartedAt;
  Timer? _syncDebounce;

  SessionRepository(this._conn, this._store) {
    _connSub = _conn.statusStream.listen(_onStatusChange);
    // The status stream is a plain broadcast (no replay). If the
    // ConnectionManager already emitted `StatusOnline` BEFORE this repo
    // was constructed (e.g. boot-time WS opens before the user enters
    // `/chat` — `SessionRepository` is lazy-constructed via injector),
    // the listener above would miss it and `_state.connection` would
    // stay at the initial `StatusNoPeer`. ChatViewModel would then sit
    // on `ChatConnecting` forever (`_bootstrapping=true + NoPeer`).
    //
    // Replay-via-seed: invoke the handler synchronously with the
    // manager's current status so the repo picks up where things are.
    debugPrint(
      '[chat-state] SessionRepository ctor seed: '
      'conn=${_conn.status.runtimeType}',
    );
    _onStatusChange(_conn.status);
  }

  @override
  SessionState get current => _state;
  @override
  Stream<SessionState> get sessionStream => _stateController.stream;
  @override
  Stream<SessionEvent> get eventStream => _eventController.stream;

  @override
  Future<void> boot() => _conn.boot();

  @override
  Future<void> connectTo(PeerRecord peer) => _conn.connectTo(peer);

  @override
  Future<void> openSession(PeerRecord peer) => _conn.switchTo(peer);

  @override
  Stream<Map<String, PresenceState>> get presenceStream =>
      _conn.presenceStream;

  @override
  PresenceState presenceFor(String epk) => _conn.presenceFor(epk);

  @override
  PeerRecord? get activePeer => _conn.activePeer;

  @override
  void adoptChannel(IChannel channel, PeerRecord peer) =>
      _conn.adopt(channel, peer);

  @override
  Future<void> disconnect() => _conn.disconnect();

  // ---------------------------------------------------------------------------
  // Cache + sync
  // ---------------------------------------------------------------------------

  @override
  Future<void> setActivePeer(PeerRecord peer) async {
    final cached = await _store.loadFor(peer.remoteEpk);
    _activeEpk = peer.remoteEpk;
    _lastSyncedTs = cached.lastTs;
    _lastSessionStartedAt = cached.sessionStartedAt;
    _emit(_state.copyWith(
      messages: cached.messages,
      clearStreaming: true,
    ));
  }

  @override
  void requestSync() {
    final ch = _conn.channel;
    final epk = _activeEpk;
    if (ch == null || epk == null) return;
    debugPrint('[chat-state] requestSync epk=$epk (mirror)');
    // Plan 16 mirror-cache: app does NOT cap the history. Pi decides
    // how many events to return based on its own env config; the app
    // just renders whatever arrives. Pi sets `truncated:true` if it
    // dropped events; we surface that to logs only (D1=B).
    ch.send(SessionSync(id: _newId()));
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  @override
  Future<void> sendMessage(String text) async {
    final msg = UserMessage(id: _newId(), text: text);
    final ch = _conn.channel;

    // Always add the bubble locally — even when the channel is down
    // (Pi offline, app booting, reconnecting, etc). Without this the
    // user typing while Pi is `stop`-ed lost every prompt silently.
    //
    // When the channel IS up, also arm `streaming` so the typing
    // indicator + input-disabled state behave as before. When it's
    // down, leave streaming alone so the user can keep typing more
    // pending messages — AgentDone won't come to clear it anyway.
    if (ch != null) {
      debugPrint('[chat-state] sendMessage id=${msg.id}, awaiting → true');
      _emit(
        _state.copyWith(
          messages: [..._state.messages, UserMsg(id: msg.id, text: text)],
          streaming: StreamingMessage(inReplyTo: msg.id),
        ),
      );
      unawaited(_persistSnapshot());
      await ch.send(msg);
    } else {
      debugPrint(
        '[chat-state] sendMessage id=${msg.id}, channel=null → '
        'held locally as cli_* (no transmit, no streaming indicator)',
      );
      _emit(
        _state.copyWith(
          messages: [..._state.messages, UserMsg(id: msg.id, text: text)],
        ),
      );
      unawaited(_persistSnapshot());
    }
  }

  @override
  Future<void> cancel(String targetId) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(Cancel(id: _newId(), targetId: targetId));
  }

  @override
  Future<void> approveTool(
    String toolCallId,
    ApproveDecision decision,
  ) async {
    final ch = _conn.channel;
    if (ch == null) return;
    await ch.send(
      ApproveTool(id: _newId(), toolCallId: toolCallId, decision: decision),
    );
    _updateTool(
      toolCallId,
      decision == ApproveDecision.allow
          ? ToolEventStatus.allowed
          : ToolEventStatus.denied,
    );
  }

  // ---------------------------------------------------------------------------
  // Internal event handlers
  // ---------------------------------------------------------------------------

  void _onStatusChange(ConnectionStatus s) {
    _msgSub?.cancel();
    _msgSub = null;

    if (s is StatusOnline) {
      _msgSub = s.channel.serverMessages.listen(
        _onServerMessage,
        onDone: () {},
      );
      // ignore: unawaited_futures
      _onlineActivated();
    }
    _emit(_state.copyWith(connection: s));
  }

  Future<void> _onlineActivated() async {
    final peer = _conn.activePeer;
    if (peer == null) return;
    if (peer.remoteEpk != _activeEpk) {
      await setActivePeer(peer);
    }
    _syncDebounce?.cancel();
    _syncDebounce = Timer(const Duration(milliseconds: 200), requestSync);
  }

  void _onServerMessage(ServerMessage msg) {
    switch (msg) {
      case AgentChunk(:final inReplyTo, :final delta):
        final tail = delta.length > 3
            ? delta.substring(delta.length - 3)
            : delta;
        debugPrint(
          '[chat-state] AgentChunk in_reply_to=$inReplyTo '
          "len=${delta.length} tail='$tail'",
        );
        _chunkBuffer.write(delta);
        _chunkReplyTo = inReplyTo;
        _flushTimer?.cancel();
        _flushTimer = Timer(const Duration(milliseconds: 16), _flushChunks);

      case AgentDone(:final inReplyTo):
        debugPrint(
          '[chat-state] SessionRepository got AgentDone '
          'in_reply_to=$inReplyTo, dispatching to chat',
        );
        debugPrint(
          '[chat-state] AgentDone in_reply_to=$inReplyTo, awaiting → false '
          '(current streaming.in_reply_to=${_state.streaming?.inReplyTo ?? "—"})',
        );
        _flushTimer?.cancel();
        _flushTimer = null;
        final pendingDelta = _chunkBuffer.toString();
        _chunkBuffer.clear();
        _chunkReplyTo = '';

        final cur = _state.streaming;
        final streamedSoFar = cur?.buffer ?? '';
        final fullText = streamedSoFar + pendingDelta;

        if (fullText.isEmpty) {
          _emit(_state.copyWith(clearStreaming: true));
        } else {
          _emit(
            _state.copyWith(
              messages: [
                ..._state.messages,
                AssistantMsg(id: inReplyTo, text: fullText),
              ],
              clearStreaming: true,
            ),
          );
          unawaited(_persistSnapshot());
        }

      case AgentMessage(:final inReplyTo, :final text):
        // Consolidated reply (typically only inside session_history; rare
        // standalone). If the matching streaming bucket exists, finalize
        // it; otherwise append as a fresh AssistantMsg.
        if (_state.messages.any((m) => m is AssistantMsg && m.id == inReplyTo)) {
          break; // already present (dedupe)
        }
        _emit(
          _state.copyWith(
            messages: [..._state.messages, AssistantMsg(id: inReplyTo, text: text)],
            clearStreaming: _state.streaming?.inReplyTo == inReplyTo
                ? true
                : false,
          ),
        );
        unawaited(_persistSnapshot());

      case UserInput(:final id, :final text):
        // Dedup against history: if a `session_history` batch already
        // populated this UserMsg (same id), Pi may also echo it as a
        // real-time `user_input`. Skip to avoid duplicate bubbles.
        if (_state.messages.any((m) => m is UserMsg && m.id == id)) {
          break;
        }
        _emit(
          _state.copyWith(
            messages: [..._state.messages, UserMsg(id: id, text: text)],
            streaming: StreamingMessage(inReplyTo: id),
          ),
        );
        unawaited(_persistSnapshot());

      case ToolRequest(:final toolCallId, :final tool, :final args):
        // Dedup against history: a previous `session_history` batch
        // may already contain this ToolEvent (same toolCallId).
        if (_state.messages
            .any((m) => m is ToolEvent && m.toolCallId == toolCallId)) {
          break;
        }
        final event = ToolEvent(
          id: toolCallId,
          toolCallId: toolCallId,
          tool: tool,
          args: args,
        );
        _emit(_state.copyWith(messages: [..._state.messages, event]));
        unawaited(_persistSnapshot());

      case ToolResult(:final toolCallId, :final result, :final error):
        _updateTool(
          toolCallId,
          error != null ? ToolEventStatus.denied : ToolEventStatus.completed,
          result: result,
          error: error,
        );
        unawaited(_persistSnapshot());

      case Cancelled(:final targetId):
        _emit(
          _state.copyWith(
            messages: [
              ..._state.messages.where((m) => m.id != targetId),
            ],
            clearStreaming: true,
          ),
        );
        unawaited(_persistSnapshot());

      case Pong():
        break;

      case PairOk():
      case PairError():
        break;

      case Bye(:final rawReason):
        debugPrint('[chat-state] received bye reason=$rawReason');
        if (!_eventController.isClosed) {
          _eventController.add(PeerWentOffline(rawReason));
        }
        // Previously this called `_conn.disconnect()`, which tore down
        // the WS to relay entirely. That killed presence updates AND
        // meant the only way to learn Pi was back was a manual
        // Reconnect tap. Now we `switchTo` the same peer instead: it
        // closes the dead per-peer channel but immediately establishes
        // a fresh WS to relay with `subscribe_presence` replayed, so
        // when Pi reconnects the relay's `peer_online` flows through
        // and ChatViewModel can auto-clear the banner + sync.
        final peer = _conn.activePeer;
        if (peer != null) {
          // ignore: unawaited_futures
          _conn.switchTo(peer);
        }

      case SessionHistory(:final events, :final sessionStartedAt, :final eos):
        debugPrint(
          '[chat-state] ← session_history events.len=${events.length} '
          'session_started_at=$sessionStartedAt eos=$eos '
          '(cached _lastSessionStartedAt=$_lastSessionStartedAt '
          '_lastSyncedTs=$_lastSyncedTs)',
        );
        // ignore: unawaited_futures
        _applyHistory(msg);

      case ErrorMessage(:final code, :final message):
        if (code == 'unknown_peer' || code.contains('unknown_peer')) {
          if (!_eventController.isClosed) {
            _eventController.add(const PairingRevoked());
          }
          break;
        }
        _emit(
          _state.copyWith(
            messages: [
              ..._state.messages,
              AssistantMsg(id: _newId(), text: '⚠ $code: $message'),
            ],
          ),
        );
        unawaited(_persistSnapshot());
    }
  }

  // ---------------------------------------------------------------------------
  // session_history handling
  // ---------------------------------------------------------------------------

  Future<void> _applyHistory(SessionHistory h) async {
    final converted = _convertHistory(h.events);
    final maxTs = h.events.isEmpty
        ? null
        : h.events.map((e) => e.ts).reduce((a, b) => a > b ? a : b);
    _lastSessionStartedAt = h.sessionStartedAt;
    _lastSyncedTs = maxTs;

    // Plan 16 mirror-cache: state.messages = Pi's view exactly.
    // `truncated` is captured for logs only (D1=B).
    debugPrint(
      '[chat-state] _applyHistory: REPLACE converted.len=${converted.length} '
      'existing.len=${_state.messages.length} eos=${h.eos} '
      'truncated=${h.truncated}',
    );
    _emit(_state.copyWith(messages: converted, clearStreaming: false));

    final epk = _activeEpk;
    if (epk != null) {
      await _store.replaceFor(
        epk,
        converted,
        sessionStartedAt: h.sessionStartedAt,
        lastTs: _lastSyncedTs,
      );
    }

    if (h.eos) {
      debugPrint(
        '[chat-state] session_history sync complete (eos) '
        'session_started_at=${h.sessionStartedAt} last_ts=$_lastSyncedTs '
        'truncated=${h.truncated}',
      );
    }
  }

  /// Replay history events sequentially so a `tool_request` followed by a
  /// `tool_result` for the same call merges into a single ToolEvent (the
  /// same in-place merge `_updateTool` does for real-time).
  List<ChatMessage> _convertHistory(List<SessionHistoryEvent> events) {
    final out = <ChatMessage>[];
    for (final e in events) {
      switch (e) {
        case UserInputEvt(:final id, :final text):
          out.add(UserMsg(id: id, text: text));
        case AgentMessageEvt(:final inReplyTo, :final text):
          out.add(AssistantMsg(id: inReplyTo, text: text));
        case ToolRequestEvt(:final toolCallId, :final tool, :final args):
          out.add(ToolEvent(
            id: toolCallId,
            toolCallId: toolCallId,
            tool: tool,
            args: args,
          ));
        case ToolResultEvt(:final toolCallId, :final result, :final error):
          final idx = out.lastIndexWhere(
            (m) => m is ToolEvent && m.toolCallId == toolCallId,
          );
          final newStatus = error != null
              ? ToolEventStatus.denied
              : ToolEventStatus.completed;
          if (idx >= 0) {
            final existing = out[idx] as ToolEvent;
            out[idx] = existing.copyWith(
              status: newStatus,
              result: result,
              error: error,
            );
          } else {
            out.add(ToolEvent(
              id: toolCallId,
              toolCallId: toolCallId,
              tool: 'unknown',
              args: const <String, dynamic>{},
              status: newStatus,
              result: result,
              error: error,
            ));
          }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------

  Future<void> _persistSnapshot() async {
    final epk = _activeEpk;
    if (epk == null) return;
    // Persist current state to Hive. Pointers (`_lastSessionStartedAt`,
    // `_lastSyncedTs`) are only advanced by `_applyHistory` when actual
    // events arrive; here we just snapshot the rendered message list
    // so a reload-from-cold shows the same view.
    await _store.replaceFor(
      epk,
      _state.messages,
      sessionStartedAt: _lastSessionStartedAt,
      lastTs: _lastSyncedTs,
    );
  }

  void _flushChunks() {
    if (_chunkBuffer.isEmpty) return;
    final delta = _chunkBuffer.toString();
    _chunkBuffer.clear();
    final cur = _state.streaming;
    if (cur != null && cur.inReplyTo == _chunkReplyTo) {
      _emit(_state.copyWith(streaming: cur.appendDelta(delta)));
    } else {
      _emit(
        _state.copyWith(
          streaming: StreamingMessage(inReplyTo: _chunkReplyTo, buffer: delta),
        ),
      );
    }
  }

  void _updateTool(
    String toolCallId,
    ToolEventStatus status, {
    dynamic result,
    String? error,
  }) {
    var found = false;
    final updated = _state.messages.map((m) {
      if (m is ToolEvent && m.toolCallId == toolCallId) {
        found = true;
        return m.copyWith(status: status, result: result, error: error);
      }
      return m;
    }).toList();

    if (!found) {
      updated.add(ToolEvent(
        id: toolCallId,
        toolCallId: toolCallId,
        tool: 'unknown',
        args: const <String, dynamic>{},
        status: status,
        result: result,
        error: error,
      ));
    }

    _emit(_state.copyWith(messages: updated));
  }

  void _emit(SessionState s) {
    _state = s;
    if (!_stateController.isClosed) _stateController.add(s);
  }

  // ---------------------------------------------------------------------------

  @override
  void dispose() {
    _flushTimer?.cancel();
    _syncDebounce?.cancel();
    _connSub?.cancel();
    _msgSub?.cancel();
    _conn.dispose();
    _stateController.close();
    _eventController.close();
  }

  static int _counter = 0;
  static String _newId() => 'cli_${++_counter}';
}
