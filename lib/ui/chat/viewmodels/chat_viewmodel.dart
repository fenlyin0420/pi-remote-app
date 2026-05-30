import 'dart:async';

import 'package:app/data/local/records/message_record.dart';
import 'package:app/data/local/records/runtime_record.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_events.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';

/// Plan/31 — ChatViewModel is now a thin composer over the local SSOT.
///
/// It reads messages + runtime from [SessionReadRepository] (the DB), composes
/// the in-memory streaming buffer from [SyncService] (#7), and issues commands
/// (send/cancel/approve) through [SyncService]. Connection lifecycle +
/// presence/rooms queries (AppBar) stay on [ConnectionManager]. It NEVER
/// subscribes to the channel directly — that's the SyncService's job.
class ChatViewModel extends ViewModel<ChatState> {
  final SessionReadRepository _read;
  final SyncService _sync;
  final ConnectionManager _conn;
  final Preferences _prefs;
  final PairingStorage _storage;

  StreamSubscription<List<MessageRecord>>? _msgsSub;
  StreamSubscription<RuntimeRecord>? _runtimeSub;
  StreamSubscription<StreamingMessage?>? _streamingSub;
  StreamSubscription<SessionEvent>? _eventSub;
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  StreamSubscription<ConnectionStatus>? _statusSub;

  PeerRecord? _activePeer;
  String _activeRoomId = 'main';
  bool _bootstrapping = true;
  bool _disposed = false;

  List<ChatMessage> _messages = const [];
  StreamingMessage? _streaming;
  RuntimeRecord _runtime = const RuntimeRecord();
  bool _pairingRevoked = false;
  String? _peerOfflineReason;
  ConnectionStatus? _lastStatus;

  ChatViewModel(this._read, this._sync, this._conn, this._prefs, this._storage)
    : super(const ChatConnecting()) {
    _streaming = _sync.streaming;
    _streamingSub = _sync.streamingStream.listen(_onStreaming);
    _eventSub = _sync.events.listen(_onEvent);
    _roomsSub = _conn.roomsStream.listen((_) => _recompute());
    _statusSub = _conn.statusStream.listen(_onStatus);
    // ignore: discarded_futures
    _bootstrap();
  }

  // --- AppBar-facing getters (relay/connection queries, not message data) ---

  PeerRecord? get activePeer => _activePeer;

  RoomInfo? get activeRoom {
    final epk = _activePeer?.remoteEpk;
    if (epk == null) return null;
    for (final r in _conn.roomsFor(epk)) {
      if (r.roomId == _activeRoomId) return r;
    }
    return null;
  }

  bool get isRoomLive {
    final epk = _activePeer?.remoteEpk;
    if (epk == null) return false;
    return _conn.isRoomLive(epk, _activeRoomId);
  }

  bool get isWorking => _streaming != null;

  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    final epk = _prefs.selectedPeerEpk;
    final roomId = _prefs.selectedRoomId ?? 'main';
    if (epk == null) {
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    final peer = await _storage.loadPeer(epk);
    if (_disposed) return;
    if (peer == null) {
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    _activePeer = peer;
    _activeRoomId = roomId;

    // Bind the writer + watch the DB for this (peer, room).
    await _sync.activate(epk, roomId);
    if (_disposed) return;
    _conn.switchRoom(roomId);
    _msgsSub = _read.watchMessages(epk, roomId).listen(_onMessages);
    _runtimeSub = _read.watchRuntime(epk, roomId).listen(_onRuntime);

    // Drive the connection lifecycle (plano 12/13): connect to this peer if
    // the manager isn't already on it.
    if (_conn.activePeer?.remoteEpk != peer.remoteEpk) {
      await _conn.switchTo(peer);
      if (_disposed) return;
    }
    _bootstrapping = false;
    _sync.requestSync();
    _recompute();
  }

  void _onMessages(List<MessageRecord> rows) {
    _messages = [for (final r in rows) r.toChatMessage()];
    _recompute();
  }

  void _onStreaming(StreamingMessage? s) {
    _streaming = s;
    _recompute();
  }

  void _onRuntime(RuntimeRecord r) {
    _runtime = r;
    _recompute();
  }

  void _onStatus(ConnectionStatus s) {
    final wasOnline = _lastStatus is StatusOnline;
    final nowOnline = s is StatusOnline;
    _lastStatus = s;
    // Auto re-sync on a fresh online edge so the chat catches up.
    if (nowOnline && !wasOnline) _sync.requestSync();
    _recompute();
  }

  void _onEvent(SessionEvent e) {
    if (e is PairingRevoked) {
      _pairingRevoked = true;
    } else if (e is PeerWentOffline) {
      _peerOfflineReason = e.rawReason;
    }
    _recompute();
  }

  void _recompute() {
    if (_disposed) return;
    emit(_compose());
  }

  ChatState _compose() {
    if (_activePeer == null) {
      return _bootstrapping ? const ChatConnecting() : const ChatNoPeer();
    }
    final isOnline = _runtime.connection == RuntimeConnection.online;
    final isOffline = !isOnline;
    final peerPresence = _runtime.presence == RuntimePresence.alive
        ? const PresenceOnline() as PresenceState
        : const PresenceOffline(sinceTs: 0);

    final hasContent = _messages.isNotEmpty || _streaming != null;
    if (hasContent) {
      return ChatReady(
        messages: _messages,
        streaming: _streaming,
        isOffline: isOffline,
        pairingRevoked: _pairingRevoked,
        peerOfflineReason: _peerOfflineReason,
        peerPresence: peerPresence,
      );
    }
    if (_bootstrapping && _runtime.connection == RuntimeConnection.connecting) {
      return const ChatConnecting();
    }
    return ChatReady(
      messages: const [],
      isOffline: isOffline,
      pairingRevoked: _pairingRevoked,
      peerOfflineReason: _peerOfflineReason,
      peerPresence: peerPresence,
    );
  }

  // --- Commands (writer = SyncService; lifecycle = ConnectionManager) ---

  Future<void> sendMessage(String text, {MessageImage? image}) =>
      _sync.sendMessage(text, image: image);

  Future<void> cancel(String targetId) => _sync.cancel(targetId);

  Future<void> approveTool(String toolCallId, ApproveDecision decision) =>
      _sync.approveTool(toolCallId, decision);

  Future<void> clearActiveSession() => _sync.clearActiveSession();

  Future<void> reconnect() async {
    final peer = _activePeer;
    if (peer == null) return;
    _peerOfflineReason = null;
    emit(const ChatConnecting());
    await _conn.switchTo(peer);
  }

  @override
  void dispose() {
    _disposed = true;
    _msgsSub?.cancel();
    _runtimeSub?.cancel();
    _streamingSub?.cancel();
    _eventSub?.cancel();
    _roomsSub?.cancel();
    _statusSub?.cancel();
    super.dispose();
  }
}
