import 'dart:async';

import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/i_session_repository.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/core/viewmodel/viewmodel.dart';
import 'package:flutter/foundation.dart' show debugPrint;

/// ChatViewModel — owns the chat connection lifecycle.
///
/// Connection rule (after plano 12): the WS is opened by the
/// ConnectionManager at app boot and stays alive across navigation. Chat
/// observes the existing connection and asks the manager to switch the
/// "active peer" when it mounts. Presence (relay-driven) drives the
/// banner / input state independently of the WS-to-relay status.
class ChatViewModel extends ViewModel<ChatState> {
  final ISessionRepository _repo;
  final Preferences _prefs;
  final PairingStorage _storage;
  StreamSubscription? _sub;
  StreamSubscription? _eventSub;
  // Plan-17 follow-up — presence per-peer was replaced by "is this
  // specific room currently live?". Subscribed to roomsStream below.
  StreamSubscription<Map<String, List<RoomInfo>>>? _roomsSub;
  bool _pairingRevoked = false;
  String? _peerOfflineReason;
  PeerRecord? _activePeer;
  String _activeRoomId = 'main';
  bool _roomLive = false;
  bool _bootstrapping = true;
  bool _disposed = false;

  /// Active room metadata (name, cwd, etc) for the AppBar title.
  /// Refreshed on every rooms snapshot. `null` until first snapshot.
  RoomInfo? get activeRoom {
    final epk = _activePeer?.remoteEpk;
    if (epk == null) return null;
    final list = _repo.roomsFor(epk);
    for (final r in list) {
      if (r.roomId == _activeRoomId) return r;
    }
    return null;
  }

  /// Currently-bound peer, exposed for the AppBar.
  PeerRecord? get activePeer => _activePeer;

  /// Whether the active room is announced LIVE on the relay.
  bool get isRoomLive => _roomLive;

  /// Plan-18 follow-up — `true` when the agent is mid-response
  /// (state.streaming != null). Drives the "working…" pill in the
  /// chat AppBar.
  bool get isWorking {
    final s = state;
    return s is ChatReady && s.streaming != null;
  }

  ChatViewModel(this._repo, this._prefs, this._storage)
    : super(const ChatConnecting()) {
    _sub = _repo.sessionStream.listen(_onSession);
    _eventSub = _repo.eventStream.listen(_onEvent);
    _roomsSub = _repo.roomsStream.listen(_onRooms);
    // ignore: unawaited_futures
    _bootstrap();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  Future<void> _bootstrap() async {
    final epk = _prefs.selectedPeerEpk;
    final roomId = _prefs.selectedRoomId ?? 'main';
    if (epk == null) {
      debugPrint('[chat-state] bootstrap: no selectedPeerEpk → ChatNoPeer');
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    debugPrint('[chat-state] bootstrap: target peer=$epk room=$roomId');
    final peer = await _storage.loadPeer(epk);
    if (_disposed) return;
    if (peer == null) {
      debugPrint('[chat-state] bootstrap: selectedPeerEpk=$epk not in storage');
      _bootstrapping = false;
      emit(const ChatNoPeer());
      return;
    }
    _activePeer = peer;
    _activeRoomId = roomId;
    _roomLive = _repo.isRoomLive(peer.remoteEpk, roomId);
    debugPrint(
      '[chat-state] bootstrap: peer=${peer.remoteEpk} room=$roomId '
      'live=$_roomLive',
    );
    // Plan 17 — make sure the destination room id is propagated to
    // ConnectionManager / WS transport on cold start (Home's
    // openSession already does this when the user taps a tile; this
    // handles the case where the app re-launches directly into /chat).
    // Tell the connection layer which room to address on the Pi side.
    _repo.switchRoom(roomId);
    // setActivePeer below loads the (peer, room) partitioned cache.

    // Always load the per-peer history cache (plano 11) so the chat
    // surface has content even if the WS hasn't authenticated yet.
    await _repo.setActivePeer(peer, roomId: roomId);
    if (_disposed) return;

    // Plano 13 fast path: if the connection layer already settled on
    // this exact peer (boot opened it OR Home triggered switchTo before
    // navigating), don't ask for another openSession — that would just
    // be a no-op AND skip the event chain we'd otherwise rely on. Seed
    // the chat state synchronously from `_repo.current` and we're done.
    final cur = _repo.activePeer;
    final alreadyDriving = cur?.remoteEpk == peer.remoteEpk;
    if (!alreadyDriving) {
      debugPrint('[chat-state] bootstrap: openSession (peer switch needed)');
      await _repo.openSession(peer);
      if (_disposed) return;
    } else {
      debugPrint('[chat-state] bootstrap: already driving target peer');
    }

    // Seed from the repo's current snapshot so the view leaves
    // `ChatConnecting` immediately — even when `openSession` was a
    // no-op (no stream events to wait for).
    _onSession(_repo.current);

    // Plano 11 normally fires session_sync from `_onlineActivated` on
    // a StatusOnline transition. With no transition (fast-path or
    // idempotent openSession), there is none — kick a one-shot sync.
    _repo.requestSync();
  }

  // ---------------------------------------------------------------------------
  // Actions — called from UI
  // ---------------------------------------------------------------------------

  Future<void> sendMessage(String text) {
    debugPrint(
      '[chat-state] ChatViewModel.sendMessage text.len=${text.length}',
    );
    return _repo.sendMessage(text);
  }

  Future<void> cancel(String targetId) => _repo.cancel(targetId);

  Future<void> approveTool(String toolCallId, ApproveDecision decision) =>
      _repo.approveTool(toolCallId, decision);

  /// Called from the offline (bye) banner. Clears the sticky `bye` flag
  /// and asks the repo to open the session again.
  Future<void> reconnect() async {
    final peer = _activePeer;
    if (peer == null) return;
    debugPrint('[chat-state] manual reconnect epk=${peer.remoteEpk}');
    _peerOfflineReason = null;
    _bootstrapping = true;
    emit(const ChatConnecting());
    await _repo.openSession(peer);
  }

  // ---------------------------------------------------------------------------
  // Session → ChatState translation
  // ---------------------------------------------------------------------------

  void _onSession(SessionState s) {
    final cur = state;
    final wasStreaming =
        cur is ChatReady && cur.streaming != null;
    final isStreaming = s.streaming != null;
    if (wasStreaming != isStreaming) {
      debugPrint(
        '[chat-state] ChatViewModel streaming transition: '
        '$wasStreaming → $isStreaming '
        '(in_reply_to=${s.streaming?.inReplyTo ?? "—"})',
      );
    }
    if (_bootstrapping && s.connection is! StatusNoPeer) {
      _bootstrapping = false;
    }
    final next = _toChat(
      s,
      _pairingRevoked,
      _peerOfflineReason,
      _roomLive,
      _bootstrapping,
    );
    debugPrint(
      '[chat-state] _onSession emit: '
      '${next.runtimeType} (conn=${s.connection.runtimeType} '
      'msgs=${s.messages.length} streaming=${s.streaming != null} '
      'bootstrapping=$_bootstrapping)',
    );
    emit(next);
  }

  void _onEvent(SessionEvent e) {
    if (e is PairingRevoked) {
      _pairingRevoked = true;
      emit(_toChat(
        _repo.current,
        true,
        _peerOfflineReason,
        _roomLive,
        _bootstrapping,
      ));
    } else if (e is PeerWentOffline) {
      _peerOfflineReason = e.rawReason;
      emit(_toChat(
        _repo.current,
        _pairingRevoked,
        e.rawReason,
        _roomLive,
        _bootstrapping,
      ));
    }
  }

  /// Plan-17 follow-up — replaces the old per-peer presence handler.
  /// Tracks whether the ACTIVE ROOM is live on the relay; flips
  /// online/offline at the room granularity (matches what the user
  /// sees per cwd-session on Home).
  void _onRooms(Map<String, List<RoomInfo>> _) {
    final epk = _activePeer?.remoteEpk;
    if (epk == null) return;
    final next = _repo.isRoomLive(epk, _activeRoomId);
    if (next == _roomLive) return;
    final wasLive = _roomLive;
    _roomLive = next;
    debugPrint(
      '[chat-state] room live transition: $wasLive → $next '
      '(peer=$epk room=$_activeRoomId)',
    );

    // Auto-recovery: room just came back online — clear the sticky
    // banner from a previous Bye and ask Pi for the latest history.
    if (next && !wasLive) {
      if (_peerOfflineReason != null) {
        debugPrint(
          '[chat-state] room back live → clearing offlineReason banner',
        );
        _peerOfflineReason = null;
      }
      debugPrint('[chat-state] room back live → triggering requestSync');
      _repo.requestSync();
    }

    emit(_toChat(
      _repo.current,
      _pairingRevoked,
      _peerOfflineReason,
      _roomLive,
      _bootstrapping,
    ));
  }

  static ChatState _toChat(
    SessionState s,
    bool revoked,
    String? offlineReason,
    bool isRoomLive,
    bool bootstrapping,
  ) {
    // Plan-17 follow-up — translate the new bool flag back to the
    // existing PresenceState enum (PresenceOnline | PresenceOffline)
    // so the ChatReady contract stays stable.
    final peerPresence = isRoomLive
        ? const PresenceOnline() as PresenceState
        : const PresenceOffline(sinceTs: 0);
    final conn = s.connection;

    // Fingerprint mismatch / non-recoverable offline — short-circuit
    // before any content-based fallback so the user sees the re-pair
    // affordance even if there's stale cache lying around.
    if (conn is StatusOffline && !conn.canRetry) {
      return ChatFatalError(conn.reason);
    }

    // Content-first: if we have history (cached or live) OR are mid-
    // stream, always render the chat surface. The connection state only
    // drives the AppBar status line + input disable, never blocks the
    // history from being visible.
    final hasContent = s.messages.isNotEmpty || s.streaming != null;
    if (hasContent) {
      return ChatReady(
        messages: s.messages,
        streaming: s.streaming,
        isOffline: conn is! StatusOnline,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      );
    }

    // No content yet — surface the lifecycle state as before.
    return switch (conn) {
      StatusNoPeer() when bootstrapping => const ChatConnecting(),
      StatusNoPeer() when offlineReason != null => ChatReady(
        messages: const [],
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      StatusNoPeer() => const ChatNoPeer(),
      StatusConnecting() => const ChatConnecting(),
      StatusOnline() => ChatReady(
        messages: const [],
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      StatusRetrying() => ChatReady(
        messages: const [],
        isOffline: true,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
      // Recoverable offline — show the chat surface with the
      // reconnecting banner instead of swallowing into ChatConnecting.
      StatusOffline() => ChatReady(
        messages: const [],
        isOffline: true,
        pairingRevoked: revoked,
        peerOfflineReason: offlineReason,
        peerPresence: peerPresence,
      ),
    };
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    _eventSub?.cancel();
    _roomsSub?.cancel();
    // Connection persists from boot (plano 12). Chat is passive.
    super.dispose();
  }
}
